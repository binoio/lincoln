//
//  SettingsView.swift
//  Lincoln
//
//  Settings / Preferences window using standard macOS form controls.
//

import SwiftUI

public struct SettingsView: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var updaterViewModel: UpdaterViewModel
    var environment: SSHEnvironment?
    @State private var sshTestResult: String?

    public var body: some View {
        TabView {
            // MARK: - General Tab
            Form {
                Section("Appearance") {
                    Toggle("Show menu bar item", isOn: $settings.showMenuBarItem)
                    Toggle("Show Dock icon", isOn: Binding(
                        get: { !settings.hideDockIcon },
                        set: { settings.hideDockIcon = !$0 }
                    ))
                    if settings.hideDockIcon {
                        Text("Lincoln will remain available from the menu bar extra while the Dock icon is hidden.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Launch & Startup Behavior") {
                    Toggle("Start Lincoln at login", isOn: $settings.launchAtLogin)
                    Text("Tunnels marked “Connect when Lincoln launches” open a Terminal window at launch. Tunnels that were up last time but are gone are shown as dropped, never reconnected on their own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notifications") {
                    Toggle("Notify when a tunnel drops or fails to connect", isOn: $settings.notificationsEnabled)
                }
            }
            .formStyle(.grouped)
            .padding(10)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            // MARK: - SSH Tab
            Form {
                Section("ssh") {
                    TextField("Executable:", text: $settings.sshExecutable)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Test") { testSSH() }
                        if let result = sshTestResult {
                            Text(result)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                Section("Environment") {
                    TextField("Extra PATH:", text: $settings.extraPath)
                        .textFieldStyle(.roundedBorder)
                    Text("Prepended to PATH for Lincoln's own ssh -G / -O calls, so Match exec helpers (for example the az CLI) resolve when Lincoln is launched from the Dock. The tunnel itself runs in Terminal.app with your login shell environment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Keepalive") {
                    Stepper("ServerAliveInterval: \(settings.serverAliveInterval)s", value: $settings.serverAliveInterval, in: 5...300, step: 5)
                    Stepper("ServerAliveCountMax: \(settings.serverAliveCountMax)", value: $settings.serverAliveCountMax, in: 1...10)
                    Text("The control master gives up after ServerAliveInterval × ServerAliveCountMax seconds without a reply; Lincoln then shows the tunnel as dropped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Reset SSH Settings") { settings.resetSSHDefaults() }
                }
            }
            .formStyle(.grouped)
            .padding(10)
            .tabItem {
                Label("SSH", systemImage: "terminal")
            }

            // MARK: - Sparkle Updates Tab
            Form {
                Section("Software Updates (Sparkle 2)") {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updaterViewModel.automaticallyChecksForUpdates },
                        set: { updaterViewModel.automaticallyChecksForUpdates = $0 }
                    ))

                    Toggle("Automatically download updates", isOn: Binding(
                        get: { updaterViewModel.automaticallyDownloadsUpdates },
                        set: { updaterViewModel.automaticallyDownloadsUpdates = $0 }
                    ))
                    .disabled(!updaterViewModel.automaticallyChecksForUpdates)

                    if let lastCheck = updaterViewModel.lastUpdateCheckDate {
                        LabeledContent("Last checked:", value: lastCheck.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    CheckForUpdatesView(viewModel: updaterViewModel)
                }
            }
            .formStyle(.grouped)
            .padding(10)
            .tabItem {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .frame(width: 520, height: 480)
    }

    private func testSSH() {
        guard let environment = environment else { return }
        sshTestResult = "Running…"
        Task {
            let result = await environment.version()
            let text = (result.standardError + result.standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            sshTestResult = result.exitCode == 0 ? text : "exit \(result.exitCode): \(text)"
        }
    }
}
