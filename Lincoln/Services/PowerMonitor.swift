//
//  PowerMonitor.swift
//  Lincoln
//

import Foundation
import AppKit

@MainActor
final class PowerMonitor {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                LogStore.log(level: .info, category: "Power", message: "System will sleep")
                self?.onWillSleep?()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                LogStore.log(level: .info, category: "Power", message: "System did wake")
                self?.onDidWake?()
            }
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }
}
