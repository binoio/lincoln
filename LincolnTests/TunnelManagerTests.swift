import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class TunnelManagerTests: XCTestCase {
    private var directory: URL!
    private var store: TunnelStore!
    private var settings: SettingsManager!
    private var factory: MockTunnelProcessFactory!
    private var environment: MockSSHEnvironment!
    private var scheduler: ManualScheduler!
    private var terminated: [pid_t] = []
    private var processList = ""

    override func setUp() async throws {
        directory = TestFixtures.temporaryDirectory("manager")
        store = TunnelStore(fileURL: directory.appendingPathComponent("tunnels.json"))
        settings = SettingsManager(defaults: TestFixtures.isolatedDefaults(), loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        factory = MockTunnelProcessFactory()
        environment = MockSSHEnvironment()
        scheduler = ManualScheduler()
        terminated = []
        processList = ""
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeManager(home: URL? = nil) -> TunnelManager {
        TunnelManager(
            store: store,
            settings: settings,
            environment: environment,
            processFactory: factory,
            notifier: MockNotifier(),
            reconciler: StaleProcessReconciler(listProcesses: { [self] in processList }, currentPID: 100, terminate: { [self] in terminated.append($0) }),
            policy: .immediate,
            scheduler: scheduler.scheduler,
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

    func testConnectRecordsDesiredUpAndRestoreOnRelaunch() async throws {
        let manager = makeManager()
        manager.load()
        let supervisor = manager.add(TestFixtures.tunnel())
        manager.connect(id: supervisor.id)
        await drainMainQueue()
        XCTAssertTrue(supervisor.state.isActive)
        XCTAssertEqual(try store.load().document.desiredUp, [supervisor.id])

        // Simulate quit: processes stop, desiredUp is kept.
        manager.stopAllForQuit()
        XCTAssertEqual(try store.load().document.desiredUp, [supervisor.id])

        // Relaunch: a fresh manager restores the connection.
        let relaunched = makeManager()
        relaunched.load()
        await drainMainQueue()
        XCTAssertEqual(relaunched.supervisors.count, 1)
        XCTAssertTrue(relaunched.supervisors[0].state.isActive)
        XCTAssertEqual(factory.processes.count, 2)

        // Explicit disconnect clears the intent.
        relaunched.disconnect(id: supervisor.id)
        XCTAssertEqual(try store.load().document.desiredUp, [])
        let third = makeManager()
        third.load()
        await drainMainQueue()
        XCTAssertFalse(third.supervisors[0].state.isActive)
    }

    func testRestoreCanBeDisabledButAutoConnectAlwaysApplies() async throws {
        var auto = TestFixtures.tunnel(name: "Auto")
        auto.autoConnect = true
        var document = TunnelDocument()
        document.upsert(auto)
        let manual = TestFixtures.tunnel(name: "Manual")
        document.upsert(manual)
        document.setDesiredUp(true, id: manual.id)
        try store.save(document)

        settings.restoreConnectionsOnLaunch = false
        let manager = makeManager()
        manager.load()
        await drainMainQueue()
        XCTAssertTrue(manager.supervisor(for: auto.id)!.state.isActive)
        XCTAssertFalse(manager.supervisor(for: manual.id)!.state.isActive)
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

    func testLaunchReconciliationStopsOrphans() {
        let id = UUID()
        processList = """
          501   100 /usr/bin/ssh -N -o LocalCommand=echo \(SSHCommandBuilder.readySentinel(for: id)) tg
          502     1 /usr/bin/ssh -N -o LocalCommand=echo \(SSHCommandBuilder.readySentinel(for: UUID())) della
          503     1 /usr/bin/ssh unrelated
        """
        let manager = makeManager()
        manager.load()
        XCTAssertEqual(terminated, [502], "only Lincoln-owned ssh from another Lincoln is stopped")
    }

    func testToggleConnectAllDisconnectAll() async {
        let manager = makeManager()
        manager.load()
        let a = manager.add(TestFixtures.tunnel(name: "A"))
        let b = manager.add(TestFixtures.tunnel(name: "B"))
        manager.connectAll()
        await drainMainQueue()
        XCTAssertEqual(manager.activeCount, 2)
        manager.toggle(id: a.id)
        XCTAssertFalse(a.state.isActive)
        XCTAssertTrue(b.state.isActive)
        manager.disconnectAll()
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.document.desiredUp, [])
    }

    func testNetworkChangeAndWakeRestartOnlyActiveTunnels() async {
        let manager = makeManager()
        manager.load()
        let a = manager.add(TestFixtures.tunnel(name: "A"))
        var noWake = TestFixtures.tunnel(name: "B")
        noWake.reconnectOnWake = false
        let b = manager.add(noWake)
        let idle = manager.add(TestFixtures.tunnel(name: "C"))
        manager.connect(id: a.id)
        manager.connect(id: b.id)
        await drainMainQueue()
        factory.processes[0].emit(SSHCommandBuilder.readySentinel(for: a.id) + "\n")
        factory.processes[1].emit(SSHCommandBuilder.readySentinel(for: b.id) + "\n")
        XCTAssertTrue(a.state.isConnected)
        XCTAssertTrue(b.state.isConnected)

        manager.handleWake()
        XCTAssertFalse(a.state.isConnected)
        XCTAssertTrue(b.state.isConnected, "reconnectOnWake is off for B")
        XCTAssertEqual(idle.state, .idle)

        manager.handleNetworkChange()
        XCTAssertFalse(b.state.isConnected)
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

    func testImportFromSSHConfig() throws {
        let home = TestFixtures.temporaryDirectory("home")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
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
        """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)

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
        // The config itself is untouched.
        XCTAssertEqual(try String(contentsOf: ssh.appendingPathComponent("config"), encoding: .utf8).contains("Host plain"), true)
    }
}
