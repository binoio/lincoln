import XCTest
@testable import LincolnCore

final class TunnelStateMachineTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private var machine: TunnelStateMachine!

    override func setUp() {
        machine = TunnelStateMachine(now: { self.epoch })
    }

    func testHappyPath() {
        var (state, effects) = machine.transition(.idle, on: .start)
        XCTAssertEqual(state, .connecting(since: epoch))
        XCTAssertEqual(effects, [.launch])

        (state, effects) = machine.transition(state, on: .masterMissing)
        XCTAssertEqual(state, .connecting(since: epoch), "no socket yet while Duo is answered in Terminal")
        XCTAssertEqual(effects, [])

        (state, effects) = machine.transition(state, on: .launchExited(status: 0))
        XCTAssertEqual(state, .connecting(since: epoch))
        XCTAssertEqual(effects, [.log("ssh backgrounded; confirming control socket")])

        (state, effects) = machine.transition(state, on: .masterRunning(pid: 42))
        XCTAssertEqual(state, .connected(pid: 42, since: epoch))
        XCTAssertEqual(effects, [.notifyConnected])

        (state, effects) = machine.transition(state, on: .masterRunning(pid: 42))
        XCTAssertEqual(effects, [])

        (state, effects) = machine.transition(state, on: .stop)
        XCTAssertEqual(state, .disconnecting)
        XCTAssertEqual(effects, [.sendExit])

        (state, effects) = machine.transition(state, on: .masterRunning(pid: 42))
        XCTAssertEqual(state, .disconnecting, "the master may take a moment to go")

        (state, effects) = machine.transition(state, on: .masterMissing)
        XCTAssertEqual(state, .idle)
    }

    func testLaunchFailureAndTimeout() {
        let (failed, effects) = machine.transition(.connecting(since: epoch), on: .launchExited(status: 255))
        XCTAssertEqual(failed, .failed(reason: "ssh exited with status 255"))
        XCTAssertEqual(effects, [.notifyFailed(reason: "ssh exited with status 255")])

        let (notStarted, _) = machine.transition(.connecting(since: epoch), on: .launchFailed(reason: "Terminal.app was not found."))
        XCTAssertEqual(notStarted, .failed(reason: "Terminal.app was not found."))
        XCTAssertEqual(machine.transition(.idle, on: .launchFailed(reason: "x")).0, .idle)

        let (timedOut, _) = machine.transition(.connecting(since: epoch), on: .connectTimedOut)
        XCTAssertEqual(timedOut, .failed(reason: "No control socket after the connect timeout"))

        // Retrying from failed launches Terminal again.
        let (retry, retryEffects) = machine.transition(failed, on: .start)
        XCTAssertEqual(retry, .connecting(since: epoch))
        XCTAssertEqual(retryEffects, [.launch])
    }

    func testDropIsNotifiedAndNeverAutoReconnects() {
        let (dropped, effects) = machine.transition(.connected(pid: 1, since: epoch), on: .masterMissing)
        XCTAssertEqual(dropped, .dropped(reason: "Control socket is gone"))
        XCTAssertEqual(effects, [.notifyDropped(reason: "Control socket is gone")])
        XCTAssertTrue(dropped.needsAttention)
        XCTAssertFalse(dropped.isActive)
        // Stays dropped across further checks; only a user start relaunches.
        XCTAssertEqual(machine.transition(dropped, on: .masterMissing).0, dropped)
        XCTAssertEqual(machine.transition(dropped, on: .start).1, [.launch])
        // A user stop acknowledges the drop.
        XCTAssertEqual(machine.transition(dropped, on: .stop).0, .idle)
    }

    func testExternallyStartedMasterIsAdopted() {
        let (state, effects) = machine.transition(.idle, on: .masterRunning(pid: 7))
        XCTAssertEqual(state, .connected(pid: 7, since: epoch))
        XCTAssertEqual(effects, [.log("Adopted control master started outside Lincoln")])
        // …and a dropped tunnel re-established from a terminal comes back.
        let (back, backEffects) = machine.transition(.dropped(reason: "x"), on: .masterRunning(pid: 8))
        XCTAssertEqual(back, .connected(pid: 8, since: epoch))
        XCTAssertEqual(backEffects, [.notifyConnected])
    }

    func testPIDUpdatesWithoutNotification() {
        let (state, effects) = machine.transition(.connected(pid: nil, since: epoch), on: .masterRunning(pid: 9))
        XCTAssertEqual(state, .connected(pid: 9, since: epoch))
        XCTAssertEqual(effects, [])
    }

    func testRestoreExpectedUpMarksDropped() {
        let (state, _) = machine.transition(.idle, on: .restoreExpectedUp)
        XCTAssertEqual(state, .dropped(reason: "Was connected when Lincoln last quit"))
        XCTAssertEqual(machine.transition(.connected(pid: 1, since: epoch), on: .restoreExpectedUp).0, .connected(pid: 1, since: epoch))
    }

    func testIgnoredEvents() {
        XCTAssertEqual(machine.transition(.idle, on: .stop).0, .idle)
        XCTAssertEqual(machine.transition(.idle, on: .masterMissing).0, .idle)
        XCTAssertEqual(machine.transition(.idle, on: .launchExited(status: 1)).0, .idle)
        XCTAssertEqual(machine.transition(.connected(pid: 1, since: epoch), on: .connectTimedOut).0, .connected(pid: 1, since: epoch))
        XCTAssertEqual(machine.transition(.connected(pid: 1, since: epoch), on: .start).0, .connected(pid: 1, since: epoch))
        XCTAssertEqual(machine.transition(.disconnecting, on: .start).1, [.log("Still disconnecting; try again in a moment")])
    }

    func testStateHelpers() {
        XCTAssertTrue(TunnelState.connected(pid: nil, since: epoch).isConnected)
        XCTAssertTrue(TunnelState.connecting(since: epoch).isConnecting)
        XCTAssertTrue(TunnelState.connecting(since: epoch).isActive)
        XCTAssertFalse(TunnelState.disconnecting.isActive)
        XCTAssertTrue(TunnelState.failed(reason: "x").needsAttention)
        XCTAssertEqual(TunnelState.failed(reason: "x").detail, "x")
        XCTAssertNil(TunnelState.idle.detail)
        XCTAssertEqual(TunnelState.connecting(since: epoch).label, "Connecting")
    }
}
