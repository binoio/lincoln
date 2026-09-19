import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class TunnelManagerTests: XCTestCase {
    private var directory: URL!
    private var store: TunnelStore!
    private var settings: SettingsManager!
    private var launcher: MockTerminalLauncher!
    private var headless: MockHeadlessLauncher!
    private var socket: MockControlSocket!
    private var environment: MockSSHEnvironment!
    private var notifier: MockNotifier!

    private var socketPath: String { environment.resolved!.path }

    override func setUp() async throws {
        directory = TestFixtures.temporaryDirectory("manager")
        store = TunnelStore(fileURL: directory.appendingPathComponent("tunnels.json"))
        settings = SettingsManager(defaults: TestFixtures.isolatedDefaults(), loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        launcher = MockTerminalLauncher()
        socket = MockControlSocket()
        environment = MockSSHEnvironment()
        notifier = MockNotifier()
        headless = MockHeadlessLauncher()
        headless.socket = socket
        headless.socketPath = environment.resolved!.path
        // Manager tests exercise the Terminal flow unless stated otherwise.
        settings.connectSilentlyFirst = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeManager(home: URL? = nil) -> TunnelManager {
        TunnelManager(
            store: store,
            settings: settings,
            environment: environment,
            launcher: launcher,
            headless: headless,
            socket: socket,
            notifier: notifier,
            configParser: SSHConfigParser(homeDirectory: home ?? URL(fileURLWithPath: "/nonexistent"))
        )
    }

    func testAddUpdateRemovePersist() throws {
        let manager = makeManager()
        manager.load()
        XCTAssertTrue(manager.supervisors.isEmpty)

        let supervisor = manager.addNewTunnel()
        XCTAssertEqual(manager.selectedTunnelID, supervisor.id)
        XCTAssertEqual(supervisor.tunnel.name, "New Tunnel")
        XCTAssertEqual(supervisor.tunnel.forwards.first?.listenPort, 1080)
        let second = manager.addNewTunnel()
        XCTAssertEqual(second.tunnel.name, "New Tunnel 2")
        XCTAssertEqual(second.tunnel.forwards.first?.listenPort, 1081, "next free SOCKS port")

        var edited = supervisor.tunnel
        edited.name = "Gateway"
        edited.host = "tg"
        manager.update(edited)
        XCTAssertEqual(manager.supervisor(for: supervisor.id)?.tunnel.name, "Gateway")

        let onDisk = try store.load().document
        XCTAssertEqual(onDisk.tunnels.map(\.name), ["Gateway", "New Tunnel 2"])

        manager.remove(id: second.id)
        XCTAssertEqual(manager.supervisors.count, 1)
        XCTAssertEqual(try store.load().document.tunnels.count, 1)
        XCTAssertEqual(manager.selectedTunnelID, supervisor.id)
    }

    func testConnectRecordsDesiredUpAndRestoreMarksDropped() async throws {
        let manager = makeManager()
        manager.load()
        let supervisor = manager.add(TestFixtures.tunnel())
        manager.connect(id: supervisor.id)
        await drainMainQueue()
        XCTAssertTrue(supervisor.state.isConnecting)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(try store.load().document.desiredUp, [supervisor.id])

        // The master comes up; quitting leaves it running.
        socket.running[socketPath] = 5
        await manager.pollAll()
        XCTAssertTrue(supervisor.state.isConnected)
        manager.prepareForQuit()
        XCTAssertEqual(try store.load().document.desiredUp, [supervisor.id])

        // Relaunch while the master is still running: adopted, no Terminal.
        let relaunched = makeManager()
        relaunched.load()
        await relaunched.restore()
        XCTAssertTrue(relaunched.supervisors[0].state.isConnected)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(notifier.posted.isEmpty)

        // Relaunch after the master died: shown as dropped, user reconnects.
        socket.running.removeAll()
        let third = makeManager()
        third.load()
        await third.restore()
        XCTAssertEqual(third.supervisors[0].state, .dropped(reason: "Was connected when Lincoln last quit"))
        XCTAssertEqual(notifier.posted.last?.title, "Tunnels need reconnecting")
        XCTAssertEqual(launcher.launches.count, 1, "never reopens Terminal unasked")

        // Explicit disconnect clears the intent.
        third.disconnect(id: supervisor.id)
        await drainMainQueue()
        XCTAssertEqual(third.supervisors[0].state, .idle)
        XCTAssertEqual(try store.load().document.desiredUp, [])
    }

    func testAutoConnectOpensTerminalAtLaunch() async throws {
        var document = TunnelDocument()
        document.upsert(TestFixtures.tunnel(name: "Auto", autoConnect: true))
        document.upsert(TestFixtures.tunnel(name: "Manual"))
        try store.save(document)

        let manager = makeManager()
        manager.load()
        await manager.restore()
        await drainMainQueue()
        XCTAssertEqual(launcher.launches.map(\.name), ["Auto"])
        XCTAssertTrue(manager.supervisors[0].state.isConnecting)
        XCTAssertEqual(manager.supervisors[1].state, .idle)
    }

    func testSilentSettingIsConsultedPerLaunch() async {
        let manager = makeManager()
        manager.load()
        let supervisor = manager.add(TestFixtures.tunnel())
        settings.connectSilentlyFirst = true
        manager.connect(id: supervisor.id)
        await drainMainQueue()
        XCTAssertEqual(headless.launches.count, 1)
        XCTAssertTrue(launcher.launches.isEmpty)
        await manager.pollAll()
        XCTAssertTrue(supervisor.state.isConnected)
    }

    func testExternallyStartedMasterIsAdoptedByPolling() async {
        let manager = makeManager()
        manager.load()
        let supervisor = manager.add(TestFixtures.tunnel())
        socket.running[socketPath] = 77
        await manager.pollAll()
        XCTAssertTrue(supervisor.state.isConnected)
        XCTAssertEqual(manager.connectedCount, 1)
        XCTAssertTrue(manager.anyConnected)
    }

    func testCorruptStoreIsSurfacedNotFatal() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.fileURL)
        let manager = makeManager()
        manager.load()
        XCTAssertTrue(manager.supervisors.isEmpty)
        XCTAssertNotNil(manager.loadWarning)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("tunnels.json.corrupt-") })
    }

    func testToggleConnectAllDisconnectAll() async {
        let manager = makeManager()
        manager.load()
        let a = manager.add(TestFixtures.tunnel(name: "A"))
        let b = manager.add(TestFixtures.tunnel(name: "B"))
        manager.connectAll()
        await drainMainQueue()
        XCTAssertEqual(manager.activeCount, 2)
        XCTAssertEqual(launcher.launches.map(\.name), ["A", "B"])
        manager.toggle(id: a.id)
        await drainMainQueue()
        XCTAssertFalse(a.state.isActive)
        XCTAssertTrue(b.state.isActive)
        manager.disconnectAll()
        await drainMainQueue()
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.document.desiredUp, [])
    }

    func testRemoveLeavesRunningMasterAlone() async {
        let manager = makeManager()
        manager.load()
        let supervisor = manager.add(TestFixtures.tunnel())
        socket.running[socketPath] = 3
        await manager.pollAll()
        XCTAssertTrue(supervisor.state.isConnected)
        manager.remove(id: supervisor.id)
        await drainMainQueue()
        XCTAssertTrue(socket.exits.isEmpty)
        XCTAssertEqual(socket.running[socketPath], 3)
    }

    func testRemovalRequestNeedsConfirmation() {
        let manager = makeManager()
        manager.load()
        let a = manager.add(TestFixtures.tunnel(name: "A"))
        manager.requestRemoval(id: nil)
        XCTAssertNil(manager.pendingRemovalID)
        manager.requestRemoval(id: UUID())
        XCTAssertNil(manager.pendingRemovalID, "unknown ids are ignored")
        manager.requestRemoval(id: a.id)
        XCTAssertEqual(manager.pendingRemovalID, a.id)
        XCTAssertEqual(manager.supervisors.count, 1, "nothing is removed until confirmed")
        manager.remove(id: a.id)
        XCTAssertTrue(manager.supervisors.isEmpty)
    }

    func testPromptRoutingQueueAndCancel() async {
        let manager = makeManager()
        manager.load()
        let a = manager.add(TestFixtures.tunnel(name: "A"))
        // Any headless launch keeps the tunnel in `connecting` while ssh runs;
        // that is when relayed prompts are accepted.
        settings.connectSilentlyFirst = true
        // Not connecting → prompt is refused outright.
        var replyIdle: AskpassReply?
        manager.testRoute(PendingPrompt(request: AskpassRequest(prompt: "x", hint: nil, tunnelID: a.id.uuidString)) { replyIdle = $0 })
        XCTAssertEqual(replyIdle?.cancelled, true)
        XCTAssertNil(manager.activePrompt)

        // Connecting → prompt becomes active, answer flows back. ssh sends one
        // prompt at a time per tunnel, so a newer prompt supersedes an unanswered one.
        headless.result = SSHCommandResult(standardOutput: "", standardError: "", exitCode: 255)
        var reply1: AskpassReply?
        var reply2: AskpassReply?
        headless.whileRunning = { [self] in
            manager.testRoute(PendingPrompt(request: AskpassRequest(prompt: "first", hint: nil, tunnelID: a.id.uuidString)) { reply1 = $0 })
            XCTAssertEqual(manager.activePrompt?.request.prompt, "first")
            XCTAssertNil(reply1)
            manager.testRoute(PendingPrompt(request: AskpassRequest(prompt: "second", hint: nil, tunnelID: a.id.uuidString)) { reply2 = $0 })
            XCTAssertEqual(reply1?.cancelled, true, "superseded")
            XCTAssertEqual(manager.activePrompt?.request.prompt, "second")
            manager.answerActivePrompt("1")
            XCTAssertEqual(reply2, AskpassReply(answer: "1", cancelled: false))
            XCTAssertNil(manager.activePrompt)
            var reply3: AskpassReply?
            manager.testRoute(PendingPrompt(request: AskpassRequest(prompt: "third", hint: nil, tunnelID: a.id.uuidString)) { reply3 = $0 })
            manager.cancelActivePrompt()
            XCTAssertEqual(reply3?.cancelled, true)
            XCTAssertNil(manager.activePrompt)
        }
        manager.connect(id: a.id)
        await drainMainQueue()
        XCTAssertEqual(notifier.posted.filter { $0.title == "A needs your answer" }.count, 3)
        // Unknown tunnel ids are cancelled.
        var replyUnknown: AskpassReply?
        manager.testRoute(PendingPrompt(request: AskpassRequest(prompt: "x", hint: nil, tunnelID: UUID().uuidString)) { replyUnknown = $0 })
        XCTAssertEqual(replyUnknown?.cancelled, true)
    }

    func testClipboardHelpers() async {
        let manager = makeManager()
        manager.load()
        let a = manager.add(TestFixtures.tunnel(name: "A"))
        XCTAssertFalse(manager.copySessionCommand(id: nil))
        XCTAssertFalse(manager.copySessionCommand(id: a.id), "no control path resolved yet")
        await manager.pollAll()
        XCTAssertTrue(manager.copySessionCommand(id: a.id))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "/usr/bin/ssh -o ControlPath=\(socketPath) -- tg")
        XCTAssertTrue(manager.copyConfigSnippet(id: a.id))
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)!.hasPrefix("Host lincoln-a\n"))
        XCTAssertFalse(manager.copyConfigSnippet(id: UUID()))
    }

    func testDuplicateAndMove() {
        let manager = makeManager()
        manager.load()
        let a = manager.add(TestFixtures.tunnel(name: "A"))
        let copy = manager.duplicate(id: a.id)!
        XCTAssertEqual(copy.tunnel.name, "A copy")
        XCTAssertNotEqual(copy.tunnel.forwards[0].id, a.tunnel.forwards[0].id)
        XCTAssertEqual(manager.supervisors.map { $0.tunnel.name }, ["A", "A copy"])
        manager.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(manager.document.tunnels.map(\.name), ["A copy", "A"])
    }

    func testPollingTimerRunsWhileActiveAndStopsWhenIdle() async {
        let manager = makeManager()
        manager.load()
        let supervisor = manager.add(TestFixtures.tunnel())
        manager.activePollInterval = 0.05
        socket.running[socketPath] = 1
        manager.startPolling()
        let connected = expectation(description: "connected")
        connected.assertForOverFulfill = false
        supervisor.onStateChange = { if $0.state.isConnected { connected.fulfill() } }
        await fulfillment(of: [connected], timeout: 3)
        XCTAssertTrue(manager.hasActiveTunnels)

        // While connected the timer keeps checking…
        let before = socket.checks.count
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(socket.checks.count, before)

        // …after the master goes away and the drop is acknowledged, it stops.
        socket.running.removeAll()
        try? await Task.sleep(nanoseconds: 300_000_000)
        manager.disconnect(id: supervisor.id)
        await drainMainQueue()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(manager.hasActiveTunnels)
        let idleCount = socket.checks.count
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(socket.checks.count, idleCount, "no polling while nothing is active")
        manager.stopPolling()
    }

    func testSocketDirectoryChangeWakesIdlePolling() async throws {
        let directory = URL(fileURLWithPath: "/tmp/lincoln-watch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("socket-alice@tg:22").path
        environment.resolved = ResolvedControlPath(path: path, isFromConfig: true,
                                                   destination: SSHDestination(user: "alice", hostName: "tg", port: 22, configuredControlPath: path))
        let manager = makeManager()
        manager.load()
        let supervisor = manager.add(TestFixtures.tunnel())
        manager.startPolling()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(supervisor.state, .idle)
        XCTAssertEqual(manager.watchedSocketDirectories, [directory.path])
        let idleCount = socket.checks.count

        // A master started by hand in a terminal creates its socket file…
        socket.running[path] = 77
        FileManager.default.createFile(atPath: path, contents: nil)
        let adopted = expectation(description: "adopted")
        adopted.assertForOverFulfill = false
        supervisor.onStateChange = { if $0.state.isConnected { adopted.fulfill() } }
        await fulfillment(of: [adopted], timeout: 3)
        XCTAssertGreaterThan(socket.checks.count, idleCount)
        manager.stopPolling()
    }

    func testImportFromSSHConfig() throws {
        let home = TestFixtures.temporaryDirectory("home")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = """
        Host tg
            HostName tigressgateway.princeton.edu
            DynamicForward 1080
        Host files
            HostName tigressgateway.princeton.edu
            LocalForward 10445 files.princeton.edu:445
        Host plain
            HostName plain.example.org
        Host *
            User alice
        """
        try config.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let manager = makeManager(home: home)
        manager.load()
        let hosts = manager.importableHosts()
        XCTAssertEqual(hosts.compactMap(\.alias), ["tg", "files", "plain"])
        let created = manager.importHosts(hosts)
        XCTAssertEqual(created.map(\.host), ["tg", "files", "plain"])
        XCTAssertEqual(created[0].forwards.map(\.specification), ["1080"])
        XCTAssertEqual(created[1].forwards.map(\.specification), ["10445:files.princeton.edu:445"])
        XCTAssertEqual(created[2].forwards.first?.kind, .dynamic, "hosts without forwards get a SOCKS proxy")
        XCTAssertNotEqual(created[2].forwards.first?.listenPort, 1080, "on a free port")
        XCTAssertTrue(created[0].notes.contains("HostName tigressgateway.princeton.edu"))
        XCTAssertEqual(try store.load().document.tunnels.count, 3)
        XCTAssertEqual(manager.selectedTunnelID, created.last?.id)
        XCTAssertEqual(try String(contentsOf: ssh.appendingPathComponent("config"), encoding: .utf8), config, "ssh config is untouched")
    }
}
