//
//  SettingsManager.swift
//  Lincoln
//
//  App preferences in UserDefaults (io.binoio.Lincoln domain), which survive
//  deleting and reinstalling the app. Dock/menu bar policy follows Kona:
//  hiding the Dock icon forces the menu bar item on so the app stays reachable.
//

import Foundation
import AppKit
import ServiceManagement

protocol LoginItemControlling {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

struct SMAppServiceLoginItem: LoginItemControlling {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class SettingsManager: ObservableObject {
    enum Key {
        static let showMenuBarItem = "lincoln.showMenuBarItem"
        static let hideDockIcon = "lincoln.hideDockIcon"
        static let notificationsEnabled = "lincoln.notificationsEnabled"
        static let connectSilentlyFirst = "lincoln.connectSilentlyFirst"
        static let sshExecutable = "lincoln.sshExecutable"
        static let extraPath = "lincoln.extraPath"
        static let serverAliveInterval = "lincoln.serverAliveInterval"
        static let serverAliveCountMax = "lincoln.serverAliveCountMax"
        static let hasCompletedFirstRun = "lincoln.hasCompletedFirstRun"

        static var all: [String] {
            [showMenuBarItem, hideDockIcon, notificationsEnabled, connectSilentlyFirst, sshExecutable,
             extraPath, serverAliveInterval, serverAliveCountMax, hasCompletedFirstRun]
        }
    }

    static let defaultSSHExecutable = "/usr/bin/ssh"
    static let defaultExtraPath = "~/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin"

    private let defaults: UserDefaults
    private let loginItem: LoginItemControlling
    /// Set to false in tests so no NSApp activation policy changes happen.
    var appliesActivationPolicy = true

    @Published var showMenuBarItem: Bool {
        didSet {
            if !showMenuBarItem && hideDockIcon {
                // Never let the app become unreachable.
                hideDockIcon = false
            }
            defaults.set(showMenuBarItem, forKey: Key.showMenuBarItem)
        }
    }

    @Published var hideDockIcon: Bool {
        didSet {
            if hideDockIcon && !showMenuBarItem {
                showMenuBarItem = true
            }
            defaults.set(hideDockIcon, forKey: Key.hideDockIcon)
            LogStore.log(level: .info, category: "Settings", message: "Hide Dock icon changed to \(hideDockIcon)")
            applyDockIconVisibility()
        }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// Try the master with keys only and no window; open Terminal.app only
    /// when ssh needs a person (Duo, passphrase, host key).
    @Published var connectSilentlyFirst: Bool {
        didSet { defaults.set(connectSilentlyFirst, forKey: Key.connectSilentlyFirst) }
    }

    @Published var sshExecutable: String {
        didSet { defaults.set(sshExecutable, forKey: Key.sshExecutable) }
    }

    @Published var extraPath: String {
        didSet { defaults.set(extraPath, forKey: Key.extraPath) }
    }

    @Published var serverAliveInterval: Int {
        didSet { defaults.set(serverAliveInterval, forKey: Key.serverAliveInterval) }
    }

    @Published var serverAliveCountMax: Int {
        didSet { defaults.set(serverAliveCountMax, forKey: Key.serverAliveCountMax) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != loginItem.isEnabled else { return }
            do {
                try loginItem.setEnabled(launchAtLogin)
                LogStore.log(level: .success, category: "Settings", message: launchAtLogin ? "Registered app for Launch at Login" : "Unregistered app from Launch at Login")
            } catch {
                LogStore.log(level: .error, category: "Settings", message: "SMAppService operation failed", details: error.localizedDescription)
            }
        }
    }

    var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstRun) }
        set { defaults.set(newValue, forKey: Key.hasCompletedFirstRun) }
    }

    init(defaults: UserDefaults = .standard, loginItem: LoginItemControlling = SMAppServiceLoginItem()) {
        self.defaults = defaults
        self.loginItem = loginItem
        showMenuBarItem = defaults.object(forKey: Key.showMenuBarItem) as? Bool ?? true
        hideDockIcon = defaults.bool(forKey: Key.hideDockIcon)
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        connectSilentlyFirst = defaults.object(forKey: Key.connectSilentlyFirst) as? Bool ?? true
        sshExecutable = defaults.string(forKey: Key.sshExecutable) ?? SettingsManager.defaultSSHExecutable
        extraPath = defaults.string(forKey: Key.extraPath) ?? SettingsManager.defaultExtraPath
        serverAliveInterval = defaults.object(forKey: Key.serverAliveInterval) as? Int ?? 30
        serverAliveCountMax = defaults.object(forKey: Key.serverAliveCountMax) as? Int ?? 3
        launchAtLogin = loginItem.isEnabled
        if !showMenuBarItem && hideDockIcon {
            hideDockIcon = false
        }
    }

    func applyDockIconVisibility() {
        guard appliesActivationPolicy else { return }
        let policy: NSApplication.ActivationPolicy = hideDockIcon ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
        if !hideDockIcon {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func resetSSHDefaults() {
        sshExecutable = SettingsManager.defaultSSHExecutable
        extraPath = SettingsManager.defaultExtraPath
        serverAliveInterval = 30
        serverAliveCountMax = 3
    }
}
