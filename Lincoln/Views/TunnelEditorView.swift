//
//  TunnelEditorView.swift
//  Lincoln
//
//  Grouped form for one tunnel. Nothing is persisted until Save.
//

import SwiftUI
import AppKit
import LincolnCore

struct TunnelEditorView: View {
    @ObservedObject var editor: TunnelEditorViewModel
    @ObservedObject var supervisor: TunnelSupervisor
    var onSave: () -> Void
    @State private var showingSnippet = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Tunnel") {
                    TextField("Name:", text: $editor.draft.name, prompt: Text("Gateway SOCKS"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Host:", text: $editor.draft.host, prompt: Text("alias from ~/.ssh/config, or hostname"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    TextField("User:", text: $editor.userText, prompt: Text("inherit from ssh config"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    TextField("Port:", text: $editor.portText, prompt: Text("22"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    HStack {
                        TextField("Identity file:", text: $editor.identityFileText, prompt: Text("inherit (ssh-agent / IdentityFile)"))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button("Choose…") { chooseIdentityFile() }
                    }
                    Text("Only SSH keys are used (PasswordAuthentication is disabled). Duo and other keyboard-interactive prompts appear in the Console.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForwardsEditorView(editor: editor)
                } header: {
                    Text("Forwards")
                } footer: {
                    Text("Lincoln clears any forwards defined for this host in ssh config and applies exactly these.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Behavior") {
                    Toggle("Connect when Lincoln launches", isOn: $editor.draft.autoConnect)
                    Toggle("Reconnect automatically if the connection drops", isOn: $editor.draft.autoReconnect)
                    Toggle("Restart after the Mac wakes from sleep", isOn: $editor.draft.reconnectOnWake)
                    Toggle("Share connection with terminal ssh (act as ControlMaster)", isOn: $editor.draft.shareControlMaster)
                    if editor.draft.shareControlMaster {
                        Text("Uses the ControlPath ssh resolves for this host (see `ssh -G`). Terminal sessions and ProxyJump hops through this host reuse Lincoln's authenticated connection and skip a second Duo prompt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    optionsEditor
                } header: {
                    Text("Extra ssh options")
                } footer: {
                    Text("Passed as -o Key=Value. Options pinned by Lincoln (ClearAllForwardings, ExitOnForwardFailure, PasswordAuthentication) take precedence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notes") {
                    TextEditor(text: $editor.draft.notes)
                        .font(.body)
                        .frame(minHeight: 48, maxHeight: 96)
                }

                Section("Command preview") {
                    Text(editor.commandPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(.secondary)
                    HStack {
                        Button("Copy Command") {
                            copy(editor.commandPreview)
                        }
                        Button("Copy ssh_config Snippet") {
                            copy(editor.configSnippet)
                        }
                        .help("An equivalent Host block you can paste into your own ssh config by hand")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if !editor.validationErrors.isEmpty {
                    Label(editor.validationErrors.joined(separator: " "), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(2)
                } else if editor.hasChanges {
                    Label(supervisor.state.isActive ? "Saving reconnects the tunnel with the new settings." : "Unsaved changes", systemImage: "pencil.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Label("Saved", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Revert") { editor.revert() }
                    .disabled(!editor.hasChanges)
                Button("Save") { onSave() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.canSave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    private var optionsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($editor.draft.extraOptions) { $option in
                HStack {
                    TextField("Key", text: $option.key, prompt: Text("Compression"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    TextField("Value", text: $option.value, prompt: Text("yes"))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        editor.removeOption(id: option.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .autocorrectionDisabled()
            }
            Button {
                editor.addOption()
            } label: {
                Label("Add Option", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose a private key"
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            editor.identityFileText = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
