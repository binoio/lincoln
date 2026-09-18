//
//  TunnelDetailView.swift
//  Lincoln
//

import SwiftUI
import LincolnCore

struct TunnelDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case configure = "Configure"
        case console = "Console"
        var id: String { rawValue }
    }

    @ObservedObject var manager: TunnelManager
    @ObservedObject var supervisor: TunnelSupervisor
    @StateObject private var editor: TunnelEditorViewModel
    @State private var tab: Tab

    init(manager: TunnelManager, supervisor: TunnelSupervisor) {
        self.manager = manager
        self.supervisor = supervisor
        _editor = StateObject(wrappedValue: TunnelEditorViewModel(tunnel: supervisor.tunnel))
        _tab = State(initialValue: supervisor.tunnel.isValid ? .console : .configure)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .configure:
                TunnelEditorView(editor: editor, supervisor: supervisor, onSave: save)
            case .console:
                ConsoleView(supervisor: supervisor)
            }
        }
        .onChange(of: supervisor.needsAttention) { _, needs in
            if needs { tab = .console }
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
                StatusBadgeView(state: supervisor.state)
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
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                Spacer()

                if let error = supervisor.lastError, !supervisor.state.isActive {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .help(error)
                } else if !supervisor.tunnel.forwards.isEmpty {
                    Text(supervisor.tunnel.forwards.map(\.summary).joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func save() {
        guard let tunnel = editor.commit() else { return }
        manager.update(tunnel)
        if supervisor.state.isActive {
            supervisor.restart()
        }
    }
}
