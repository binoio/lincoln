//
//  NetworkMonitor.swift
//  Lincoln
//
//  Reports meaningful network path changes (interface set / gateway
//  changes) so connected tunnels can restart instead of waiting for
//  ServerAlive to time out.
//

import Foundation
import Network

@MainActor
final class NetworkMonitor {
    var onPathChanged: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.binoio.Lincoln.network")
    private var lastSignature: String?
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = NetworkMonitor.signature(for: path)
            Task { @MainActor in
                self?.handle(signature: signature, satisfied: path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        monitor.cancel()
        isStarted = false
    }

    private func handle(signature: String, satisfied: Bool) {
        defer { lastSignature = signature }
        guard let previous = lastSignature, previous != signature else { return }
        guard satisfied else { return }
        LogStore.log(level: .info, category: "Network", message: "Network path changed", details: signature)
        onPathChanged?()
    }

    nonisolated static func signature(for path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.sorted().joined(separator: ",")
        return "\(path.status) [\(interfaces)] expensive=\(path.isExpensive)"
    }
}
