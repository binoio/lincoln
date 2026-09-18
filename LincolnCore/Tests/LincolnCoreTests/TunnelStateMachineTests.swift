import XCTest
@testable import LincolnCore

final class TunnelStateMachineTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private var machine: TunnelStateMachine!

    override func setUp() {
        machine = TunnelStateMachine(
            policy: ReconnectPolicy(baseDelay: 1, maximumDelay: 60, maximumInitialAttempts: 3, jitterFraction: 0),
            autoReconnect: true,
            now: { self.epoch },
            random: { $0.lowerBound }
        )
    }

    func testHappyPathWithDuoPrompt() {
        var (state, effects) = machine.transition(.idle, on: .start)
        XCTAssertEqual(state, .connecting(attempt: 1))
        XCTAssertEqual(effects, [.spawn])

        (state, effects) = machine.transition(state, on: .promptDetected("Passcode or option (1-2):"))
        XCTAssertEqual(state, .waitingForInput(prompt: "Passcode or option (1-2):", attempt: 1))
        XCTAssertEqual(effects, [.notifyAttention(prompt: "Passcode or option (1-2):")])

        (state, effects) = machine.transition(state, on: .inputSubmitted)
        XCTAssertEqual(state, .connecting(attempt: 1))
        XCTAssertEqual(effects, [.clearAttention])

        (state, effects) = machine.transition(state, on: .readySeen)
        XCTAssertEqual(state, .connected(since: epoch))
        XCTAssertEqual(effects, [.clearAttention, .notifyConnected])

        (state, effects) = machine.transition(state, on: .stop)
        XCTAssertEqual(state, .disconnecting)
        XCTAssertEqual(effects, [.kill, .clearAttention])

        (state, effects) = machine.transition(state, on: .processExited(status: 0, output: ""))
        XCTAssertEqual(state, .idle)
    }

    func testInitialFailuresBackOffThenGiveUp() {
        var state = TunnelState.connecting(attempt: 1)
        var effects: [TunnelEffect]
        (state, effects) = machine.transition(state, on: .processExited(status: 255, output: "ssh: connect to host tg port 22: Network is unreachable"))
        XCTAssertEqual(state, .reconnecting(attempt: 2, nextAttemptAt: epoch.addingTimeInterval(1)))
        XCTAssertEqual(effects.first, .scheduleBackoff(1))

        (state, effects) = machine.transition(state, on: .backoffElapsed)
        XCTAssertEqual(state, .connecting(attempt: 2))
        XCTAssertEqual(effects, [.spawn])

        (state, _) = machine.transition(state, on: .processExited(status: 255, output: ""))
        XCTAssertEqual(state, .reconnecting(attempt: 3, nextAttemptAt: epoch.addingTimeInterval(2)))
        (state, _) = machine.transition(state, on: .backoffElapsed)
        (state, effects) = machine.transition(state, on: .processExited(status: 255, output: "ssh: Could not resolve hostname tg"))
        XCTAssertEqual(state, .failed(reason: "ssh: Could not resolve hostname tg"))
        XCTAssertEqual(effects, [.notifyDisconnected(reason: "ssh: Could not resolve hostname tg")])
    }

    func testExitWhileWaitingForInputNeverRetries() {
        let (state, effects) = machine.transition(.waitingForInput(prompt: "Passcode:", attempt: 1), on: .processExited(status: 255, output: "Permission denied (keyboard-interactive)."))
        XCTAssertEqual(state, .failed(reason: "Permission denied (keyboard-interactive)."))
        XCTAssertTrue(effects.contains(.clearAttention))
    }

    func testDropAfterConnectedReconnectsIndefinitely() {
        // Reach connected once so the session is marked as having connected.
        var (state, effects) = machine.transition(.connecting(attempt: 1), on: .readySeen)
        XCTAssertEqual(state, .connected(since: epoch))
        (state, effects) = machine.transition(state, on: .processExited(status: 255, output: "Timeout, server tg not responding."))
        XCTAssertEqual(state, .reconnecting(attempt: 1, nextAttemptAt: epoch.addingTimeInterval(1)))
        XCTAssertEqual(effects, [.scheduleBackoff(1), .notifyDisconnected(reason: "Timeout, server tg not responding.")])
        // Attempts after a drop are not bounded by maximumInitialAttempts (3 here).
        for attempt in 1...10 {
            (state, _) = machine.transition(state, on: .backoffElapsed)
            XCTAssertEqual(state, .connecting(attempt: attempt))
            (state, effects) = machine.transition(state, on: .processExited(status: 255, output: ""))
            XCTAssertEqual(state.attempt, attempt + 1)
            XCTAssertEqual(effects.first, .scheduleBackoff(min(60, pow(2, Double(attempt - 1)))))
        }
        // A user stop resets the session; the next start is bounded again.
        (state, _) = machine.transition(state, on: .stop)
        XCTAssertEqual(state, .idle)
        (state, _) = machine.transition(state, on: .start)
        for _ in 1...2 {
            (state, _) = machine.transition(state, on: .processExited(status: 255, output: ""))
            (state, _) = machine.transition(state, on: .backoffElapsed)
        }
        (state, _) = machine.transition(state, on: .processExited(status: 255, output: ""))
        XCTAssertEqual(state, .failed(reason: "ssh exited with status 255"))
    }

    func testAutoReconnectOffFailsImmediately() {
        machine.autoReconnect = false
        let (dropped, _) = machine.transition(.connected(since: epoch), on: .processExited(status: 0, output: ""))
        XCTAssertEqual(dropped, .failed(reason: "Connection closed"))
        let (initial, _) = machine.transition(.connecting(attempt: 1), on: .processExited(status: 1, output: ""))
        XCTAssertEqual(initial, .failed(reason: "ssh exited with status 1"))
    }

    func testLinkLostRestartsAConnectedTunnel() {
        var (state, effects) = machine.transition(.connected(since: epoch), on: .linkLost)
        XCTAssertEqual(state, .restarting)
        XCTAssertEqual(effects.first, .kill)
        (state, effects) = machine.transition(state, on: .processExited(status: 255, output: ""))
        XCTAssertEqual(state, .reconnecting(attempt: 1, nextAttemptAt: epoch))
        XCTAssertEqual(effects, [.scheduleBackoff(0)])
        (state, _) = machine.transition(state, on: .backoffElapsed)
        XCTAssertEqual(state, .connecting(attempt: 1))
    }

    func testLinkLostWhileReconnectingSkipsBackoff() {
        let (state, effects) = machine.transition(.reconnecting(attempt: 4, nextAttemptAt: epoch.addingTimeInterval(30)), on: .linkLost)
        XCTAssertEqual(state, .connecting(attempt: 4))
        XCTAssertEqual(effects, [.cancelBackoff, .spawn])
    }

    func testStopWhileReconnectingCancelsBackoff() {
        let (state, effects) = machine.transition(.reconnecting(attempt: 2, nextAttemptAt: epoch), on: .stop)
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(effects, [.cancelBackoff])
    }

    func testStartWhileReconnectingSpawnsNow() {
        let (state, effects) = machine.transition(.reconnecting(attempt: 2, nextAttemptAt: epoch), on: .start)
        XCTAssertEqual(state, .connecting(attempt: 3))
        XCTAssertEqual(effects, [.cancelBackoff, .spawn])
    }

    func testIgnoredEvents() {
        XCTAssertEqual(machine.transition(.idle, on: .stop).0, .idle)
        XCTAssertEqual(machine.transition(.idle, on: .readySeen).0, .idle)
        XCTAssertEqual(machine.transition(.idle, on: .backoffElapsed).0, .idle)
        XCTAssertEqual(machine.transition(.idle, on: .linkLost).0, .idle)
        XCTAssertEqual(machine.transition(.connected(since: epoch), on: .promptDetected("x")).0, .connected(since: epoch))
        XCTAssertEqual(machine.transition(.connected(since: epoch), on: .start).0, .connected(since: epoch))
        XCTAssertEqual(machine.transition(.failed(reason: "x"), on: .processExited(status: 1, output: "")).0, .failed(reason: "x"))
    }

    func testFailureReasonSkipsSentinelAndBlankLines() {
        let reason = TunnelStateMachine.failureReason(status: 255, output: "LINCOLN_READY_x\n\n  Connection closed by remote host  \n\n")
        XCTAssertEqual(reason, "Connection closed by remote host")
    }

    func testStateHelpers() {
        XCTAssertTrue(TunnelState.connected(since: epoch).isConnected)
        XCTAssertTrue(TunnelState.waitingForInput(prompt: "", attempt: 1).isWaitingForInput)
        XCTAssertTrue(TunnelState.reconnecting(attempt: 1, nextAttemptAt: epoch).isActive)
        XCTAssertFalse(TunnelState.reconnecting(attempt: 1, nextAttemptAt: epoch).isRunningProcess)
        XCTAssertTrue(TunnelState.disconnecting.isRunningProcess)
        XCTAssertFalse(TunnelState.disconnecting.isActive)
        XCTAssertEqual(TunnelState.connecting(attempt: 3).label, "Connecting (attempt 3)")
        XCTAssertEqual(TunnelState.connecting(attempt: 1).label, "Connecting")
    }
}
