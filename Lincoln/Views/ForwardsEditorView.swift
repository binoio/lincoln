//
//  ForwardsEditorView.swift
//  Lincoln
//

import SwiftUI
import LincolnCore

struct ForwardsEditorView: View {
    @ObservedObject var editor: TunnelEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($editor.draft.forwards) { $forward in
                ForwardRow(forward: $forward) {
                    editor.removeForward(id: forward.id)
                }
            }
            if editor.draft.forwards.isEmpty {
                Text("No forwards. Add a SOCKS proxy or a port forward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    editor.addForward(kind: .dynamic)
                } label: {
                    Label("SOCKS Proxy", systemImage: "plus.circle")
                }
                Button {
                    editor.addForward(kind: .local)
                } label: {
                    Label("Local Forward", systemImage: "plus.circle")
                }
                Button {
                    editor.addForward(kind: .remote)
                } label: {
                    Label("Remote Forward", systemImage: "plus.circle")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

private struct ForwardRow: View {
    @Binding var forward: Forward
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $forward.kind) {
                ForEach(Forward.Kind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField("bind", text: $forward.bindAddress, prompt: Text(forward.kind == .remote ? "*" : "localhost"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .help("Bind address (optional)")

            Text(":")
            TextField("port", value: $forward.listenPort, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .help(forward.kind == .remote ? "Port opened on the remote side" : "Local listening port")

            if forward.kind != .dynamic {
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                TextField("host", text: $forward.targetHost, prompt: Text("files.example.org"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)
                    .autocorrectionDisabled()
                Text(":")
                TextField("port", value: $forward.targetPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
            } else {
                Text("SOCKS5 proxy on this port")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Remove forward")
        }
    }
}
