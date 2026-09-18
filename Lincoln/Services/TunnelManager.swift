//
//  TunnelManager.swift
//  Lincoln
//
//  Owns the tunnel list and one supervisor per tunnel, persists every change
//  through TunnelStore, restores the desired state at launch and fans out
//  network/power events.
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
    private let processFactory: TunnelProcessFactory
    private let notifier: Notifying?
    private let reconciler: StaleProcessReconciler
    private let policy: ReconnectPolicy
    private let scheduler: BackoffScheduler
    private let configParser: SSHConfigParser
    private var cancellables = Set<AnyCancellable>()

    init(
        store: TunnelStore,
        settings: SettingsManager,
        environment: SSHEnvironmentProviding,
        processFactory: TunnelProcessFactory,
        notifier: Notifying? = nil,
        reconciler: StaleProcessReconciler = StaleProcessReconciler(),
        policy: ReconnectPolicy = .default,
        scheduler: BackoffScheduler? = nil,
        configParser: SSHConfigParser = SSHConfigParser()
    ) {
        self.store = store
        self.settings = settings
        self.environment = environment
        self.processFactory = processFactory
        self.notifier = notifier
        self.reconciler = reconciler
        self.policy = policy
        self.scheduler = scheduler ?? TunnelSupervisor.dispatchScheduler
        self.configParser = configParser
    }

    // MARK: - Lifecycle

    /// Loads the store, stops orphaned ssh processes from an earlier Lincoln,
    /// and re-establishes tunnels that were up last time.
    func load(restoreConnections: Bool? = nil) {
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

        let stale = reconciler.reconcile()
        for process in stale {
            LogStore.log(level: .warning, category: "Reconcile", message: "Stopped orphaned ssh (pid \(process.pid)) from a previous Lincoln", details: process.command)
        }

        supervisors = document.tunnels.map(makeSupervisor)
        if selectedTunnelID == nil {
            selectedTunnelID = supervisors.first?.id
        }

        let restore = restoreConnections ?? settings.restoreConnectionsOnLaunch
        for supervisor in supervisors {
            let wasUp = document.desiredUp.contains(supervisor.id)
            if supervisor.tunnel.autoConnect || (restore && wasUp) {
                LogStore.log(level: .info, category: "Launch", message: "Restoring \(supervisor.tunnel.displayName) (\(supervisor.tunnel.autoConnect ? "auto-connect" : "was connected"))")
                supervisor.start()
            }
        }
    }

    private func makeSupervisor(for tunnel: Tunnel) -> TunnelSupervisor {
        let supervisor = TunnelSupervisor(
            tunnel: tunnel,
            processFactory: processFactory,
            environment: environment,
            notifier: notifier,
            policy: policy,
            scheduler: scheduler
        )
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
    var anyNeedsAttention: Bool { supervisors.contains { $0.needsAttention } }

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
        supervisor(for: tunnel.id)?.tunnel = tunnel
        persist()
        LogStore.log(level: .info, category: "Tunnels", message: "Updated \(tunnel.displayName)")
    }

    func remove(id: UUID) {
        guard let supervisor = supervisor(for: id) else { return }
        let name = supervisor.tunnel.displayName
        supervisor.stop()
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
    }

    func disconnect(id: UUID) {
        guard let supervisor = supervisor(for: id) else { return }
        document.setDesiredUp(false, id: id)
        persist()
        supervisor.stop()
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

    /// Quit path: stop every process but keep `desiredUp` so the next launch
    /// restores the same tunnels.
    func stopAllForQuit() {
        for supervisor in supervisors where supervisor.state.isRunningProcess || supervisor.state.isActive {
            supervisor.stop()
        }
    }

    func handleNetworkChange() {
        for supervisor in supervisors where supervisor.state.isActive {
            supervisor.linkLost()
        }
    }

    func handleWake() {
        for supervisor in supervisors where supervisor.state.isActive && supervisor.tunnel.reconnectOnWake {
            supervisor.linkLost()
        }
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
