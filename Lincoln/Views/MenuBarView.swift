//
//  MenuBarView.swift
//  Lincoln
//
//  Standard macOS Menu Bar Extra dropdown menu content conforming to macOS HIG conventions.
//

import SwiftUI
import AppKit
import LincolnCore

public struct MenuBarView: View {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var updaterViewModel: UpdaterViewModel
    var openMainWindowAction: () -> Void
    var openLogsWindowAction: () -> Void
    var quitAction: () -> Void

    public var body: some View {
        // MARK: - Status Header
        Button(headerText) {}
            .disabled(true)

        Divider()

        // MARK: - Per-tunnel toggles
        MenuBarTunnelToggles(manager: manager)

        Divider()

        MenuBarBulkActions(manager: manager)

        Divider()

        // MARK: - Window & Preferences Actions
        MenuBarWindowActions(
            updaterViewModel: updaterViewModel,
            openMainWindowAction: openMainWindowAction,
            openLogsWindowAction: openLogsWindowAction
        )

        Divider()

        // MARK: - Quit Action
        Button("Quit Lincoln") {
            quitAction()
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var headerText: String {
        if manager.anyNeedsAttention { return "Lincoln: a tunnel needs your input" }
        let connected = manager.connectedCount
        if connected == 0 { return "Lincoln: no tunnels connected" }
        return "Lincoln: \(connected) tunnel\(connected == 1 ? "" : "s") connected"
    }

}

private struct MenuBarTunnelToggles: View {
    @ObservedObject var manager: TunnelManager

    var body: some View {
        if manager.supervisors.isEmpty {
            Button("No tunnels configured") {}
                .disabled(true)
        } else {
            ForEach(manager.supervisors) { supervisor in
                MenuBarTunnelToggle(manager: manager, supervisor: supervisor)
            }
        }
    }
}

private struct MenuBarTunnelToggle: View {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var supervisor: TunnelSupervisor

    var body: some View {
        Toggle(isOn: Binding(
            get: { supervisor.state.isActive },
            set: { _ in manager.toggle(id: supervisor.id) }
        )) {
            Text(title)
        }
    }

    private var title: String {
        switch supervisor.state {
        case .idle: return supervisor.tunnel.displayName
        default: return "\(supervisor.tunnel.displayName) — \(supervisor.state.label)"
        }
    }
}

private struct MenuBarBulkActions: View {
    @ObservedObject var manager: TunnelManager

    var body: some View {
        Button("Connect All") {
            manager.connectAll()
        }
        .disabled(manager.supervisors.isEmpty || manager.supervisors.allSatisfy { $0.state.isActive })

        Button("Disconnect All") {
            manager.disconnectAll()
        }
        .disabled(manager.activeCount == 0)
    }
}

private struct MenuBarWindowActions: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel
    var openMainWindowAction: () -> Void
    var openLogsWindowAction: () -> Void

    var body: some View {
        Button("Open Lincoln…") {
            openMainWindowAction()
        }

        Button("Diagnostic Logs…") {
            openLogsWindowAction()
        }

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        .keyboardShortcut(",", modifiers: .command)

        CheckForUpdatesView(viewModel: updaterViewModel)
    }
}

// MARK: - Menu Bar Vector Icon Generation

public enum MenuBarIcon {
    public enum Variant: Equatable {
        case disconnected
        case connected
        case attention
    }

    public static let disconnected: NSImage = makeImage(.disconnected)
    public static let connected: NSImage = makeImage(.connected)
    public static let attention: NSImage = makeImage(.attention)

    public static func image(for variant: Variant) -> NSImage {
        switch variant {
        case .disconnected: return disconnected
        case .connected: return connected
        case .attention: return attention
        }
    }

    /// A tunnel portal: an arch with a road running in; the opening is lit
    /// (filled) when a tunnel is connected, and carries an exclamation mark
    /// when one is waiting for input.
    public static func makeImage(_ variant: Variant) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)

            // Arch outline (portal), 2pt stroke.
            let arch = CGMutablePath()
            arch.move(to: CGPoint(x: 3, y: 2.5))
            arch.addLine(to: CGPoint(x: 3, y: 9))
            arch.addArc(center: CGPoint(x: 9, y: 9), radius: 6, startAngle: .pi, endAngle: 0, clockwise: true)
            arch.addLine(to: CGPoint(x: 15, y: 2.5))
            ctx.addPath(arch)
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            ctx.strokePath()

            // Ground line.
            ctx.move(to: CGPoint(x: 1, y: 2.5))
            ctx.addLine(to: CGPoint(x: 17, y: 2.5))
            ctx.setLineWidth(1.5)
            ctx.strokePath()

            switch variant {
            case .disconnected:
                break
            case .connected:
                // Lit opening.
                let opening = CGMutablePath()
                opening.move(to: CGPoint(x: 6, y: 3.5))
                opening.addLine(to: CGPoint(x: 6, y: 9))
                opening.addArc(center: CGPoint(x: 9, y: 9), radius: 3, startAngle: .pi, endAngle: 0, clockwise: true)
                opening.addLine(to: CGPoint(x: 12, y: 3.5))
                opening.closeSubpath()
                ctx.addPath(opening)
                ctx.fillPath()
            case .attention:
                // Exclamation mark inside the portal.
                ctx.fill(CGRect(x: 8, y: 7, width: 2, height: 5.5))
                ctx.fillEllipse(in: CGRect(x: 7.9, y: 4, width: 2.2, height: 2.2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
