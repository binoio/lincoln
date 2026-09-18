//
//  TunnelSupervisor.swift
//  Lincoln
//
//  Runs one tunnel: drives the LincolnCore state machine, owns the ssh
//  process, feeds the console, detects prompts and the ready sentinel, and
//  schedules reconnect backoff.
//

import Foundation
import Combine
import LincolnCore

/// Schedules a callback after a delay and returns a cancel closure.
/// Injected so tests can fire backoff timers deterministically.
typealias BackoffScheduler = (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> (() -> Void)

@MainActor
final class TunnelSupervisor: ObservableObject, Identifiable {
    nonisolated let id: UUID

    @Published var tunnel: Tunnel {
        didSet { machine.autoReconnect = tunnel.autoReconnect }
    }
    @Published private(set) var state: TunnelState = .idle
    @Published private(set) var console = ConsoleBuffer()
    @Published private(set) var currentPrompt: DetectedPrompt?
    @Published private(set) var needsAttention = false
    @Published private(set) var lastCommandLine: String = ""
    @Published private(set) var lastError: String?

    var onStateChange: ((TunnelSupervisor) -> Void)?

    private var machine: TunnelStateMachine
    private var process: TunnelProcess?
    private var cancelBackoff: (() -> Void)?
    private var promptCheck: (() -> Void)?
    private var spawnGeneration = 0
    /// Output since the current ssh started; the sentinel is searched here so
    /// a previous run's sentinel can never mark a new run as connected.
    private var runOutput = ""
    private var sentinelSeenThisRun = false

    private let processFactory: TunnelProcessFactory
    private let environment: SSHEnvironmentProviding
    private let notifier: Notifying?
    private let scheduler: BackoffScheduler
    /// How long the output must stay quiet before a trailing ":"/"?" counts as a prompt.
    var promptQuietInterval: TimeInterval = 0.3

    init(
        tunnel: Tunnel,
        processFactory: TunnelProcessFactory,
        environment: SSHEnvironmentProviding,
        notifier: Notifying? = nil,
        policy: ReconnectPolicy = .default,
        scheduler: BackoffScheduler? = nil
    ) {
        self.id = tunnel.id
        self.tunnel = tunnel
        self.processFactory = processFactory
        self.environment = environment
        self.notifier = notifier
        self.scheduler = scheduler ?? TunnelSupervisor.dispatchScheduler
        self.machine = TunnelStateMachine(policy: policy, autoReconnect: tunnel.autoReconnect)
    }

    nonisolated static let dispatchScheduler: BackoffScheduler = { delay, action in
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    // MARK: - Intents

    func start() {
        guard tunnel.isValid else {
            let reason = tunnel.validationErrors.joined(separator: " ")
            lastError = reason
            console.appendSystemLine("— cannot connect: \(reason)")
            LogStore.log(level: .error, category: "Tunnel", message: "\(tunnel.displayName): invalid configuration", details: reason)
            return
        }
        lastError = nil
        handle(.start)
    }

    func stop() {
        handle(.stop)
    }

    func restart() {
        handle(.linkLost)
    }

    /// Sends a line to ssh (the user's answer to a prompt).
    func submitInput(_ text: String) {
        guard let process = process, process.isRunning else { return }
        process.write(text + "\n")
        promptCheck?()
        promptCheck = nil
        // The pty echoes non-secret answers back, completing the prompt line.
        currentPrompt = nil
        handle(.inputSubmitted)
    }

    func sendInterrupt() {
        process?.write("\u{03}")
    }

    func clearConsole() {
        console.clear()
    }

    /// Fold external link events (network change, wake) in.
    func linkLost() {
        guard state.isConnected || (state.isActive && !state.isRunningProcess) else { return }
        handle(.linkLost)
    }

    // MARK: - State machine plumbing

    private func handle(_ event: TunnelEvent) {
        let previous = state
        let (next, effects) = machine.transition(state, on: event)
        state = next
        if previous != next {
            LogStore.log(level: TunnelSupervisor.logLevel(for: next), category: "Tunnel", message: "\(tunnel.displayName): \(previous.label) → \(next.label)")
            if case .failed(let reason) = next { lastError = reason }
            if case .connected = next { lastError = nil }
        }
        for effect in effects {
            perform(effect)
        }
        if previous != next {
            onStateChange?(self)
        }
    }

    private func perform(_ effect: TunnelEffect) {
        switch effect {
        case .spawn:
            spawn()
        case .kill:
            if let process = process, process.isRunning {
                process.terminate()
            } else {
                // Nothing to kill (stop arrived while ssh -G was still
                // resolving, or the launch failed): complete the transition now.
                process = nil
                handle(.processExited(status: 0, output: ""))
            }
        case .scheduleBackoff(let delay):
            cancelBackoff?()
            let generation = spawnGeneration
            cancelBackoff = scheduler(delay) { [weak self] in
                guard let self = self, self.spawnGeneration == generation else { return }
                self.cancelBackoff = nil
                self.handle(.backoffElapsed)
            }
        case .cancelBackoff:
            cancelBackoff?()
            cancelBackoff = nil
        case .notifyAttention(let prompt):
            needsAttention = true
            notifier?.post(identifier: "attention-\(id.uuidString)", title: "\(tunnel.displayName) needs your input", body: prompt)
        case .clearAttention:
            needsAttention = false
            currentPrompt = nil
            notifier?.clear(identifier: "attention-\(id.uuidString)")
        case .notifyConnected:
            console.appendSystemLine("— connected \(TunnelSupervisor.timestamp())")
            notifier?.clear(identifier: "dropped-\(id.uuidString)")
        case .notifyDisconnected(let reason):
            console.appendSystemLine("— disconnected: \(reason)")
            notifier?.post(identifier: "dropped-\(id.uuidString)", title: "\(tunnel.displayName) disconnected", body: reason)
        case .log(let message):
            console.appendSystemLine("— \(message)")
            LogStore.log(level: .info, category: "Tunnel", message: "\(tunnel.displayName): \(message)")
        }
    }

    private func spawn() {
        spawnGeneration += 1
        let generation = spawnGeneration
        let snapshot = tunnel
        Task { @MainActor in
            var controlPath: String?
            if snapshot.shareControlMaster {
                controlPath = await environment.resolveControlPath(for: snapshot)
                if let path = controlPath {
                    do {
                        try environment.prepareControlPathDirectory(path)
                    } catch {
                        LogStore.log(level: .warning, category: "Tunnel", message: "\(snapshot.displayName): could not prepare ControlPath directory", details: error.localizedDescription)
                        controlPath = nil
                    }
                } else {
                    console.appendSystemLine("— ControlPath is 'none' for \(snapshot.trimmedHost); connection will not be shared")
                }
            }
            // The user may have stopped us while ssh -G ran.
            guard generation == spawnGeneration, case .connecting = state, process == nil || process?.isRunning == false else { return }
            launchProcess(for: snapshot, controlPath: controlPath, generation: generation)
        }
    }

    private func launchProcess(for snapshot: Tunnel, controlPath: String?, generation: Int) {
        let builderEnvironment = environment.builderEnvironment
        let arguments = SSHCommandBuilder.arguments(for: snapshot, controlPath: controlPath, environment: builderEnvironment)
        lastCommandLine = SSHCommandBuilder.commandLine(for: snapshot, controlPath: controlPath, environment: builderEnvironment)
        runOutput = ""
        sentinelSeenThisRun = false
        currentPrompt = nil
        console.appendSystemLine("— \(TunnelSupervisor.timestamp()) \(lastCommandLine)")
        LogStore.log(level: .info, category: "SSH", message: "\(snapshot.displayName): launching ssh", details: lastCommandLine)

        let process = processFactory.makeProcess(
            executable: builderEnvironment.sshExecutable,
            arguments: arguments,
            environment: environment.processEnvironment()
        )
        process.onOutput = { [weak self] data in
            guard let self = self, self.spawnGeneration == generation else { return }
            self.handleOutput(data)
        }
        process.onExit = { [weak self] status in
            guard let self = self, self.spawnGeneration == generation else { return }
            self.handleExit(status: status)
        }
        self.process = process
        do {
            try process.start()
        } catch {
            let message = error.localizedDescription
            console.appendSystemLine("— failed to launch ssh: \(message)")
            LogStore.log(level: .error, category: "SSH", message: "\(snapshot.displayName): failed to launch ssh", details: message)
            self.process = nil
            handle(.processExited(status: -1, output: message))
        }
    }

    private func handleOutput(_ data: Data) {
        let text = ANSIStripper.strip(String(decoding: data, as: UTF8.self))
        guard !text.isEmpty else { return }
        console.append(text)
        runOutput.append(text)
        if runOutput.count > 20_000 {
            runOutput = String(runOutput.suffix(10_000))
        }

        if !sentinelSeenThisRun, PromptDetector.containsReadySentinel(runOutput, tunnelID: id) {
            sentinelSeenThisRun = true
            promptCheck?()
            promptCheck = nil
            handle(.readySeen)
            return
        }

        // Prompts end without a newline; wait for the output to go quiet
        // before deciding the tail is a question rather than a partial line.
        promptCheck?()
        promptCheck = nil
        guard !state.isConnected, !console.tail.isEmpty else { return }
        promptCheck = scheduler(promptQuietInterval) { [weak self] in
            guard let self = self else { return }
            self.promptCheck = nil
            self.evaluatePrompt()
        }
    }

    private func evaluatePrompt() {
        guard state.isRunningProcess, !state.isConnected else { return }
        guard let prompt = PromptDetector.detect(lineTail: console.tail) else { return }
        if currentPrompt == prompt { return }
        currentPrompt = prompt
        handle(.promptDetected(prompt.text))
    }

    private func handleExit(status: Int32) {
        promptCheck?()
        promptCheck = nil
        process = nil
        let recent = console.recentText(lineCount: 20)
        console.appendSystemLine("— ssh exited (\(status)) \(TunnelSupervisor.timestamp())")
        if PromptDetector.containsAuthenticationFailure(runOutput) {
            LogStore.log(level: .error, category: "SSH", message: "\(tunnel.displayName): authentication failed", details: recent)
        }
        handle(.processExited(status: status, output: runOutput.isEmpty ? recent : runOutput))
    }

    private static func logLevel(for state: TunnelState) -> LogLevel {
        switch state {
        case .connected: return .success
        case .failed: return .error
        case .waitingForInput, .reconnecting, .restarting: return .warning
        default: return .info
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
