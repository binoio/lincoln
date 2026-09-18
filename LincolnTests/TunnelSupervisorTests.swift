import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class TunnelSupervisorTests: XCTestCase {
    private var factory: MockTunnelProcessFactory!
    private var environment: MockSSHEnvironment!
    private var notifier: MockNotifier!
    private var scheduler: ManualScheduler!
    private var tunnel: Tunnel!
    private var supervisor: TunnelSupervisor!

    override func setUp() async throws {
        factory = MockTunnelProcessFactory()
        environment = MockSSHEnvironment()
        notifier = MockNotifier()
        scheduler = ManualScheduler()
        tunnel = TestFixtures.tunnel()
        supervisor = makeSupervisor(tunnel)
    }

    private func makeSupervisor(_ tunnel: Tunnel) -> TunnelSupervisor {
        TunnelSupervisor(
            tunnel: tunnel,
            processFactory: factory,
            environment: environment,
            notifier: notifier,
            policy: ReconnectPolicy(baseDelay: 1, maximumDelay: 60, maximumInitialAttempts: 3, jitterFraction: 0),
            scheduler: scheduler.scheduler
        )
    }

    private var sentinel: String { SSHCommandBuilder.readySentinel(for: tunnel.id) }

    private func startAndSpawn() async -> MockTunnelProcess {
        supervisor.start()
        await drainMainQueue()
        return factory.last!
    }

    func testStartSpawnsSSHWithBuiltArguments() async {
        let process = await startAndSpawn()
        XCTAssertEqual(supervisor.state, .connecting(attempt: 1))
        XCTAssertTrue(process.started)
        XCTAssertEqual(process.executable, "/usr/bin/ssh")
        XCTAssertEqual(process.arguments, SSHCommandBuilder.arguments(for: tunnel, environment: environment.builderEnvironment))
        XCTAssertEqual(process.environment["TERM"], "dumb")
        XCTAssertTrue(supervisor.lastCommandLine.contains("-- tg"))
        XCTAssertTrue(supervisor.console.text.contains("/usr/bin/ssh -N"))
        XCTAssertEqual(environment.resolveCalls, 0, "ControlPath is only resolved when sharing is on")
    }

    func testInvalidTunnelDoesNotStart() {
        supervisor = makeSupervisor(Tunnel(name: "x", host: ""))
        supervisor.start()
        XCTAssertEqual(supervisor.state, .idle)
        XCTAssertTrue(factory.processes.isEmpty)
        XCTAssertNotNil(supervisor.lastError)
    }

    func testDuoPromptFlowToConnected() async {
        let process = await startAndSpawn()
        process.emit("Duo two-factor login for alice\n\n 1. Duo Push to XXX-XXX-1234\n 2. Phone call\n\nPasscode or option (1-2): ")
        XCTAssertEqual(supervisor.state, .connecting(attempt: 1), "prompt is not declared until the output goes quiet")
        scheduler.fireAll()
        XCTAssertEqual(supervisor.state, .waitingForInput(prompt: "Passcode or option (1-2):", attempt: 1))
        XCTAssertTrue(supervisor.needsAttention)
        XCTAssertEqual(supervisor.currentPrompt?.kind, .passcode)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted.first?.title, "Gateway needs your input")

        supervisor.submitInput("1")
        XCTAssertEqual(process.writes, ["1\n"])
        XCTAssertEqual(supervisor.state, .connecting(attempt: 1))
        XCTAssertFalse(supervisor.needsAttention)
        XCTAssertTrue(notifier.cleared.contains("attention-\(tunnel.id.uuidString)"))

        process.emit("1\r\nSuccess. Logging you in...\r\n\(sentinel)\r\n")
        XCTAssertTrue(supervisor.state.isConnected)
        XCTAssertTrue(supervisor.console.text.contains("— connected"))
        XCTAssertFalse(supervisor.console.text.contains("\r"))
    }

    func testSecretPromptIsHiddenAndPartialChunksJoin() async {
        let process = await startAndSpawn()
        process.emit("Enter passphrase for key '/Users/alice/.ssh/id_ed25519'")
        process.emit(": ")
        scheduler.fireAll()
        XCTAssertEqual(supervisor.currentPrompt?.isSecret, true)
        XCTAssertTrue(supervisor.state.isWaitingForInput)
    }

    func testPromptTimerIsCancelledWhenMoreOutputArrives() async {
        let process = await startAndSpawn()
        process.emit("Warning: something:")
        process.emit(" more text\n")
        scheduler.fireAll()
        XCTAssertEqual(supervisor.state, .connecting(attempt: 1))
        XCTAssertNil(supervisor.currentPrompt)
    }

    func testSentinelFromPreviousRunDoesNotCountForNewRun() async {
        let first = await startAndSpawn()
        first.emit("\(sentinel)\n")
        XCTAssertTrue(supervisor.state.isConnected)
        first.exit(status: 255)
        XCTAssertEqual(supervisor.state.attempt, 1)
        guard case .reconnecting = supervisor.state else { return XCTFail("expected reconnecting, got \(supervisor.state)") }
        scheduler.fire { $0 >= 1 }
        await drainMainQueue()
        XCTAssertEqual(supervisor.state, .connecting(attempt: 1))
        let second = factory.last!
        XCTAssertNotIdentical(first, second)
        second.emit("banner\n")
        XCTAssertEqual(supervisor.state, .connecting(attempt: 1), "old sentinel in the console must not mark the new run connected")
        second.emit("\(sentinel)\n")
        XCTAssertTrue(supervisor.state.isConnected)
    }

    func testInitialFailureBacksOffThenGivesUp() async {
        let first = await startAndSpawn()
        first.exit(status: 255)
        XCTAssertEqual(supervisor.state, .reconnecting(attempt: 2, nextAttemptAt: supervisor.state.nextAttemptAt!))
        XCTAssertEqual(scheduler.pending.map(\.delay), [1])
        scheduler.fireAll()
        await drainMainQueue()
        XCTAssertEqual(factory.processes.count, 2)
        factory.last!.exit(status: 255)
        scheduler.fireAll()
        await drainMainQueue()
        XCTAssertEqual(factory.processes.count, 3)
        factory.last!.emit("ssh: Could not resolve hostname tg: nodename nor servname provided\r\n")
        factory.last!.exit(status: 255)
        XCTAssertEqual(supervisor.state, .failed(reason: "ssh: Could not resolve hostname tg: nodename nor servname provided"))
        XCTAssertEqual(supervisor.lastError, "ssh: Could not resolve hostname tg: nodename nor servname provided")
        XCTAssertEqual(notifier.posted.last?.title, "Gateway disconnected")
    }

    func testStopTerminatesAndReturnsToIdle() async {
        let process = await startAndSpawn()
        process.emit("\(sentinel)\n")
        supervisor.stop()
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(supervisor.state, .idle)
        XCTAssertTrue(supervisor.console.text.contains("ssh exited (143)"))
    }

    func testStopWhileReconnectingCancelsTimer() async {
        let process = await startAndSpawn()
        process.exit(status: 1)
        XCTAssertEqual(scheduler.pending.count, 1)
        supervisor.stop()
        XCTAssertEqual(supervisor.state, .idle)
        XCTAssertTrue(scheduler.pending.isEmpty)
        scheduler.fireAll()
        await drainMainQueue()
        XCTAssertEqual(factory.processes.count, 1, "cancelled backoff must not spawn")
    }

    func testStopDuringControlPathResolutionDoesNotSpawn() async {
        var shared = tunnel!
        shared.shareControlMaster = true
        supervisor = makeSupervisor(shared)
        environment.controlPathToReturn = "/tmp/sockets/socket-alice@tg:22"
        supervisor.start()
        // Stop before the async resolution completes.
        supervisor.stop()
        await drainMainQueue()
        XCTAssertTrue(factory.processes.isEmpty)
        XCTAssertEqual(supervisor.state, .idle, "nothing to kill, so the stop completes immediately")
        // A later start works normally.
        _ = await startAndSpawn()
        XCTAssertEqual(factory.processes.count, 1)
        XCTAssertEqual(supervisor.state, .connecting(attempt: 1))
    }

    func testControlMasterArgumentsWhenShared() async {
        var shared = tunnel!
        shared.shareControlMaster = true
        supervisor = makeSupervisor(shared)
        environment.controlPathToReturn = "/tmp/sockets/socket-alice@tg:22"
        let process = await startAndSpawn()
        XCTAssertEqual(environment.resolveCalls, 1)
        XCTAssertEqual(environment.preparedDirectories, ["/tmp/sockets/socket-alice@tg:22"])
        XCTAssertTrue(process.arguments.contains("ControlMaster=yes"))
        XCTAssertTrue(process.arguments.contains("ControlPath=/tmp/sockets/socket-alice@tg:22"))
    }

    func testControlMasterFallsBackWhenPathIsNone() async {
        var shared = tunnel!
        shared.shareControlMaster = true
        supervisor = makeSupervisor(shared)
        environment.controlPathToReturn = nil
        let process = await startAndSpawn()
        XCTAssertTrue(process.arguments.contains("ControlMaster=no"))
        XCTAssertTrue(supervisor.console.text.contains("will not be shared"))
    }

    func testLinkLostRestartsConnectedTunnel() async {
        let process = await startAndSpawn()
        process.emit("\(sentinel)\n")
        supervisor.linkLost()
        XCTAssertEqual(supervisor.state, .reconnecting(attempt: 1, nextAttemptAt: supervisor.state.nextAttemptAt!))
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(scheduler.pending.map(\.delay), [0])
        scheduler.fireAll()
        await drainMainQueue()
        XCTAssertEqual(factory.processes.count, 2)
    }

    func testLinkLostIsIgnoredWhenIdle() {
        supervisor.linkLost()
        XCTAssertEqual(supervisor.state, .idle)
    }

    func testLaunchFailureIsReported() async {
        struct Boom: LocalizedError { var errorDescription: String? { "forkpty failed: boom" } }
        factory.configure = { $0.startError = Boom() }
        supervisor = makeSupervisor(TestFixtures.tunnel(autoReconnect: false))
        supervisor.start()
        await drainMainQueue()
        XCTAssertEqual(supervisor.state, .failed(reason: "forkpty failed: boom"))
        XCTAssertTrue(supervisor.console.text.contains("failed to launch ssh"))
    }

    func testAutoReconnectOffStopsAfterDrop() async {
        supervisor = makeSupervisor(TestFixtures.tunnel(autoReconnect: false))
        let process = await startAndSpawn()
        process.emit("\(sentinel)\n")
        process.exit(status: 255)
        guard case .failed = supervisor.state else { return XCTFail("expected failed, got \(supervisor.state)") }
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testUpdatingTunnelUpdatesReconnectPolicy() async {
        var updated = tunnel!
        updated.autoReconnect = false
        supervisor.tunnel = updated
        let process = await startAndSpawn()
        process.exit(status: 1)
        guard case .failed = supervisor.state else { return XCTFail("expected failed, got \(supervisor.state)") }
    }

    func testInterruptAndClear() async {
        let process = await startAndSpawn()
        process.emit("hello\n")
        supervisor.sendInterrupt()
        XCTAssertEqual(process.writes, ["\u{03}"])
        supervisor.clearConsole()
        XCTAssertEqual(supervisor.console.text, "")
    }
}

private extension TunnelState {
    var nextAttemptAt: Date? {
        if case .reconnecting(_, let date) = self { return date }
        return nil
    }
}
