//
//  TunnelManager.swift
//  Lincoln
//
//  Owns the tunnel list and one supervisor per tunnel, persists every change
//  through TunnelStore, polls the control sockets, and at launch adopts
//  masters that are already running (started by Lincoln or by hand).
//

import Foundation
import Combine
import LincolnCore

@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var supervisors: [TunnelSupervisor] = []
    @Published private(set) var document = TunnelDocument.empty
    @Published var selectedTunnelID: UUID?
    @Published private(set) var loadWarning: String?
    /// Bumped whenever any supervisor changes state so list rows refresh.
    @Published private(set) var stateVersion = 0

    let store: TunnelStore
    let settings: SettingsManager
    let environment: SSHEnvironmentProviding
    private let launcher: TerminalLaunching
    private let headless: HeadlessMasterLaunching?
    private let socket: ControlSocketChecking
    private let notifier: Notifying?
    private let configParser: SSHConfigParser
    private let stateDirectory: URL
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?

    /// Seconds between `ssh -O check` rounds; faster while something connects.
    var idlePollInterval: TimeInterval = 5
    var connectingPollInterval: TimeInterval = 1

    init(
        store: TunnelStore,
        settings: SettingsManager,
        environment: SSHEnvironmentProviding,
        launcher: TerminalLaunching,
        headless: HeadlessMasterLaunching? = nil,
        socket: ControlSocketChecking,
        notifier: Notifying? = nil,
        configParser: SSHConfigParser = SSHConfigParser(),
        stateDirectory: URL? = nil
    ) {
        self.store = store
        self.settings = settings
        self.environment = environment
        self.launcher = launcher
        self.headless = headless
        self.socket = socket
        self.notifier = notifier
        self.configParser = configParser
        self.stateDirectory = stateDirectory ?? store.directoryURL.appendingPathComponent("state", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Loads the store and builds supervisors. Call `startPolling()` (or
    /// `pollAll()`) afterwards to learn which masters are already running.
    func load() {
        do {
            let result = try store.load()
            document = result.document
            if let quarantine = result.quarantinedFileURL {
                loadWarning = "tunnels.json could not be read and was moved to \(quarantine.lastPathComponent)."
                LogStore.log(level: .error, category: "Store", message: "Corrupt tunnels.json quarantined", details: quarantine.path)
            }
            if let migrated = result.migratedFromSchemaVersion {
                LogStore.log(level: .info, category: "Store", message: "Migrated tunnels.json from schema \(migrated)")
                try? store.save(document)
            }
            LogStore.log(level: .info, category: "Store", message: "Loaded \(document.tunnels.count) tunnel(s) from \(store.fileURL.path)")
        } catch {
            loadWarning = error.localizedDescription
            LogStore.log(level: .error, category: "Store", message: "Failed to load tunnels.json", details: error.localizedDescription)
        }

        supervisors = document.tunnels.map(makeSupervisor)
        if selectedTunnelID == nil {
            selectedTunnelID = supervisors.first?.id
        }
    }

    /// First poll after launch: adopt running masters, mark the ones that
    /// were up last time but are gone, and auto-connect where asked.
    func restore() async {
        await pollAll()
        for supervisor in supervisors {
            if document.desiredUp.contains(supervisor.id), !supervisor.state.isConnected {
                supervisor.markExpectedUp()
            }
            if supervisor.tunnel.autoConnect, !supervisor.state.isActive {
                LogStore.log(level: .info, category: "Launch", message: "Auto-connecting \(supervisor.tunnel.displayName)")
                connect(id: supervisor.id)
            }
        }
        let dropped = supervisors.filter { if case .dropped = $0.state { return true } else { return false } }
        if !dropped.isEmpty {
            let names = dropped.map { $0.tunnel.displayName }.joined(separator: ", ")
            notifier?.post(identifier: "restore", title: "Tunnels need reconnecting", body: names)
        }
    }

    func startPolling() {
        guard pollTimer == nil else { return }
        scheduleNextPoll(after: 0)
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func scheduleNextPoll(after delay: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                await self.pollAll()
                let interval = self.supervisors.contains { $0.state.isConnecting || $0.state == .disconnecting } ? self.connectingPollInterval : self.idlePollInterval
                self.scheduleNextPoll(after: interval)
            }
        }
    }

    /// Checks every tunnel's control socket concurrently.
    func pollAll() async {
        await withTaskGroup(of: Void.self) { group in
            for supervisor in supervisors {
                group.addTask { @MainActor in
                    await supervisor.poll()
                }
            }
        }
    }

    private func makeSupervisor(for tunnel: Tunnel) -> TunnelSupervisor {
        let supervisor = TunnelSupervisor(
            tunnel: tunnel,
            launcher: launcher,
            headless: headless,
            socket: socket,
            environment: environment,
            notifier: notifier,
            stateDirectory: stateDirectory
        )
        supervisor.connectSilentlyFirst = { [weak self] in self?.settings.connectSilentlyFirst ?? true }
        supervisor.onStateChange = { [weak self] _ in
            self?.stateVersion += 1
        }
        supervisor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        return supervisor
    }

    // MARK: - Queries

    func supervisor(for id: UUID?) -> TunnelSupervisor? {
        guard let id = id else { return nil }
        return supervisors.first { $0.id == id }
    }

    var selectedSupervisor: TunnelSupervisor? { supervisor(for: selectedTunnelID) }

    var connectedCount: Int { supervisors.filter { $0.state.isConnected }.count }
    var activeCount: Int { supervisors.filter { $0.state.isActive }.count }
    var anyConnected: Bool { connectedCount > 0 }
    var anyNeedsAttention: Bool { supervisors.contains { $0.state.needsAttention } }

    // MARK: - Mutations

    @discardableResult
    func add(_ tunnel: Tunnel) -> TunnelSupervisor {
        document.upsert(tunnel)
        let supervisor = makeSupervisor(for: tunnel)
        supervisors.append(supervisor)
        selectedTunnelID = tunnel.id
        persist()
        LogStore.log(level: .info, category: "Tunnels", message: "Added \(tunnel.displayName)")
        return supervisor
    }

    /// A blank tunnel the editor fills in.
    @discardableResult
    func addNewTunnel() -> TunnelSupervisor {
        var name = "New Tunnel"
        var counter = 2
        while document.tunnels.contains(where: { $0.name == name }) {
            name = "New Tunnel \(counter)"
            counter += 1
        }
        return add(Tunnel(name: name, host: "", forwards: [Forward.dynamic(port: nextFreeSOCKSPort())]))
    }

    private func nextFreeSOCKSPort() -> Int {
        let used = Set(document.tunnels.flatMap { $0.forwards.map(\.listenPort) })
        var port = 1080
        while used.contains(port) { port += 1 }
        return port
    }

    func update(_ tunnel: Tunnel) {
        document.upsert(tunnel)
        if let supervisor = supervisor(for: tunnel.id) {
            supervisor.tunnel = tunnel
            supervisor.invalidateControlPath()
        }
        persist()
        LogStore.log(level: .info, category: "Tunnels", message: "Updated \(tunnel.displayName)")
    }

    /// Removes the tunnel from Lincoln. A running master is left alone: it
    /// belongs to the user's ssh session, not to the app.
    func remove(id: UUID) {
        guard let supervisor = supervisor(for: id) else { return }
        let name = supervisor.tunnel.displayName
        supervisors.removeAll { $0.id == id }
        document.remove(id: id)
        if selectedTunnelID == id {
            selectedTunnelID = supervisors.first?.id
        }
        persist()
        LogStore.log(level: .info, category: "Tunnels", message: "Removed \(name)")
    }

    @discardableResult
    func duplicate(id: UUID) -> TunnelSupervisor? {
        guard let source = supervisor(for: id)?.tunnel else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = "\(source.displayName) copy"
        copy.forwards = source.forwards.map { forward in
            var f = forward
            f.id = UUID()
            return f
        }
        copy.autoConnect = false
        return add(copy)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        supervisors.move(fromOffsets: source, toOffset: destination)
        document.tunnels = supervisors.map(\.tunnel)
        persist()
    }

    // MARK: - Connections

    func connect(id: UUID) {
        guard let supervisor = supervisor(for: id) else { return }
        document.setDesiredUp(true, id: id)
        persist()
        supervisor.start()
        scheduleNextPoll(after: connectingPollInterval)
    }

    func disconnect(id: UUID) {
        guard let supervisor = supervisor(for: id) else { return }
        document.setDesiredUp(false, id: id)
        persist()
        supervisor.stop()
        scheduleNextPoll(after: connectingPollInterval)
    }

    func toggle(id: UUID) {
        guard let supervisor = supervisor(for: id) else { return }
        if supervisor.state.isActive {
            disconnect(id: id)
        } else {
            connect(id: id)
        }
    }

    func connectAll() {
        for supervisor in supervisors where !supervisor.state.isActive {
            connect(id: supervisor.id)
        }
    }

    func disconnectAll() {
        for supervisor in supervisors where supervisor.state.isActive {
            disconnect(id: supervisor.id)
        }
    }

    /// Quitting Lincoln leaves the masters running (they are the user's ssh
    /// sessions); `desiredUp` is kept so the next launch knows what to expect.
    func prepareForQuit() {
        stopPolling()
    }

    /// Network change or wake: check right away instead of waiting for the timer.
    func pollSoon() {
        scheduleNextPoll(after: 0.5)
    }

    // MARK: - Import

    func importableHosts() -> [SSHConfigHost] {
        do {
            return try configParser.parse().filter { $0.isConcrete }
        } catch {
            LogStore.log(level: .error, category: "Import", message: "Could not read ~/.ssh/config", details: error.localizedDescription)
            return []
        }
    }

    var sshConfigPath: String { configParser.defaultConfigURL.path }

    /// Creates tunnels from ssh_config hosts. Hosts without forwards get a
    /// SOCKS forward on the next free port so the result is immediately usable.
    @discardableResult
    func importHosts(_ hosts: [SSHConfigHost]) -> [Tunnel] {
        var created: [Tunnel] = []
        for host in hosts {
            guard let alias = host.alias else { continue }
            let forwards = host.forwards.isEmpty ? [Forward.dynamic(port: nextFreeSOCKSPort() + created.count)] : host.forwards
            let tunnel = Tunnel(
                name: alias,
                host: alias,
                forwards: forwards,
                notes: host.hostName.map { "Imported from \(host.sourcePath) (HostName \($0))" } ?? "Imported from \(host.sourcePath)"
            )
            document.upsert(tunnel)
            supervisors.append(makeSupervisor(for: tunnel))
            created.append(tunnel)
        }
        if let last = created.last {
            selectedTunnelID = last.id
        }
        persist()
        LogStore.log(level: .success, category: "Import", message: "Imported \(created.count) tunnel(s) from ssh config")
        return created
    }

    // MARK: - Persistence

    private func persist() {
        do {
            try store.save(document)
        } catch {
            LogStore.log(level: .error, category: "Store", message: "Failed to save tunnels.json", details: error.localizedDescription)
        }
    }
}
