import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class TunnelSupervisorTests: XCTestCase {
    private var launcher: MockTerminalLauncher!
    private var headless: MockHeadlessLauncher!
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
        headless = MockHeadlessLauncher()
        headless.socket = socket
        headless.socketPath = environment.resolved!.path
        notifier = MockNotifier()
        stateDirectory = TestFixtures.temporaryDirectory("state")
        tunnel = TestFixtures.tunnel()
        supervisor = makeSupervisor(tunnel)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    /// Terminal-only supervisor (silent connections off), as most of the
    /// Terminal-flow tests expect.
    private func makeSupervisor(_ tunnel: Tunnel, silent: Bool = false) -> TunnelSupervisor {
        let supervisor = TunnelSupervisor(tunnel: tunnel, launcher: launcher, headless: headless, socket: socket, environment: environment, notifier: notifier, stateDirectory: stateDirectory)
        supervisor.connectSilentlyFirst = { silent }
        return supervisor
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

    // MARK: - Silent-first launches

    func testSilentLaunchSucceedsWithoutTerminal() async {
        supervisor = makeSupervisor(tunnel, silent: true)
        supervisor.start()
        await drainMainQueue()
        XCTAssertEqual(headless.launches.count, 1)
        XCTAssertTrue(launcher.launches.isEmpty, "no Terminal window")
        XCTAssertTrue(headless.launches[0].contains("BatchMode=yes"))
        XCTAssertTrue(headless.launches[0].contains("KbdInteractiveAuthentication=no"))
        XCTAssertTrue(headless.launches[0].contains("PreferredAuthentications=publickey"))
        XCTAssertEqual(headless.timeouts, [supervisor.connectTimeout])
        XCTAssertEqual(supervisor.lastLaunchMode, .silent)
        XCTAssertTrue(supervisor.state.isConnecting)
        await supervisor.poll()
        XCTAssertTrue(supervisor.state.isConnected)
    }

    func testDuoRequirementFallsBackToTerminal() async {
        supervisor = makeSupervisor(tunnel, silent: true)
        headless.result = MockHeadlessLauncher.duoDenied
        supervisor.start()
        await drainMainQueue()
        XCTAssertEqual(headless.launches.count, 1)
        XCTAssertEqual(launcher.launches.count, 1, "Terminal opens for the Duo prompt")
        XCTAssertFalse(launcher.last!.script.contains("BatchMode"), "the Terminal run may prompt")
        XCTAssertEqual(supervisor.lastLaunchMode, .terminal(reason: "alice@tigressgateway.princeton.edu: Permission denied (keyboard-interactive)."))
        XCTAssertTrue(supervisor.state.isConnecting)
        XCTAssertNil(supervisor.lastError)
    }

    func testHardFailureReportsSSHMessageWithoutTerminal() async {
        supervisor = makeSupervisor(tunnel, silent: true)
        headless.result = MockHeadlessLauncher.refused
        supervisor.start()
        await drainMainQueue()
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(supervisor.state, .failed(reason: "ssh: connect to host tg port 22: Connection refused"))
        XCTAssertEqual(notifier.posted.last?.title, "Gateway did not connect")
    }

    func testSilentTimeoutFails() async {
        supervisor = makeSupervisor(tunnel, silent: true)
        supervisor.connectTimeout = 7
        headless.result = SSHCommandResult(standardOutput: "", standardError: "", exitCode: 143, timedOut: true)
        supervisor.start()
        await drainMainQueue()
        XCTAssertEqual(supervisor.state, .failed(reason: "ssh did not finish within 7s"))
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testSilentOffGoesStraightToTerminal() async {
        supervisor = makeSupervisor(tunnel, silent: false)
        supervisor.start()
        await drainMainQueue()
        XCTAssertTrue(headless.launches.isEmpty)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(supervisor.lastLaunchMode, .terminal(reason: "silent connections are off in Settings"))
    }

    func testStopDuringSilentLaunchIsHonored() async {
        supervisor = makeSupervisor(tunnel, silent: true)
        headless.result = MockHeadlessLauncher.duoDenied
        supervisor.start()
        supervisor.stop()
        await drainMainQueue()
        XCTAssertTrue(launcher.launches.isEmpty, "stop before the silent attempt returned must not open Terminal")
        XCTAssertEqual(supervisor.state, .idle)
    }

    // MARK: - Terminal flow

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
        XCTAssertEqual(supervisor.state, .failed(reason: "ssh exited with status 255"))
        XCTAssertEqual(notifier.posted.last?.title, "Gateway did not connect")
        XCTAssertEqual(supervisor.lastError, "ssh exited with status 255")
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

    func testSessionCommandLineSharesMaster() async {
        XCTAssertNil(supervisor.sessionCommandLine(), "unknown until the control path is resolved")
        await supervisor.poll()
        XCTAssertEqual(supervisor.sessionCommandLine(), "/usr/bin/ssh -o ControlPath=\(socketPath) -- tg")
        XCTAssertTrue(launcher.launches.isEmpty, "copying a command never opens Terminal")
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
