//
//  ImportSheetView.swift
//  Lincoln
//
//  Read-only import of Host aliases from ~/.ssh/config (and its Includes).
//

import SwiftUI
import LincolnCore

struct ImportSheetView: View {
    @ObservedObject var manager: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: [SSHConfigHost] = []
    @State private var selected: Set<String> = []
    @State private var loaded = false

    private var existingAliases: Set<String> {
        Set(manager.document.tunnels.map(\.host))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from ssh config")
                        .font(.headline)
                    Text(manager.sshConfigPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Select Forwarding Hosts") {
                    selected = Set(hosts.filter { !$0.forwards.isEmpty }.compactMap(\.alias))
                }
                .font(.caption)
            }
            .padding(16)

            Divider()

            if hosts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text(loaded ? "No Host entries found" : "Reading…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(hosts) { host in
                        if let alias = host.alias {
                            Toggle(isOn: binding(for: alias)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(alias).font(.body)
                                            if existingAliases.contains(alias) {
                                                Text("already imported")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.gray.opacity(0.15))
                                                    .cornerRadius(4)
                                            }
                                        }
                                        Text(detail(for: host))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if !host.forwards.isEmpty {
                                        Image(systemName: "arrow.left.arrow.right")
                                            .foregroundColor(.accentColor)
                                            .help(host.forwards.map(\.summary).joined(separator: "\n"))
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("Lincoln reads your config and never modifies it. Hosts without forwards get a SOCKS proxy you can change afterwards.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(selected.count)") {
                    let chosen = hosts.filter { $0.alias.map(selected.contains) ?? false }
                    manager.importHosts(chosen)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
        .onAppear(perform: loadHosts)
    }

    private func binding(for alias: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(alias) },
            set: { on in
                if on { selected.insert(alias) } else { selected.remove(alias) }
            }
        )
    }

    private func detail(for host: SSHConfigHost) -> String {
        var parts: [String] = []
        if let hostName = host.hostName { parts.append(hostName) }
        if let user = host.user { parts.append("user \(user)") }
        if let jump = host.proxyJump, jump != "none" { parts.append("via \(jump)") }
        if !host.forwards.isEmpty { parts.append(host.forwards.map(\.summary).joined(separator: ", ")) }
        parts.append(URL(fileURLWithPath: host.sourcePath).lastPathComponent)
        return parts.joined(separator: " · ")
    }

    private func loadHosts() {
        hosts = manager.importableHosts()
        selected = Set(hosts.filter { !$0.forwards.isEmpty && !existingAliases.contains($0.alias ?? "") }.compactMap(\.alias))
        loaded = true
    }
}
