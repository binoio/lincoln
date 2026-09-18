//
//  SSHEnvironment.swift
//  Lincoln
//
//  Runs Lincoln's own ssh invocations (`-G`, `-O check`, `-O exit`) and
//  resolves, via `ssh -G`, the ControlPath ssh itself would use for a host —
//  which is what lets terminal sessions share a tunnel Lincoln started.
//

import Foundation
import CryptoKit
import LincolnCore

/// What `ssh -G` says about a destination.
struct SSHDestination: Equatable {
    var user: String?
    var hostName: String
    var port: Int
    /// The expanded ControlPath from the user's config, or nil when it is
    /// "none"/absent.
    var configuredControlPath: String?
}

@MainActor
protocol SSHEnvironmentProviding {
    var builderEnvironment: SSHCommandBuilder.Environment { get }
    /// The control socket path Lincoln manages for this tunnel: the user's
    /// configured ControlPath when there is one, else a Lincoln-owned path
    /// under ~/.ssh/sockets. nil when ssh -G fails.
    func resolveControlPath(for tunnel: Tunnel) async -> ResolvedControlPath?
    /// Creates the socket directory (0700) so the master can bind there.
    func prepareControlPathDirectory(_ controlPath: String) throws
}

struct ResolvedControlPath: Equatable {
    var path: String
    /// True when the path came from the user's ssh config (terminal sessions
    /// will share it); false when Lincoln fell back to its own path.
    var isFromConfig: Bool
    var destination: SSHDestination
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
    private let homeDirectory: URL

    init(settings: SettingsManager, fileManager: FileManager = .default, homeDirectory: URL? = nil) {
        self.settings = settings
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
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
            home: homeDirectory.path
        )
    }

    /// Environment for Lincoln's own ssh calls. Match exec helpers referenced
    /// by the user's config run here too, so PATH gets the usual extras.
    static func makeProcessEnvironment(base: [String: String], extraPath: String, home: String) -> [String: String] {
        var env = base
        let extras = extraPath
            .split(separator: ":")
            .map { String($0).replacingOccurrences(of: "~", with: home) }
            .filter { !$0.isEmpty }
        let existing = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (extras + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        env["HOME"] = home
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // These calls never authenticate; make sure nothing tries to prompt.
        env.removeValue(forKey: "SSH_ASKPASS")
        env.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        env.removeValue(forKey: "DISPLAY")
        return env
    }

    func resolveControlPath(for tunnel: Tunnel) async -> ResolvedControlPath? {
        let result = await run(arguments: SSHCommandBuilder.configDumpArguments(for: tunnel))
        guard result.exitCode == 0 else {
            LogStore.log(level: .warning, category: "SSH", message: "ssh -G failed for \(tunnel.trimmedHost)", details: result.standardError)
            return nil
        }
        guard let destination = SSHEnvironment.destination(fromConfigDump: result.standardOutput) else { return nil }
        if let configured = destination.configuredControlPath {
            return ResolvedControlPath(path: configured, isFromConfig: true, destination: destination)
        }
        let fallback = SSHEnvironment.fallbackControlPath(for: destination, home: homeDirectory.path)
        return ResolvedControlPath(path: fallback, isFromConfig: false, destination: destination)
    }

    /// Unix socket paths are limited to 104 bytes on macOS.
    static let maximumSocketPathLength = 100

    /// Lincoln-owned socket for hosts whose config disables multiplexing.
    /// Falls back to a hashed name when the readable one would be too long.
    static func fallbackControlPath(for destination: SSHDestination, home: String) -> String {
        let user = destination.user ?? NSUserName()
        let key = "\(user)@\(destination.hostName):\(destination.port)"
        let readable = "\(home)/.ssh/sockets/lincoln-\(key)"
        if readable.utf8.count <= maximumSocketPathLength { return readable }
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(home)/.ssh/sockets/lincoln-\(digest)"
    }

    /// Extracts user/hostname/port/controlpath from `ssh -G` output.
    static func destination(fromConfigDump dump: String) -> SSHDestination? {
        var values: [String: String] = [:]
        for line in dump.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let hostName = values["hostname"], !hostName.isEmpty else { return nil }
        var controlPath = values["controlpath"]
        if let path = controlPath, path.isEmpty || path.lowercased() == "none" { controlPath = nil }
        return SSHDestination(
            user: values["user"],
            hostName: hostName,
            port: values["port"].flatMap(Int.init) ?? 22,
            configuredControlPath: controlPath
        )
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
