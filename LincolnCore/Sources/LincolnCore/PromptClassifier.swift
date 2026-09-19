//
//  PromptClassifier.swift
//  LincolnCore
//
//  Decides how an ssh prompt relayed through SSH_ASKPASS should be shown.
//

import Foundation

public enum PromptKind: Equatable {
    /// Passphrase or password: hide the input.
    case secret
    /// A yes/no question (host key confirmation, "Are you sure…").
    case confirmation
    /// Anything typed in the clear, e.g. Duo "Passcode or option (1-2):".
    case text
}

public enum PromptClassifier {
    /// - Parameters:
    ///   - prompt: the text ssh passed to the askpass program.
    ///   - hint: the value of `SSH_ASKPASS_PROMPT` ("confirm", "none", or nil).
    public static func kind(prompt: String, hint: String?) -> PromptKind {
        if hint?.lowercased() == "confirm" { return .confirmation }
        let lowered = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.contains("(yes/no") || lowered.contains("yes/no/[fingerprint]") { return .confirmation }
        if lowered.contains("passphrase") || lowered.contains("password") || lowered.hasSuffix("pin:") { return .secret }
        return .text
    }

    /// Whether the prompt is informational only (ssh's notifier, e.g.
    /// "Confirm user presence for key…") and needs no answer.
    public static func isNotification(hint: String?) -> Bool {
        hint?.lowercased() == "none"
    }
}
