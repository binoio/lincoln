//
//  SSHEnvironment.swift
//  Lincoln
//
//  Resolves the ssh executable, the environment a GUI-launched ssh needs
//  (PATH for ProxyCommand/Match exec helpers, SSH_AUTH_SOCK) and, via
//  `ssh -G`, the ControlPath ssh itself would use for a host.
//

import Foundation
import LincolnCore

@MainActor
protocol SSHEnvironmentProviding {
    var builderEnvironment: SSHCommandBuilder.Environment { get }
    func processEnvironment() -> [String: String]
    /// The fully expanded ControlPath ssh would use for this tunnel's host,
    /// or nil when multiplexing is disabled (`none`) or resolution fails.
    func resolveControlPath(for tunnel: Tunnel) async -> String?
    /// Creates the socket directory (0700) so ControlMaster can bind there.
    func prepareControlPathDirectory(_ controlPath: String) throws
}

struct SSHCommandResult: Equatable {
    var standardOutput: String
    var standardError: String
    var exitCode: Int32
}

@MainActor
final class SSHEnvironment: SSHEnvironmentProviding {
    private let settings: SettingsManager
    private let fileManager: FileManager

    init(settings: SettingsManager, fileManager: FileManager = .default) {
        self.settings = settings
        self.fileManager = fileManager
    }

    var builderEnvironment: SSHCommandBuilder.Environment {
        SSHCommandBuilder.Environment(
            sshExecutable: settings.sshExecutable,
            serverAliveInterval: settings.serverAliveInterval,
            serverAliveCountMax: settings.serverAliveCountMax
        )
    }

    func processEnvironment() -> [String: String] {
        SSHEnvironment.makeProcessEnvironment(
            base: ProcessInfo.processInfo.environment,
            extraPath: settings.extraPath,
            sshAuthSock: settings.sshAuthSock,
            home: fileManager.homeDirectoryForCurrentUser.path
        )
    }

    /// Pure helper shared with tests.
    static func makeProcessEnvironment(base: [String: String], extraPath: String, sshAuthSock: String, home: String) -> [String: String] {
        var env = base
        let expandedHome = home
        let extras = extraPath
            .split(separator: ":")
            .map { String($0).replacingOccurrences(of: "~", with: expandedHome) }
            .filter { !$0.isEmpty }
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let merged = (extras + existing).filter { seen.insert($0).inserted }
        env["PATH"] = merged.joined(separator: ":")
        env["TERM"] = "dumb"
        env["HOME"] = expandedHome
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let sock = sshAuthSock.trimmingCharacters(in: .whitespaces)
        if !sock.isEmpty {
            env["SSH_AUTH_SOCK"] = sock.replacingOccurrences(of: "~", with: expandedHome)
        }
        // Never let ssh pop a GUI askpass; prompts belong in the console.
        env.removeValue(forKey: "SSH_ASKPASS")
        env.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        env.removeValue(forKey: "DISPLAY")
        return env
    }

    func resolveControlPath(for tunnel: Tunnel) async -> String? {
        var args: [String] = ["-G"]
        if let port = tunnel.port { args += ["-p", String(port)] }
        if let user = tunnel.user, !user.isEmpty { args += ["-l", user] }
        args += ["--", tunnel.trimmedHost]
        let result = await run(arguments: args)
        guard result.exitCode == 0 else {
            LogStore.log(level: .warning, category: "SSH", message: "ssh -G failed for \(tunnel.trimmedHost)", details: result.standardError)
            return nil
        }
        return SSHEnvironment.controlPath(fromConfigDump: result.standardOutput)
    }

    /// Extracts `controlpath` from `ssh -G` output; nil for "none"/absent.
    static func controlPath(fromConfigDump dump: String) -> String? {
        for line in dump.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].lowercased() == "controlpath" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.lowercased() == "none" || value.isEmpty ? nil : value
        }
        return nil
    }

    func prepareControlPathDirectory(_ controlPath: String) throws {
        let expanded = (controlPath as NSString).expandingTildeInPath
        let directory = (expanded as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return }
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// `ssh -V` for the Settings "Test" button.
    func version() async -> SSHCommandResult {
        await run(arguments: ["-V"])
    }

    func run(arguments: [String]) async -> SSHCommandResult {
        let executable = settings.sshExecutable
        let environment = processEnvironment()
        return await Task.detached(priority: .userInitiated) {
            SSHEnvironment.runSynchronously(executable: executable, arguments: arguments, environment: environment)
        }.value
    }

    nonisolated static func runSynchronously(executable: String, arguments: [String], environment: [String: String]) -> SSHCommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return SSHCommandResult(standardOutput: "", standardError: error.localizedDescription, exitCode: -1)
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return SSHCommandResult(
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self),
            exitCode: task.terminationStatus
        )
    }
}
