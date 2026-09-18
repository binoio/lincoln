//
//  PromptDetector.swift
//  LincolnCore
//
//  Recognizes interactive prompts in ssh's output (Duo passcode menus, key
//  passphrases, host-key confirmations) and the readiness sentinel.
//

import Foundation

public struct DetectedPrompt: Equatable {
    public enum Kind: Equatable {
        /// Password / passphrase: echo must be hidden.
        case secret
        /// Duo "Passcode or option (1-2):" and similar one-time codes.
        case passcode
        /// "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
        case hostKeyConfirmation
        /// Anything else that ends like a question.
        case generic
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public var isSecret: Bool { kind == .secret }
}

public enum PromptDetector {
    /// Classifies the unterminated tail of the console (text after the last
    /// newline). Returns nil when it does not look like a prompt.
    public static func detect(lineTail: String) -> DetectedPrompt? {
        let tail = lineTail.trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty, tail.count <= 512 else { return nil }
        let lowered = tail.lowercased()

        if lowered.contains("(yes/no") || lowered.contains("yes/no/[fingerprint]") {
            return DetectedPrompt(kind: .hostKeyConfirmation, text: tail)
        }
        let endsLikePrompt = tail.hasSuffix(":") || tail.hasSuffix("?") || tail.hasSuffix(">") || tail.hasSuffix("$ ")
        guard endsLikePrompt else { return nil }

        if lowered.contains("password") || lowered.contains("passphrase") || lowered.contains("pin:") {
            return DetectedPrompt(kind: .secret, text: tail)
        }
        if lowered.contains("passcode") || lowered.contains("verification code") || lowered.contains("one-time") || lowered.contains("otp") || lowered.contains("token") {
            return DetectedPrompt(kind: .passcode, text: tail)
        }
        return DetectedPrompt(kind: .generic, text: tail)
    }

    public static func containsReadySentinel(_ text: String, tunnelID: UUID) -> Bool {
        text.contains(SSHCommandBuilder.readySentinel(for: tunnelID))
    }

    /// Whether the output contains a definitive authentication failure.
    public static func containsAuthenticationFailure(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("permission denied") || lowered.contains("authentication failed") || lowered.contains("too many authentication failures")
    }

    /// True for Duo's multi-line menu, which is worth surfacing verbatim.
    public static func looksLikeDuoMenu(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("duo") && (lowered.contains("push") || lowered.contains("passcode"))
    }
}
