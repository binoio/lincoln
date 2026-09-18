//
//  TunnelSidebarRow.swift
//  Lincoln
//

import SwiftUI
import LincolnCore

struct TunnelSidebarRow: View {
    @ObservedObject var supervisor: TunnelSupervisor

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(state: supervisor.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(supervisor.tunnel.displayName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if supervisor.needsAttention {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundColor(.purple)
                    .help("Waiting for your input in the console")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let forwards = supervisor.tunnel.forwards.map(\.summary).joined(separator: ", ")
        return forwards.isEmpty ? supervisor.tunnel.destinationSummary : "\(supervisor.tunnel.destinationSummary) · \(forwards)"
    }
}
