//
//  ForwardsEditorView.swift
//  Lincoln
//
//  Forwards as an aligned grid: Type · Bind · Port · → · Target host · Port.
//

import SwiftUI
import LincolnCore

struct ForwardsEditorView: View {
    @ObservedObject var editor: TunnelEditorViewModel

    private let typeWidth: CGFloat = 132
    private let bindWidth: CGFloat = 120
    private let portWidth: CGFloat = 68

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editor.draft.forwards.isEmpty {
                Text("No forwards. Add a SOCKS proxy or a port forward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        header("Type").frame(width: typeWidth, alignment: .leading)
                        header("Bind address").frame(width: bindWidth, alignment: .leading)
                        header("Port").frame(width: portWidth, alignment: .leading)
                        Color.clear.frame(width: 14, height: 1)
                        header("Target host")
                        header("Port").frame(width: portWidth, alignment: .leading)
                        Color.clear.frame(width: 18, height: 1)
                    }
                    ForEach($editor.draft.forwards) { $forward in
                        GridRow {
                            Picker("", selection: $forward.kind) {
                                ForEach(Forward.Kind.allCases) { kind in
                                    Text(kind.displayName).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .frame(width: typeWidth)

                            TextField("", text: $forward.bindAddress, prompt: Text(forward.kind == .remote ? "*" : "localhost"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: bindWidth)
                                .help("Bind address (optional)")

                            TextField("", value: $forward.listenPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: portWidth)
                                .help(forward.kind == .remote ? "Port opened on the remote side" : "Local listening port")

                            if forward.kind == .dynamic {
                                Text("SOCKS5 proxy on this port")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .gridCellColumns(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                TextField("", text: $forward.targetHost, prompt: Text("files.example.org"))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 140, maxWidth: .infinity)
                                    .autocorrectionDisabled()
                                TextField("", value: $forward.targetPort, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: portWidth)
                            }

                            Button {
                                editor.removeForward(id: forward.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove forward")
                            .frame(width: 18)
                        }
                    }
                }
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
            .padding(.top, 2)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
