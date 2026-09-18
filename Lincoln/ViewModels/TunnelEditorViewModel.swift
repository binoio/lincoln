//
//  TunnelEditorViewModel.swift
//  Lincoln
//
//  Holds an editable draft of a tunnel; changes are written back to the
//  TunnelManager only on Save, so a half-edited tunnel never reaches disk.
//

import Foundation
import Combine
import LincolnCore

@MainActor
final class TunnelEditorViewModel: ObservableObject {
    @Published var draft: Tunnel
    private(set) var original: Tunnel

    // String-backed fields for optional numeric/text values.
    @Published var userText: String
    @Published var portText: String
    @Published var identityFileText: String

    init(tunnel: Tunnel) {
        draft = tunnel
        original = tunnel
        userText = tunnel.user ?? ""
        portText = tunnel.port.map(String.init) ?? ""
        identityFileText = tunnel.identityFile ?? ""
    }

    /// The draft with the string-backed fields folded in.
    var resolvedDraft: Tunnel {
        var tunnel = draft
        let user = userText.trimmingCharacters(in: .whitespaces)
        tunnel.user = user.isEmpty ? nil : user
        let port = portText.trimmingCharacters(in: .whitespaces)
        tunnel.port = port.isEmpty ? nil : Int(port)
        let identity = identityFileText.trimmingCharacters(in: .whitespaces)
        tunnel.identityFile = identity.isEmpty ? nil : identity
        tunnel.name = tunnel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        tunnel.host = tunnel.trimmedHost
        return tunnel
    }

    var validationErrors: [String] {
        var errors = resolvedDraft.validationErrors
        let port = portText.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty, Int(port) == nil {
            errors.append("Port must be a number.")
        }
        return errors
    }

    var isValid: Bool { validationErrors.isEmpty }
    var hasChanges: Bool { resolvedDraft != original }
    var canSave: Bool { hasChanges && isValid }

    func reset(to tunnel: Tunnel) {
        original = tunnel
        draft = tunnel
        userText = tunnel.user ?? ""
        portText = tunnel.port.map(String.init) ?? ""
        identityFileText = tunnel.identityFile ?? ""
    }

    func revert() {
        reset(to: original)
    }

    /// Returns the tunnel to persist, or nil when nothing valid changed.
    func commit() -> Tunnel? {
        guard canSave else { return nil }
        let tunnel = resolvedDraft
        original = tunnel
        draft = tunnel
        return tunnel
    }

    // MARK: - Forwards

    func addForward(kind: Forward.Kind) {
        let used = Set(draft.forwards.map(\.listenPort))
        var port = kind == .dynamic ? 1080 : 8080
        while used.contains(port) { port += 1 }
        switch kind {
        case .dynamic:
            draft.forwards.append(Forward.dynamic(port: port))
        case .local:
            draft.forwards.append(Forward.local(port: port, host: "localhost", hostPort: port))
        case .remote:
            draft.forwards.append(Forward.remote(port: port, host: "localhost", hostPort: port))
        }
    }

    func removeForward(id: UUID) {
        draft.forwards.removeAll { $0.id == id }
    }

    func addOption() {
        draft.extraOptions.append(SSHOption(key: "", value: ""))
    }

    func removeOption(id: UUID) {
        draft.extraOptions.removeAll { $0.id == id }
    }

    var configSnippet: String {
        SSHCommandBuilder.sshConfigSnippet(for: resolvedDraft)
    }

    /// The control master command, with a placeholder socket path until ssh -G resolves it.
    func commandPreview(controlPath: String?, configuredForwards: [Forward] = []) -> String {
        SSHCommandBuilder.commandLine(
            executable: "ssh",
            arguments: SSHCommandBuilder.masterArguments(for: resolvedDraft, controlPath: controlPath ?? "<ControlPath from ssh -G>", configuredForwards: configuredForwards)
        )
    }
}
