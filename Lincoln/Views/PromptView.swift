//
//  PromptView.swift
//  Lincoln
//
//  The panel that answers an ssh prompt relayed through lincoln-askpass:
//  Duo passcode/option, key passphrase, host-key confirmation.
//

import SwiftUI
import LincolnCore

struct PromptView: View {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var prompt: PendingPrompt
    @State private var answer = ""
    @FocusState private var fieldFocused: Bool

    private var supervisor: TunnelSupervisor? { manager.supervisor(for: prompt.tunnelID) }
    private var kind: PromptKind { PromptClassifier.kind(prompt: prompt.request.prompt, hint: prompt.request.hint) }
    private var isNotification: Bool { PromptClassifier.isNotification(hint: prompt.request.hint) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: kind == .secret ? "key.fill" : (kind == .confirmation ? "questionmark.diamond.fill" : "person.badge.key.fill"))
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(supervisor?.tunnel.displayName ?? "Lincoln")
                        .font(.headline)
                    Text(supervisor?.tunnel.destinationSummary ?? "ssh needs an answer")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let output = supervisor?.recentOutput.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("end")
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }

            Text(prompt.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.body.weight(.medium))
                .textSelection(.enabled)

            if isNotification {
                Text("No answer is needed; ssh continues once you complete the action it describes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if kind == .confirmation {
                Text("Answer “yes” only if you recognize this host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Group {
                    if kind == .secret {
                        SecureField("", text: $answer)
                    } else {
                        TextField("", text: $answer, prompt: Text("e.g. 1 for a Duo push, or a passcode"))
                            .autocorrectionDisabled()
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(submit)
            }

            HStack {
                Text(kind == .secret ? "Your answer is passed to ssh and never stored." : "Answers are passed straight to ssh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { manager.cancelActivePrompt() }
                    .keyboardShortcut(.cancelAction)
                if isNotification {
                    Button("OK") { manager.answerActivePrompt("") }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if kind == .confirmation {
                    Button("No") { manager.answerActivePrompt("no") }
                    Button("Yes") { manager.answerActivePrompt("yes") }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Send", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(answer.isEmpty && kind == .secret)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        manager.answerActivePrompt(answer)
        answer = ""
    }
}
