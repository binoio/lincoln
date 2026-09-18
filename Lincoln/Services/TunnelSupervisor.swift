//
//  TunnelSupervisor.swift
//  Lincoln
//
//  Runs one tunnel: launches its ControlMaster in Terminal.app, watches the
//  control socket, and drives the LincolnCore state machine.
//

import Foundation
import Combine
import LincolnCore

@MainActor
final class TunnelSupervisor: ObservableObject, Identifiable {
    nonisolated let id: UUID

    @Published var tunnel: Tunnel
    @Published private(set) var state: TunnelState = .idle
    @Published private(set) var controlPath: ResolvedControlPath?
    @Published private(set) var lastCommandLine: String = ""
    @Published private(set) var lastScriptURL: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var lastChecked: Date?

    var onStateChange: ((TunnelSupervisor) -> Void)?

    /// Give up on a launch when no socket appears within this long (Duo
    /// pushes expire well before).
    var connectTimeout: TimeInterval = 180

    private var machine: TunnelStateMachine
    private let launcher: TerminalLaunching
    private let headless: HeadlessMasterLaunching?
    private let socket: ControlSocketChecking
    private let environment: SSHEnvironmentProviding
    private let notifier: Notifying?
    /// Consulted at each launch; false forces the Terminal flow.
    var connectSilentlyFirst: () -> Bool = { true }
    /// How the last launch was performed, for the status view.
    @Published private(set) var lastLaunchMode: LaunchMode?

    enum LaunchMode: Equatable {
        case silent
        case terminal(reason: String)

        var description: String {
            switch self {
            case .silent: return "silently (keys only)"
            case .terminal(let reason): return "in Terminal.app — \(reason)"
            }
        }
    }
    private let stateDirectory: URL
    private let fileManager: FileManager
    private var isPolling = false
    private var launchGeneration = 0

    init(
        tunnel: Tunnel,
        launcher: TerminalLaunching,
        headless: HeadlessMasterLaunching? = nil,
        socket: ControlSocketChecking,
        environment: SSHEnvironmentProviding,
        notifier: Notifying? = nil,
        stateDirectory: URL = TunnelStore.defaultDirectory().appendingPathComponent("state", isDirectory: true),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.id = tunnel.id
        self.tunnel = tunnel
        self.launcher = launcher
        self.headless = headless
        self.socket = socket
        self.environment = environment
        self.notifier = notifier
        self.stateDirectory = stateDirectory
        self.fileManager = fileManager
        self.machine = TunnelStateMachine(now: now)
    }

    var statusFileURL: URL {
        stateDirectory.appendingPathComponent("\(id.uuidString).status")
    }

    // MARK: - Intents

    func start() {
        guard tunnel.isValid else {
            let reason = tunnel.validationErrors.joined(separator: " ")
            lastError = reason
            LogStore.log(level: .error, category: "Tunnel", message: "\(tunnel.displayName): invalid configuration", details: reason)
            return
        }
        lastError = nil
        handle(.start)
    }

    func stop() {
        handle(.stop)
    }

    /// Lincoln launched and this tunnel was up when it last quit.
    func markExpectedUp() {
        handle(.restoreExpectedUp)
    }

    /// Runs `ssh -O check` (and, while connecting, reads the launch status
    /// file) and feeds the result to the state machine.
    func poll() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        guard let resolved = await resolvedControlPath() else { return }

        if case .connecting(let since) = state {
            if let status = readLaunchStatus() {
                removeLaunchStatus()
                handle(.launchExited(status: status))
                if case .failed = state { return }
            }
            if Date().timeIntervalSince(since) > connectTimeout {
                handle(.connectTimedOut)
                return
            }
        }

        let status = await socket.check(tunnel, controlPath: resolved.path)
        lastChecked = Date()
        handle(status.isRunning ? .masterRunning(pid: status.pid) : .masterMissing)
    }

    /// Command line for an interactive session that reuses the master.
    func sessionCommandLine() -> String? {
        guard let path = controlPath?.path else { return nil }
        return SSHCommandBuilder.commandLine(
            executable: environment.builderEnvironment.sshExecutable,
            arguments: SSHCommandBuilder.sessionArguments(for: tunnel, controlPath: path)
        )
    }

    /// Opens a Terminal window with an interactive session on the tunnel's
    /// host, sharing the master so no second Duo prompt is needed.
    func openSession() {
        guard let command = sessionCommandLine() else { return }
        let script = "#!/bin/zsh\n# Generated by Lincoln: interactive session sharing the \(tunnel.displayName) control master.\nexec \(command)\n"
        do {
            try launcher.launch(script: script, name: "\(tunnel.displayName)-session")
        } catch {
            LogStore.log(level: .error, category: "Terminal", message: "\(tunnel.displayName): could not open session", details: error.localizedDescription)
        }
    }

    // MARK: - State machine plumbing

    private func handle(_ event: TunnelEvent) {
        let previous = state
        let (next, effects) = machine.transition(state, on: event)
        state = next
        if previous != next {
            LogStore.log(level: TunnelSupervisor.logLevel(for: next), category: "Tunnel", message: "\(tunnel.displayName): \(previous.label) → \(next.label)")
            switch next {
            case .failed(let reason), .dropped(let reason): lastError = reason
            case .connected: lastError = nil
            default: break
            }
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
        case .launch:
            launchGeneration += 1
            let generation = launchGeneration
            Task { @MainActor in
                await launch(generation: generation)
            }
        case .sendExit:
            Task { @MainActor in
                await sendExit()
            }
        case .notifyConnected:
            notifier?.clear(identifier: "dropped-\(id.uuidString)")
            notifier?.clear(identifier: "failed-\(id.uuidString)")
        case .notifyDropped(let reason):
            notifier?.post(identifier: "dropped-\(id.uuidString)", title: "\(tunnel.displayName) dropped", body: "\(reason). Connect again from Lincoln when you are ready.")
        case .notifyFailed(let reason):
            notifier?.post(identifier: "failed-\(id.uuidString)", title: "\(tunnel.displayName) did not connect", body: reason)
        case .log(let message):
            LogStore.log(level: .info, category: "Tunnel", message: "\(tunnel.displayName): \(message)")
        }
    }

    private func launch(generation: Int) async {
        guard let resolved = await resolvedControlPath(refresh: true) else {
            handle(.launchFailed(reason: "Could not resolve ssh configuration for \(tunnel.trimmedHost) (see Diagnostic Logs)"))
            return
        }
        guard generation == launchGeneration, state.isConnecting else { return }
        do {
            try environment.prepareControlPathDirectory(resolved.path)
        } catch {
            handle(.launchFailed(reason: error.localizedDescription))
            return
        }
        let configured = resolved.destination.configuredForwards
        if !configured.isEmpty {
            LogStore.log(level: .info, category: "SSH", message: "\(tunnel.displayName): ssh config already forwards \(configured.map(\.summary).joined(separator: ", ")); those stay active and are not added twice")
        }
        if !resolved.isFromConfig {
            LogStore.log(level: .warning, category: "SSH", message: "\(tunnel.displayName): ssh config has no ControlPath for this host; using \(resolved.path). Terminal sessions will not share it unless they pass the same ControlPath.")
        }

        var terminalReason = "silent connections are off in Settings"
        if connectSilentlyFirst(), let headless = headless {
            let builderEnvironment = environment.builderEnvironment
            let arguments = SSHCommandBuilder.headlessMasterArguments(for: tunnel, controlPath: resolved.path, configuredForwards: configured, environment: builderEnvironment)
            lastCommandLine = SSHCommandBuilder.commandLine(executable: builderEnvironment.sshExecutable, arguments: arguments)
            lastLaunchMode = .silent
            LogStore.log(level: .info, category: "SSH", message: "\(tunnel.displayName): starting control master silently", details: lastCommandLine)
            let result = await headless.launchMaster(arguments: arguments, timeout: connectTimeout)
            guard generation == launchGeneration, state.isConnecting else { return }
            if result.exitCode == 0 {
                handle(.launchExited(status: 0))
                return
            }
            if result.timedOut {
                handle(.launchFailed(reason: "ssh did not finish within \(Int(connectTimeout))s"))
                return
            }
            guard SSHCommandBuilder.requiresInteraction(stderr: result.standardError) else {
                let reason = SSHCommandBuilder.failureReason(stderr: result.standardError, status: result.exitCode)
                LogStore.log(level: .error, category: "SSH", message: "\(tunnel.displayName): silent connection failed", details: result.standardError)
                handle(.launchFailed(reason: reason))
                return
            }
            terminalReason = SSHCommandBuilder.failureReason(stderr: result.standardError, status: result.exitCode)
            LogStore.log(level: .info, category: "SSH", message: "\(tunnel.displayName): ssh needs a prompt (\(terminalReason)); continuing in Terminal.app")
        }
        launchInTerminal(resolved: resolved, configured: configured, reason: terminalReason)
    }

    private func launchInTerminal(resolved: ResolvedControlPath, configured: [Forward], reason: String) {
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            removeLaunchStatus()
            let builderEnvironment = environment.builderEnvironment
            lastCommandLine = SSHCommandBuilder.commandLine(
                executable: builderEnvironment.sshExecutable,
                arguments: SSHCommandBuilder.masterArguments(for: tunnel, controlPath: resolved.path, configuredForwards: configured, environment: builderEnvironment)
            )
            lastLaunchMode = .terminal(reason: reason)
            let script = SSHCommandBuilder.terminalScript(for: tunnel, controlPath: resolved.path, statusFile: statusFileURL.path, configuredForwards: configured, environment: builderEnvironment)
            lastScriptURL = try launcher.launch(script: script, name: tunnel.displayName)
            LogStore.log(level: .info, category: "SSH", message: "\(tunnel.displayName): launched control master in Terminal", details: lastCommandLine)
        } catch {
            LogStore.log(level: .error, category: "Terminal", message: "\(tunnel.displayName): could not launch Terminal", details: error.localizedDescription)
            handle(.launchFailed(reason: error.localizedDescription))
        }
    }

    private func sendExit() async {
        guard let resolved = await resolvedControlPath() else {
            handle(.masterMissing)
            return
        }
        let accepted = await socket.requestExit(tunnel, controlPath: resolved.path)
        if !accepted {
            // Nothing was listening: treat as already gone.
            handle(.masterMissing)
        }
    }

    private func resolvedControlPath(refresh: Bool = false) async -> ResolvedControlPath? {
        if !refresh, let cached = controlPath { return cached }
        let resolved = await environment.resolveControlPath(for: tunnel)
        if let resolved = resolved {
            controlPath = resolved
        }
        return resolved
    }

    /// Tunnel edits invalidate the resolved path (host/user/port may differ).
    func invalidateControlPath() {
        controlPath = nil
    }

    private func readLaunchStatus() -> Int32? {
        guard let text = try? String(contentsOf: statusFileURL, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func removeLaunchStatus() {
        try? fileManager.removeItem(at: statusFileURL)
    }

    private static func logLevel(for state: TunnelState) -> LogLevel {
        switch state {
        case .connected: return .success
        case .failed, .dropped: return .error
        default: return .info
        }
    }
}
