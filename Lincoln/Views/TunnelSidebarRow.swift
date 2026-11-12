//
//  TunnelSidebarRow.swift
//  Lincoln
//

import SwiftUI
import LincolnCore

struct TunnelSidebarRow: View {
    @ObservedObject var supervisor: TunnelSupervisor
    /// True while this row shows the inline rename field.
    var isRenaming: Bool = false
    /// Called with the new name on Return or when the field loses focus.
    var onCommitRename: (String) -> Void = { _ in }
    /// Called on Escape.
    var onCancelRename: () -> Void = {}

    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: supervisor.state)
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($nameFieldFocused)
                        .onSubmit { onCommitRename(draftName) }
                        .onExitCommand { onCancelRename() }
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused && isRenaming { onCommitRename(draftName) }
                        }
                } else {
                    Text(supervisor.tunnel.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(-1)
            Spacer(minLength: 0)
            if supervisor.state.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help(supervisor.state.detail ?? supervisor.state.label)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .onChange(of: isRenaming) { _, renaming in
            guard renaming else { return }
            beginRename()
        }
        .onAppear { if isRenaming { beginRename() } }
    }

    private func beginRename() {
        draftName = supervisor.tunnel.name
        // Focus after the field is in the hierarchy.
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private var subtitle: String {
        let forwards = supervisor.tunnel.forwards.map(\.summary).joined(separator: ", ")
        return forwards.isEmpty ? supervisor.tunnel.destinationSummary : "\(supervisor.tunnel.destinationSummary) · \(forwards)"
    }
}
