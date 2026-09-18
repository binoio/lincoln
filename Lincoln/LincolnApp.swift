//
//  LincolnApp.swift
//  Lincoln
//
//  GUI Dock and Menubar App for establishing and maintaining SSH tunnels on macOS.
//

import SwiftUI
import Sparkle
import LincolnCore

@MainActor
class LincolnAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    lazy var updaterViewModel = UpdaterViewModel(updater: updaterController.updater)
    var manager: TunnelManager?
    var settings: SettingsManager?

    static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil, !LincolnAppDelegate.isRunningTests {
            updaterController.startUpdater()
        }
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }

        let hideDock = UserDefaults.standard.bool(forKey: SettingsManager.Key.hideDockIcon)
        if hideDock {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                for window in NSApp.windows where window.canBecomeMain {
                    window.orderOut(nil)
                }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                if let firstWindow = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    firstWindow.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LogStore.log(level: .info, category: "Lifecycle", message: "applicationShouldTerminate: control masters keep running")
        manager?.prepareForQuit()
        return .terminateNow
    }
}

@main
struct LincolnApp: App {
    @NSApplicationDelegateAdaptor(LincolnAppDelegate.self) var appDelegate
    @StateObject private var settings: SettingsManager
    @StateObject private var manager: TunnelManager
    @StateObject private var logStore = LogStore.shared
    @Environment(\.openWindow) private var openWindow

    private let sshEnvironment: SSHEnvironment
    private let networkMonitor = NetworkMonitor()
    private let powerMonitor = PowerMonitor()

    init() {
        let settings = SettingsManager()
        let environment = SSHEnvironment(settings: settings)
        let notifier = NotificationService(isEnabled: { [weak settings] in settings?.notificationsEnabled ?? false })
        let manager = TunnelManager(
            store: TunnelStore(fileURL: TunnelStore.defaultFileURL()),
            settings: settings,
            environment: environment,
            launcher: TerminalAppLauncher(),
            headless: environment,
            socket: ControlSocketClient(environment: environment),
            notifier: notifier
        )
        _settings = StateObject(wrappedValue: settings)
        _manager = StateObject(wrappedValue: manager)
        sshEnvironment = environment

        if !LincolnAppDelegate.isRunningTests {
            manager.load()
            Task { @MainActor in
                await manager.restore()
                manager.startPolling()
            }
        }
        networkMonitor.onPathChanged = { [weak manager] in manager?.pollSoon() }
        powerMonitor.onDidWake = { [weak manager] in manager?.pollSoon() }
        networkMonitor.start()
        powerMonitor.start()
    }

    var body: some Scene {
        // MARK: - Main Dock Window
        WindowGroup("Lincoln", id: "main") {
            ContentView(manager: manager)
                .onAppear {
                    appDelegate.manager = manager
                    appDelegate.settings = settings
                    settings.applyDockIconVisibility()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            LincolnCommands(manager: manager, updaterViewModel: appDelegate.updaterViewModel, openLogs: {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "logs")
            }, openMainWindow: {
                openWindow(id: "main")
                DispatchQueue.main.async {
                    if let firstWindow = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        firstWindow.makeKeyAndOrderFront(nil)
                    }
                }
            }, quit: quit)
        }

        // MARK: - Menu Bar Item (Native macOS NSMenu style)
        // Guarded binding: SwiftUI writes isInserted back on every update, and an
        // unconditional @Published set would re-render forever.
        MenuBarExtra(isInserted: Binding(
            get: { settings.showMenuBarItem },
            set: { if settings.showMenuBarItem != $0 { settings.showMenuBarItem = $0 } }
        )) {
            MenuBarView(
                manager: manager,
                updaterViewModel: appDelegate.updaterViewModel,
                openMainWindowAction: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                    DispatchQueue.main.async {
                        if let firstWindow = NSApp.windows.first(where: { $0.canBecomeMain }) {
                            firstWindow.makeKeyAndOrderFront(nil)
                        }
                    }
                },
                openLogsWindowAction: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "logs")
                },
                quitAction: quit
            )
        } label: {
            Image(nsImage: MenuBarIcon.image(for: menuBarVariant))
                .renderingMode(.template)
                .help(menuBarHelp)
        }
        .menuBarExtraStyle(.menu)

        // MARK: - Diagnostic Logs Window
        Window("Diagnostic Logs", id: "logs") {
            LogsView(logStore: logStore)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        // MARK: - Settings Window
        Settings {
            SettingsView(settings: settings, updaterViewModel: appDelegate.updaterViewModel, environment: sshEnvironment)
        }
    }

    private var menuBarVariant: MenuBarIcon.Variant {
        if manager.anyNeedsAttention { return .attention }
        return manager.anyConnected ? .connected : .disconnected
    }

    private var menuBarHelp: String {
        if manager.anyNeedsAttention { return "Lincoln: a tunnel dropped" }
        return manager.anyConnected ? "Lincoln: \(manager.connectedCount) connected" : "Lincoln: no tunnels connected"
    }

    private func quit() {
        manager.prepareForQuit()
        NSApplication.shared.terminate(nil)
    }
}

/// Menu bar commands, kept in their own Commands type so the app body stays
/// small (SwiftUI's opaque-type machinery struggles with deeply nested
/// command builders).
struct LincolnCommands: Commands {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var updaterViewModel: UpdaterViewModel
    var openLogs: () -> Void
    var openMainWindow: () -> Void
    var quit: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit Lincoln", action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }

        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(viewModel: updaterViewModel)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tunnel") {
                manager.addNewTunnel()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Import from ssh config…") {
                NSApp.activate(ignoringOtherApps: true)
                openMainWindow()
                manager.showingImport = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Divider()

            Button("Duplicate Tunnel") {
                if let id = manager.selectedTunnelID { manager.duplicate(id: id) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(manager.selectedTunnelID == nil)

            Button("Remove Tunnel…") {
                manager.requestRemoval(id: manager.selectedTunnelID)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(manager.selectedTunnelID == nil)
        }

        CommandMenu("Tunnel") {
            TunnelMenuItems(manager: manager)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Logs", action: openLogs)
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}

private struct TunnelMenuItems: View {
    @ObservedObject var manager: TunnelManager

    private var selectedIsActive: Bool {
        manager.selectedSupervisor?.state.isActive == true
    }

    var body: some View {
        Button(selectedIsActive ? "Disconnect" : "Connect") {
            if let id = manager.selectedTunnelID { manager.toggle(id: id) }
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(manager.selectedTunnelID == nil)

        Button("Copy ssh Command") {
            if let command = manager.selectedSupervisor?.sessionCommandLine() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(manager.selectedSupervisor?.sessionCommandLine() == nil)

        Divider()

        Button("Connect All") {
            manager.connectAll()
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])

        Button("Disconnect All") {
            manager.disconnectAll()
        }
    }
}
