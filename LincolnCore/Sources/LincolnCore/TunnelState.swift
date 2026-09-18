//
//  TunnelState.swift
//  LincolnCore
//
//  The per-tunnel state machine as a pure function. A tunnel is up when its
//  ssh ControlMaster socket answers `ssh -O check`; the app's TunnelSupervisor
//  feeds observations in and executes the returned effects.
//

import Foundation

public enum TunnelState: Equatable {
    /// No control master for this tunnel.
    case idle
    /// A Terminal window is running ssh; waiting for the socket to appear.
    case connecting(since: Date)
    case connected(pid: Int32?, since: Date)
    /// `ssh -O exit` was sent; waiting for the socket to disappear.
    case disconnecting
    /// Was connected (this session or the last one) and the socket is gone.
    /// Reconnecting is the user's call because it may cost a Duo push.
    case dropped(reason: String)
    /// The ssh launched in Terminal exited without establishing the master.
    case failed(reason: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// True while the user's intent is "up".
    public var isActive: Bool {
        switch self {
        case .connecting, .connected: return true
        case .idle, .disconnecting, .dropped, .failed: return false
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .dropped, .failed: return true
        default: return false
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting in Terminal"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting"
        case .dropped: return "Dropped"
        case .failed: return "Failed"
        }
    }

    public var detail: String? {
        switch self {
        case .dropped(let reason), .failed(let reason): return reason
        default: return nil
        }
    }
}

public enum TunnelEvent: Equatable {
    /// User (or launch auto-connect) asked for the tunnel to be up.
    case start
    /// User asked for the tunnel to be down.
    case stop
    /// `ssh -O check` found a running master.
    case masterRunning(pid: Int32?)
    /// `ssh -O check` found no master (socket missing or dead).
    case masterMissing
    /// The ssh started in Terminal exited (status from the .command script).
    case launchExited(status: Int32)
    /// Lincoln could not even start ssh (ssh -G failed, Terminal missing…).
    case launchFailed(reason: String)
    /// Nothing answered within the connect timeout.
    case connectTimedOut
    /// Lincoln was launched and the tunnel was up when it last quit.
    case restoreExpectedUp
}

public enum TunnelEffect: Equatable {
    case launchInTerminal
    case sendExit
    case notifyConnected
    case notifyDropped(reason: String)
    case notifyFailed(reason: String)
    case log(String)
}

public struct TunnelStateMachine {
    public var now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func transition(_ state: TunnelState, on event: TunnelEvent) -> (TunnelState, [TunnelEffect]) {
        switch (state, event) {

        // MARK: Starting
        case (.idle, .start), (.dropped, .start), (.failed, .start):
            return (.connecting(since: now()), [.launchInTerminal])
        case (.connecting, .start), (.connected, .start):
            return (state, [])
        case (.disconnecting, .start):
            return (state, [.log("Still disconnecting; try again in a moment")])

        // MARK: Stopping
        case (.connecting, .stop), (.connected, .stop):
            return (.disconnecting, [.sendExit])
        case (.dropped, .stop), (.failed, .stop):
            return (.idle, [])
        case (.idle, .stop), (.disconnecting, .stop):
            return (state, [])

        // MARK: Socket observations
        case (.connecting, .masterRunning(let pid)):
            return (.connected(pid: pid, since: now()), [.notifyConnected])
        case (.connected(let oldPid, let since), .masterRunning(let pid)):
            if oldPid == pid { return (state, []) }
            return (.connected(pid: pid ?? oldPid, since: since), [])
        case (.idle, .masterRunning(let pid)):
            // Started outside Lincoln (e.g. `ssh tg` in a terminal): adopt it.
            return (.connected(pid: pid, since: now()), [.log("Adopted control master started outside Lincoln")])
        case (.dropped, .masterRunning(let pid)), (.failed, .masterRunning(let pid)):
            return (.connected(pid: pid, since: now()), [.notifyConnected])
        case (.disconnecting, .masterRunning):
            return (state, [])

        case (.connected, .masterMissing):
            let reason = "Control socket is gone"
            return (.dropped(reason: reason), [.notifyDropped(reason: reason)])
        case (.disconnecting, .masterMissing):
            return (.idle, [.log("Control master exited")])
        case (.connecting, .masterMissing), (.idle, .masterMissing), (.dropped, .masterMissing), (.failed, .masterMissing):
            return (state, [])

        // MARK: Launch outcome
        case (.connecting, .launchExited(let status)):
            if status == 0 {
                // ssh -f returned after auth; the next check confirms the socket.
                return (state, [.log("ssh backgrounded; confirming control socket")])
            }
            let reason = "ssh exited with status \(status) — see the Terminal window"
            return (.failed(reason: reason), [.notifyFailed(reason: reason)])
        case (_, .launchExited):
            return (state, [])
        case (.connecting, .launchFailed(let reason)):
            return (.failed(reason: reason), [.notifyFailed(reason: reason)])
        case (_, .launchFailed):
            return (state, [])

        case (.connecting, .connectTimedOut):
            let reason = "No control socket after the connect timeout"
            return (.failed(reason: reason), [.notifyFailed(reason: reason)])
        case (_, .connectTimedOut):
            return (state, [])

        // MARK: Launch restore
        case (.idle, .restoreExpectedUp):
            return (.dropped(reason: "Was connected when Lincoln last quit"), [])
        case (_, .restoreExpectedUp):
            return (state, [])
        }
    }
}
