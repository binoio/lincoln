//
//  TunnelDetailView.swift
//  Lincoln
//

import SwiftUI
import LincolnCore

struct TunnelDetailView: View {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var supervisor: TunnelSupervisor
    @StateObject private var editor: TunnelEditorViewModel
    @State private var copiedCommand = false

    init(manager: TunnelManager, supervisor: TunnelSupervisor) {
        self.manager = manager
        self.supervisor = supervisor
        _editor = StateObject(wrappedValue: TunnelEditorViewModel(tunnel: supervisor.tunnel))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TunnelEditorView(editor: editor, supervisor: supervisor, onSave: save)
        }
        .onReceive(supervisor.$tunnel) { tunnel in
            // Keep the editor in sync when the tunnel changes elsewhere (e.g. import).
            if !editor.hasChanges && editor.original != tunnel {
                editor.reset(to: tunnel)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(supervisor.tunnel.displayName)
                        .font(.title2.bold())
                    Text(supervisor.tunnel.destinationSummary)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    Button("Duplicate Tunnel") { manager.duplicate(id: supervisor.id) }
                    Button("Remove Tunnel…", role: .destructive) { manager.requestRemoval(id: supervisor.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
                Button {
                    copySessionCommand()
                } label: {
                    Label(copiedCommand ? "Copied" : "Copy ssh Command", systemImage: copiedCommand ? "checkmark" : "doc.on.doc")
                }
                .help("Copy an ssh command for your terminal that opens a session on this host through the tunnel (no second Duo prompt)")
                .disabled(supervisor.sessionCommandLine() == nil)
                Button {
                    manager.toggle(id: supervisor.id)
                } label: {
                    Label(supervisor.state.isActive ? "Disconnect" : "Connect", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .tint(supervisor.state.isActive ? .red : .accentColor)
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!supervisor.tunnel.isValid && !supervisor.state.isActive)
            }

            HStack {
                if let detail = supervisor.state.detail {
                    Label(detail, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(TunnelStateStyle.tintColor(for: supervisor.state))
                        .lineLimit(1)
                        .help(detail)
                } else if let error = supervisor.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .help(error)
                } else if supervisor.state.isConnecting {
                    Text(supervisor.lastLaunchMode == .silent
                         ? "Starting the control master with your keys…"
                         : "Answer the prompt in the Terminal window; the tunnel appears here once the control socket is up.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if !supervisor.tunnel.forwards.isEmpty {
                    Text(supervisor.tunnel.forwards.map(\.summary).joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                // Status sits under the Connect/Disconnect button it describes.
                StatusBadgeView(state: supervisor.state)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func copySessionCommand() {
        guard let command = supervisor.sessionCommandLine() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        withAnimation { copiedCommand = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copiedCommand = false }
        }
    }

    private func save() {
        guard let tunnel = editor.commit() else { return }
        manager.update(tunnel)
    }
}
