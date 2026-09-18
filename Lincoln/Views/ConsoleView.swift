//
//  ConsoleView.swift
//  Lincoln
//
//  The tunnel's terminal output plus an input row for answering prompts
//  (Duo passcode/option, key passphrase, host key confirmation).
//

import SwiftUI
import LincolnCore

struct ConsoleView: View {
    @ObservedObject var supervisor: TunnelSupervisor
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ConsoleTextView(text: supervisor.console.text)

            if supervisor.needsAttention, let prompt = supervisor.currentPrompt {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble.fill")
                        .foregroundColor(.purple)
                    Text(prompt.text)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color.purple.opacity(0.12))
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                if supervisor.currentPrompt?.isSecret == true {
                    SecureField("Answer (hidden)", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .focused($inputFocused)
                        .onSubmit(send)
                } else {
                    TextField(placeholder, text: $input)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($inputFocused)
                        .onSubmit(send)
                }
                Button("Send", action: send)
                    .disabled(!supervisor.state.isRunningProcess)
                Button {
                    supervisor.sendInterrupt()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Send Control-C to ssh")
                .disabled(!supervisor.state.isRunningProcess)
                Button {
                    supervisor.clearConsole()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear console")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onChange(of: supervisor.needsAttention) { _, needs in
            if needs { inputFocused = true }
        }
    }

    private var placeholder: String {
        if !supervisor.state.isRunningProcess { return "Connect to start a session" }
        if supervisor.currentPrompt != nil { return "Type your answer and press Return" }
        return "Send a line to ssh"
    }

    private func send() {
        let text = input
        input = ""
        supervisor.submitInput(text)
    }
}
