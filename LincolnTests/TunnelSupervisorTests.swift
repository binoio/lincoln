import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class TunnelSupervisorTests: XCTestCase {
    private var launcher: MockTerminalLauncher!
    private var socket: MockControlSocket!
    private var environment: MockSSHEnvironment!
    private var notifier: MockNotifier!
    private var stateDirectory: URL!
    private var tunnel: Tunnel!
    private var supervisor: TunnelSupervisor!

    private var socketPath: String { environment.resolved!.path }

    override func setUp() async throws {
        launcher = MockTerminalLauncher()
        socket = MockControlSocket()
        environment = MockSSHEnvironment()
        notifier = MockNotifier()
        stateDirectory = TestFixtures.temporaryDirectory("state")
        tunnel = TestFixtures.tunnel()
        supervisor = makeSupervisor(tunnel)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func makeSupervisor(_ tunnel: Tunnel) -> TunnelSupervisor {
        TunnelSupervisor(tunnel: tunnel, launcher: launcher, socket: socket, environment: environment, notifier: notifier, stateDirectory: stateDirectory)
    }

    private func writeStatus(_ status: Int32) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try "\(status)\n".write(to: supervisor.statusFileURL, atomically: true, encoding: .utf8)
    }

    func testStartLaunchesMasterScriptInTerminal() async {
        supervisor.start()
        await drainMainQueue()
        XCTAssertEqual(supervisor.state.isConnecting, true)
        XCTAssertEqual(launcher.launches.count, 1)
        let script = launcher.last!.script
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh"))
        XCTAssertTrue(script.contains("/usr/bin/ssh -M -N -f -o ControlPath=\(socketPath)"))
        XCTAssertTrue(script.contains("-D 1080 -- tg"))
        XCTAssertTrue(script.contains(supervisor.statusFileURL.path))
        XCTAssertEqual(launcher.last!.name, "Gateway")
        XCTAssertEqual(environment.preparedDirectories, [socketPath])
        XCTAssertEqual(supervisor.controlPath?.path, socketPath)
        XCTAssertTrue(supervisor.lastCommandLine.hasPrefix("/usr/bin/ssh -M -N -f"))
    }

    func testForwardsFromConfigAreNotDuplicated() async {
        environment.resolved!.destination.configuredForwards = [Forward.dynamic(port: 1080)]
        supervisor.start()
        await drainMainQueue()
        XCTAssertFalse(launcher.last!.script.contains("-D 1080"), "the config's DynamicForward 1080 stays active; adding it again would fail to bind")
        XCTAssertFalse(supervisor.lastCommandLine.contains("ClearAllForwardings"))
    }

    func testInvalidTunnelDoesNotStart() async {
        supervisor = makeSupervisor(Tunnel(name: "x", host: ""))
        supervisor.start()
        await drainMainQueue()
        XCTAssertEqual(supervisor.state, .idle)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertNotNil(supervisor.lastError)
    }

    func testPollWhileConnectingThenConnected() async throws {
        supervisor.start()
        await drainMainQueue()
        await supervisor.poll()
        XCTAssertTrue(supervisor.state.isConnecting, "Duo still being answered in Terminal")

        // ssh -f returned 0, then the socket answers.
        try writeStatus(0)
        socket.running[socketPath] = 4242
        await supervisor.poll()
        guard case .connected(let pid, _) = supervisor.state else { return XCTFail("expected connected, got \(supervisor.state)") }
        XCTAssertEqual(pid, 4242)
        XCTAssertFalse(FileManager.default.fileExists(atPath: supervisor.statusFileURL.path), "status file consumed")
        XCTAssertTrue(notifier.cleared.contains("dropped-\(tunnel.id.uuidString)"))
        XCTAssertNil(supervisor.lastError)
        XCTAssertNotNil(supervisor.lastChecked)
    }

    func testLaunchFailureFromStatusFile() async throws {
        supervisor.start()
        await drainMainQueue()
        try writeStatus(255)
        await supervisor.poll()
        XCTAssertEqual(supervisor.state, .failed(reason: "ssh exited with status 255 — see the Terminal window"))
        XCTAssertEqual(notifier.posted.last?.title, "Gateway did not connect")
        XCTAssertEqual(supervisor.lastError, "ssh exited with status 255 — see the Terminal window")
        XCTAssertEqual(socket.checks.count, 0, "no socket check after a failed launch")
    }

    func testConnectTimeout() async {
        supervisor.connectTimeout = 0
        supervisor.start()
        await drainMainQueue()
        try? await Task.sleep(nanoseconds: 10_000_000)
        await supervisor.poll()
        XCTAssertEqual(supervisor.state, .failed(reason: "No control socket after the connect timeout"))
    }

    func testStopSendsExitAndWaitsForSocket() async {
        socket.running[socketPath] = 1
        await supervisor.poll()
        XCTAssertTrue(supervisor.state.isConnected, "adopted a running master")
        supervisor.stop()
        await drainMainQueue()
        XCTAssertEqual(socket.exits, [socketPath])
        XCTAssertNil(socket.running[socketPath])
        XCTAssertEqual(supervisor.state, .disconnecting)
        await supervisor.poll()
        XCTAssertEqual(supervisor.state, .idle)
    }

    func testStopWhenNothingListensGoesIdleImmediately() async {
        supervisor.start()
        await drainMainQueue()
        socket.exitSucceeds = false
        supervisor.stop()
        await drainMainQueue()
        XCTAssertEqual(supervisor.state, .idle)
    }

    func testDropIsNotifiedAndNotRelaunched() async {
        socket.running[socketPath] = 9
        await supervisor.poll()
        socket.running.removeAll()
        await supervisor.poll()
        XCTAssertEqual(supervisor.state, .dropped(reason: "Control socket is gone"))
        XCTAssertEqual(notifier.posted.last?.title, "Gateway dropped")
        await supervisor.poll()
        XCTAssertEqual(launcher.launches.count, 0, "never reopens Terminal on its own")
        // Re-established by hand in a terminal → back to connected.
        socket.running[socketPath] = 10
        await supervisor.poll()
        XCTAssertTrue(supervisor.state.isConnected)
    }

    func testMarkExpectedUpOnlyWhenNotRunning() async {
        supervisor.markExpectedUp()
        XCTAssertEqual(supervisor.state, .dropped(reason: "Was connected when Lincoln last quit"))
        supervisor.start()
        await drainMainQueue()
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testResolveFailureFails() async {
        environment.resolved = nil
        supervisor.start()
        await drainMainQueue()
        guard case .failed = supervisor.state else { return XCTFail("expected failed, got \(supervisor.state)") }
        XCTAssertTrue(supervisor.lastError!.contains("Could not resolve ssh configuration"))
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testLauncherErrorFails() async {
        launcher.launchError = TerminalLauncherError.terminalNotFound
        supervisor.start()
        await drainMainQueue()
        guard case .failed = supervisor.state else { return XCTFail("expected failed, got \(supervisor.state)") }
        XCTAssertEqual(supervisor.lastError, "Terminal.app was not found.")
    }

    func testFallbackControlPathIsLogged() async {
        environment.resolved = ResolvedControlPath(path: "/tmp/lincoln-tests/sockets/lincoln-alice@h:22", isFromConfig: false,
                                                   destination: SSHDestination(user: "alice", hostName: "h", port: 22, configuredControlPath: nil))
        supervisor.start()
        await drainMainQueue()
        XCTAssertEqual(supervisor.controlPath?.isFromConfig, false)
        XCTAssertTrue(launcher.last!.script.contains("ControlPath=/tmp/lincoln-tests/sockets/lincoln-alice@h:22"))
    }

    func testOpenSessionSharesMaster() async {
        socket.running[socketPath] = 1
        await supervisor.poll()
        supervisor.openSession()
        XCTAssertEqual(launcher.last?.name, "Gateway-session")
        XCTAssertTrue(launcher.last!.script.contains("exec /usr/bin/ssh -o ControlPath=\(socketPath) -- tg"))
        XCTAssertEqual(supervisor.sessionCommandLine(), "/usr/bin/ssh -o ControlPath=\(socketPath) -- tg")
    }

    func testEditingInvalidatesResolvedPath() async {
        await supervisor.poll()
        XCTAssertEqual(environment.resolveCalls, 1)
        await supervisor.poll()
        XCTAssertEqual(environment.resolveCalls, 1, "cached")
        supervisor.invalidateControlPath()
        await supervisor.poll()
        XCTAssertEqual(environment.resolveCalls, 2)
    }
}
