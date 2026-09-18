//
//  ControlSocketClient.swift
//  Lincoln
//
//  Talks to a tunnel's ssh ControlMaster through its control socket:
//  `ssh -O check` tells whether it is up (and its pid), `ssh -O exit` stops it.
//

import Foundation
import LincolnCore

struct ControlSocketStatus: Equatable {
    var isRunning: Bool
    var pid: Int32?
    var message: String
}

@MainActor
protocol ControlSocketChecking {
    func check(_ tunnel: Tunnel, controlPath: String) async -> ControlSocketStatus
    /// Returns true when the exit request was accepted.
    func requestExit(_ tunnel: Tunnel, controlPath: String) async -> Bool
}

@MainActor
final class ControlSocketClient: ControlSocketChecking {
    private let environment: SSHEnvironment

    init(environment: SSHEnvironment) {
        self.environment = environment
    }

    func check(_ tunnel: Tunnel, controlPath: String) async -> ControlSocketStatus {
        let result = await environment.run(arguments: SSHCommandBuilder.checkArguments(for: tunnel, controlPath: controlPath))
        let output = (result.standardError + result.standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        return ControlSocketStatus(
            isRunning: result.exitCode == 0,
            pid: SSHCommandBuilder.masterPID(fromCheckOutput: output),
            message: output
        )
    }

    func requestExit(_ tunnel: Tunnel, controlPath: String) async -> Bool {
        let result = await environment.run(arguments: SSHCommandBuilder.exitArguments(for: tunnel, controlPath: controlPath))
        if result.exitCode != 0 {
            LogStore.log(level: .warning, category: "SSH", message: "\(tunnel.displayName): ssh -O exit failed", details: result.standardError)
        }
        return result.exitCode == 0
    }
}
