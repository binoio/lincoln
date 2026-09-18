//
//  StatusBadgeView.swift
//  Lincoln
//

import SwiftUI
import LincolnCore

enum TunnelStateStyle {
    static func tintColor(for state: TunnelState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .reconnecting, .restarting, .disconnecting: return .orange
        case .waitingForInput: return .purple
        case .failed: return .red
        case .idle: return .gray
        }
    }

    static func systemImageName(for state: TunnelState) -> String {
        switch state {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting, .restarting, .disconnecting: return "arrow.triangle.2.circlepath.circle.fill"
        case .waitingForInput: return "questionmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .idle: return "circle"
        }
    }
}

public struct StatusBadgeView: View {
    let state: TunnelState

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(TunnelStateStyle.tintColor(for: state))
                .frame(width: 8, height: 8)
                .shadow(color: state.isConnected ? Color.green.opacity(0.6) : Color.clear, radius: 4)

            Text(state.label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(state == .idle ? .secondary : TunnelStateStyle.tintColor(for: state))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(state == .idle ? Color.gray.opacity(0.12) : TunnelStateStyle.tintColor(for: state).opacity(0.15))
        )
        .overlay(
            Capsule()
                .strokeBorder(state == .idle ? Color.gray.opacity(0.2) : TunnelStateStyle.tintColor(for: state).opacity(0.3), lineWidth: 1)
        )
    }
}

/// The small dot used in the sidebar and menu bar rows.
struct StatusDot: View {
    let state: TunnelState

    var body: some View {
        Circle()
            .fill(TunnelStateStyle.tintColor(for: state))
            .frame(width: 8, height: 8)
            .shadow(color: state.isConnected ? Color.green.opacity(0.6) : Color.clear, radius: 3)
    }
}
