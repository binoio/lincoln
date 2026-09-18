//
//  ContentView.swift
//  Lincoln
//
//  Main window: tunnel list in the sidebar, status + editor in the detail.
//

import SwiftUI
import LincolnCore

public struct ContentView: View {
    @ObservedObject var manager: TunnelManager
    @Environment(\.openWindow) private var openWindow
    @State private var showingImport = false

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let supervisor = manager.selectedSupervisor {
                TunnelDetailView(manager: manager, supervisor: supervisor)
                    .id(supervisor.id)
            } else {
                emptyState
            }
        }
        .navigationTitle("Lincoln")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    manager.addNewTunnel()
                } label: {
                    Label("New Tunnel", systemImage: "plus")
                }
                .help("New Tunnel (⌘N)")

                Button {
                    showingImport = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import hosts from ~/.ssh/config (⇧⌘I)")

                Button {
                    openWindow(id: "logs")
                } label: {
                    Label("Logs", systemImage: "scroll")
                }
                .help("Open Diagnostic Logs (⌥⌘L)")
            }
        }
        .sheet(isPresented: $showingImport) {
            ImportSheetView(manager: manager)
        }
        .alert(
            "Remove “\(manager.supervisor(for: manager.pendingRemovalID)?.tunnel.displayName ?? "")”?",
            isPresented: Binding(
                get: { manager.pendingRemovalID != nil },
                set: { if !$0 { manager.pendingRemovalID = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let id = manager.pendingRemovalID { manager.remove(id: id) }
                manager.pendingRemovalID = nil
            }
            Button("Cancel", role: .cancel) { manager.pendingRemovalID = nil }
        } message: {
            Text("The tunnel is removed from Lincoln. A running control master is left alone, and your ~/.ssh/config is not touched.")
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 500, idealHeight: 620)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { manager.selectedTunnelID },
                set: { if manager.selectedTunnelID != $0 { manager.selectedTunnelID = $0 } }
            )) {
                Section("Tunnels") {
                    ForEach(manager.supervisors) { supervisor in
                        TunnelSidebarRow(supervisor: supervisor)
                            .tag(supervisor.id)
                            .contextMenu { contextMenu(for: supervisor) }
                    }
                    .onMove { manager.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                manager.requestRemoval(id: manager.selectedTunnelID)
            }

            Divider()

            HStack {
                Text(summaryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    manager.connectAll()
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .help("Connect All (⇧⌘T)")
                .disabled(manager.supervisors.allSatisfy { $0.state.isActive })

                Button {
                    manager.disconnectAll()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .help("Disconnect All")
                .disabled(manager.activeCount == 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var summaryText: String {
        let count = manager.supervisors.count
        if count == 0 { return "No tunnels" }
        return "\(manager.connectedCount) of \(count) connected"
    }

    @ViewBuilder
    private func contextMenu(for supervisor: TunnelSupervisor) -> some View {
        Button(supervisor.state.isActive ? "Disconnect" : "Connect") {
            manager.toggle(id: supervisor.id)
        }
        Button("Duplicate") {
            manager.duplicate(id: supervisor.id)
        }
        Divider()
        Button("Remove…") {
            manager.requestRemoval(id: supervisor.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text(manager.supervisors.isEmpty ? "No tunnels yet" : "Select a tunnel")
                .font(.title2.bold())
            if manager.supervisors.isEmpty {
                Text("Import the hosts you already use from ~/.ssh/config, or create a tunnel from scratch. Lincoln never edits your ssh configuration.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 12) {
                    Button {
                        showingImport = true
                    } label: {
                        Label("Import from ssh config…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        manager.addNewTunnel()
                    } label: {
                        Label("New Tunnel", systemImage: "plus")
                    }
                }
                .controlSize(.large)
            }
            if let warning = manager.loadWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(8)
                    .background(Color.yellow.opacity(0.12))
                    .cornerRadius(8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
