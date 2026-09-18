//
//  TunnelState.swift
//  LincolnCore
//
//  The per-tunnel connection state machine as a pure function: the app's
//  TunnelSupervisor feeds it events and executes the returned effects.
//

import Foundation

public enum TunnelState: Equatable {
    case idle
    /// ssh is running but has not printed the ready sentinel yet.
    /// `attempt` counts consecutive attempts that never reached `connected`.
    case connecting(attempt: Int)
    /// ssh printed something that looks like a prompt (Duo, passphrase,
    /// host key) and is waiting for the user to answer in the console.
    case waitingForInput(prompt: String, attempt: Int)
    case connected(since: Date)
    /// The link was lost or we chose to restart; waiting for backoff.
    case reconnecting(attempt: Int, nextAttemptAt: Date)
    /// Killing ssh so it can be started again (network change, wake).
    case restarting
    /// Killing ssh because the user asked to disconnect.
    case disconnecting
    case failed(reason: String)

    public var isRunningProcess: Bool {
        switch self {
        case .connecting, .waitingForInput, .connected, .restarting, .disconnecting: return true
        case .idle, .reconnecting, .failed: return false
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isWaitingForInput: Bool {
        if case .waitingForInput = self { return true }
        return false
    }

    /// True while the user's intent is "up" (connecting, connected, retrying).
    public var isActive: Bool {
        switch self {
        case .connecting, .waitingForInput, .connected, .reconnecting, .restarting: return true
        case .idle, .disconnecting, .failed: return false
        }
    }

    public var attempt: Int {
        switch self {
        case .connecting(let attempt), .waitingForInput(_, let attempt), .reconnecting(let attempt, _): return attempt
        default: return 0
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Disconnected"
        case .connecting(let attempt): return attempt > 1 ? "Connecting (attempt \(attempt))" : "Connecting"
        case .waitingForInput: return "Needs your input"
        case .connected: return "Connected"
        case .reconnecting(let attempt, _): return "Reconnecting (attempt \(attempt))"
        case .restarting: return "Restarting"
        case .disconnecting: return "Disconnecting"
        case .failed: return "Failed"
        }
    }
}

public enum TunnelEvent: Equatable {
    /// User (or launch restore) asked for the tunnel to be up.
    case start
    /// User asked for the tunnel to be down.
    case stop
    /// Console output ended in something that looks like a prompt.
    case promptDetected(String)
    /// The user answered the prompt in the console.
    case inputSubmitted
    /// The LocalCommand sentinel appeared in the output.
    case readySeen
    /// ssh exited. `output` is the trailing console output for diagnostics.
    case processExited(status: Int32, output: String)
    /// The backoff timer fired.
    case backoffElapsed
    /// Network path changed / Mac woke: restart a connected tunnel.
    case linkLost
}

public enum TunnelEffect: Equatable {
    case spawn
    case kill
    case scheduleBackoff(TimeInterval)
    case cancelBackoff
    case notifyAttention(prompt: String)
    case clearAttention
    case notifyConnected
    case notifyDisconnected(reason: String)
    case log(String)
}

public struct TunnelStateMachine {
    public var policy: ReconnectPolicy
    public var autoReconnect: Bool
    public var now: () -> Date
    public var random: (ClosedRange<Double>) -> Double
    /// Set once the current session reached `connected`; after that, retries
    /// are unbounded (a dropped link is worth waiting out indefinitely).
    /// Cleared when the tunnel comes to rest in `idle` or `failed`.
    public private(set) var hasConnectedThisSession = false

    public init(
        policy: ReconnectPolicy = .default,
        autoReconnect: Bool = true,
        now: @escaping () -> Date = Date.init,
        random: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) {
        self.policy = policy
        self.autoReconnect = autoReconnect
        self.now = now
        self.random = random
    }

    public mutating func transition(_ state: TunnelState, on event: TunnelEvent) -> (TunnelState, [TunnelEffect]) {
        let (next, effects) = step(state, on: event)
        switch next {
        case .connected: hasConnectedThisSession = true
        case .idle, .failed: hasConnectedThisSession = false
        default: break
        }
        return (next, effects)
    }

    private func step(_ state: TunnelState, on event: TunnelEvent) -> (TunnelState, [TunnelEffect]) {
        switch (state, event) {

        // MARK: Starting
        case (.idle, .start), (.failed, .start):
            return (.connecting(attempt: 1), [.spawn])
        case (.reconnecting, .start):
            // Skip the remaining backoff.
            return (.connecting(attempt: state.attempt + 1), [.cancelBackoff, .spawn])
        case (.connecting, .start), (.waitingForInput, .start), (.connected, .start), (.restarting, .start):
            return (state, [])
        case (.disconnecting, .start):
            // Let the kill finish; the supervisor re-issues .start on exit if desired.
            return (state, [])

        // MARK: Stopping
        case (.connecting, .stop), (.waitingForInput, .stop), (.connected, .stop), (.restarting, .stop):
            return (.disconnecting, [.kill, .clearAttention])
        case (.reconnecting, .stop):
            return (.idle, [.cancelBackoff])
        case (.idle, .stop), (.failed, .stop), (.disconnecting, .stop):
            return (state, [])

        // MARK: Prompts
        case (.connecting(let attempt), .promptDetected(let prompt)):
            return (.waitingForInput(prompt: prompt, attempt: attempt), [.notifyAttention(prompt: prompt)])
        case (.waitingForInput(_, let attempt), .promptDetected(let prompt)):
            return (.waitingForInput(prompt: prompt, attempt: attempt), [.notifyAttention(prompt: prompt)])
        case (.waitingForInput(_, let attempt), .inputSubmitted):
            return (.connecting(attempt: attempt), [.clearAttention])
        case (_, .promptDetected), (_, .inputSubmitted):
            return (state, [])

        // MARK: Ready
        case (.connecting, .readySeen), (.waitingForInput, .readySeen):
            return (.connected(since: now()), [.clearAttention, .notifyConnected])
        case (_, .readySeen):
            return (state, [])

        // MARK: Process exit
        case (.disconnecting, .processExited):
            return (.idle, [.log("ssh exited after disconnect request")])
        case (.restarting, .processExited):
            return (.reconnecting(attempt: 1, nextAttemptAt: now()), [.scheduleBackoff(0)])
        case (.connecting(let attempt), .processExited(let status, let output)):
            let reason = TunnelStateMachine.failureReason(status: status, output: output)
            if autoReconnect, hasConnectedThisSession || policy.allowsInitialRetry(afterAttempt: attempt) {
                let delay = policy.delay(forAttempt: attempt, random: random)
                return (.reconnecting(attempt: attempt + 1, nextAttemptAt: now().addingTimeInterval(delay)),
                        [.scheduleBackoff(delay), .log("Attempt \(attempt) failed: \(reason). Retrying in \(Int(delay.rounded()))s.")])
            }
            return (.failed(reason: reason), [.notifyDisconnected(reason: reason)])
        case (.waitingForInput, .processExited(let status, let output)):
            // A human was in the loop; do not fire another Duo push on our own.
            let reason = TunnelStateMachine.failureReason(status: status, output: output)
            return (.failed(reason: reason), [.clearAttention, .notifyDisconnected(reason: reason)])
        case (.connected, .processExited(let status, let output)):
            let reason = TunnelStateMachine.failureReason(status: status, output: output, dropped: true)
            if autoReconnect {
                let delay = policy.delay(forAttempt: 1, random: random)
                return (.reconnecting(attempt: 1, nextAttemptAt: now().addingTimeInterval(delay)),
                        [.scheduleBackoff(delay), .notifyDisconnected(reason: reason)])
            }
            return (.failed(reason: reason), [.notifyDisconnected(reason: reason)])
        case (.idle, .processExited), (.failed, .processExited), (.reconnecting, .processExited):
            return (state, [])

        // MARK: Backoff
        case (.reconnecting(let attempt, _), .backoffElapsed):
            return (.connecting(attempt: attempt), [.spawn])
        case (_, .backoffElapsed):
            return (state, [])

        // MARK: Link changes
        case (.connected, .linkLost):
            return (.restarting, [.kill, .log("Network changed; restarting tunnel")])
        case (.reconnecting, .linkLost):
            // Try again right away instead of waiting out the backoff.
            return (.connecting(attempt: state.attempt), [.cancelBackoff, .spawn])
        case (_, .linkLost):
            return (state, [])
        }
    }

    static func failureReason(status: Int32, output: String, dropped: Bool = false) -> String {
        let lastLine = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(SSHCommandBuilder.sentinelPrefix) }
            .last
        if let line = lastLine, !line.isEmpty {
            return line
        }
        if dropped {
            return status == 0 ? "Connection closed" : "Connection dropped (ssh exit \(status))"
        }
        return status == 0 ? "ssh exited" : "ssh exited with status \(status)"
    }
}
