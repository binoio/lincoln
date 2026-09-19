//
//  TunnelInfoView.swift
//  Lincoln
//
//  Get Info: the live status of one tunnel and the exact commands Lincoln
//  runs for it. Read-only; editing stays in the main window.
//

import SwiftUI
import AppKit
import LincolnCore

struct TunnelInfoView: View {
    @ObservedObject var manager: TunnelManager
    let tunnelID: UUID?

    var body: some View {
        if let supervisor = manager.supervisor(for: tunnelID) {
            TunnelInfoContent(supervisor: supervisor)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("This tunnel no longer exists.")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 520, height: 200)
        }
    }
}

private struct TunnelInfoContent: View {
    @ObservedObject var supervisor: TunnelSupervisor
    @State private var copiedLabel: String?

    private var configuredForwards: [Forward] {
        supervisor.controlPath?.destination.configuredForwards ?? []
    }

    private var masterCommand: String {
        SSHCommandBuilder.commandLine(
            executable: "ssh",
            arguments: SSHCommandBuilder.masterArguments(
                for: supervisor.tunnel,
                controlPath: supervisor.controlPath?.path ?? "<ControlPath from ssh -G>",
                configuredForwards: configuredForwards
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(supervisor.tunnel.displayName)
                        .font(.title3.bold())
                    Text(supervisor.tunnel.destinationSummary)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                StatusBadgeView(state: supervisor.state)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section("Status") {
                    LabeledContent("State:") {
                        Text(supervisor.state.detail.map { "\(supervisor.state.label) — \($0)" } ?? supervisor.state.label)
                    }
                    if case .connected(let pid, let since) = supervisor.state {
                        LabeledContent("Control master:") {
                            Text(pid.map { "pid \($0)" } ?? "running")
                                .font(.system(.body, design: .monospaced))
                        }
                        LabeledContent("Connected since:") {
                            Text(since.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if let resolved = supervisor.controlPath {
                        LabeledContent("Control socket:") {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(resolved.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Text(resolved.isFromConfig
                                     ? "From your ssh config — terminal sessions and ProxyJump hops through this host share the tunnel."
                                     : "Your ssh config has no ControlPath for this host, so Lincoln uses its own socket. Terminal sessions will not share it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !configuredForwards.isEmpty {
                        LabeledContent("From ssh config:") {
                            Text(configuredForwards.map(\.summary).joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let checked = supervisor.lastChecked {
                        LabeledContent("Last checked:") {
                            Text(checked.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let mode = supervisor.lastLaunchMode {
                        LabeledContent("Launched:") {
                            Text(mode.description)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = supervisor.lastError {
                        LabeledContent("Last error:") {
                            Text(error)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("Commands") {
                    commandRow(title: "Control master:", command: masterCommand, copyLabel: "Copy Command")
                    if !supervisor.lastCommandLine.isEmpty, supervisor.lastCommandLine != masterCommand {
                        commandRow(title: "Last launch:", command: supervisor.lastCommandLine, copyLabel: "Copy Last Launch")
                    }
                    if let session = supervisor.sessionCommandLine() {
                        commandRow(title: "Terminal session:", command: session, copyLabel: "Copy ssh Command")
                    }
                    commandRow(title: "ssh_config snippet:", command: SSHCommandBuilder.sshConfigSnippet(for: supervisor.tunnel), copyLabel: "Copy ssh_config Snippet")
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 800, minHeight: 420, idealHeight: 560, maxHeight: 900)
        .navigationTitle("\(supervisor.tunnel.displayName) Info")
    }

    private func commandRow(title: String, command: String, copyLabel: String) -> some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copiedLabel == copyLabel ? "Copied" : copyLabel) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    withAnimation { copiedLabel = copyLabel }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { if copiedLabel == copyLabel { copiedLabel = nil } }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}
