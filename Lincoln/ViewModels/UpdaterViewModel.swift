//
//  UpdaterViewModel.swift
//  Lincoln
//

import Combine
import Sparkle
import SwiftUI

@MainActor
public final class UpdaterViewModel: ObservableObject {
    public let updater: SPUUpdater
    @Published public var canCheckForUpdates = false

    public init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    public var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    public var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    public var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    public func checkForUpdates() {
        updater.checkForUpdates()
    }
}

public struct CheckForUpdatesView: View {
    @ObservedObject public var viewModel: UpdaterViewModel

    public init(viewModel: UpdaterViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Button("Check for Updates…") {
            viewModel.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

public struct UpdatesSettingsView: View {
    @ObservedObject public var viewModel: UpdaterViewModel

    public init(viewModel: UpdaterViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { viewModel.automaticallyChecksForUpdates },
                    set: { viewModel.automaticallyChecksForUpdates = $0 }
                ))
                Toggle("Automatically download updates", isOn: Binding(
                    get: { viewModel.automaticallyDownloadsUpdates },
                    set: { viewModel.automaticallyDownloadsUpdates = $0 }
                ))
                .disabled(!viewModel.automaticallyChecksForUpdates)

                if let lastCheck = viewModel.lastUpdateCheckDate {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                CheckForUpdatesView(viewModel: viewModel)
            }
        }
        .padding()
    }
}
