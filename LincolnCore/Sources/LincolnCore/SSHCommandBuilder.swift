//
//  SSHCommandBuilder.swift
//  LincolnCore
//
//  Turns a Tunnel into a deterministic ssh argument vector. The user's
//  ~/.ssh/config is still consulted by ssh (no -F), so ProxyJump, UseKeychain,
//  IdentityFile and friends apply exactly as they do in a terminal; Lincoln
//  only pins the options a managed tunnel needs.
//

import Foundation

public struct SSHCommandBuilder {
    public struct Environment: Equatable {
        public var sshExecutable: String
        public var serverAliveInterval: Int
        public var serverAliveCountMax: Int

        public init(sshExecutable: String = "/usr/bin/ssh", serverAliveInterval: Int = 30, serverAliveCountMax: Int = 3) {
            self.sshExecutable = sshExecutable
            self.serverAliveInterval = serverAliveInterval
            self.serverAliveCountMax = serverAliveCountMax
        }
    }

    public static let sentinelPrefix = "LINCOLN_READY_"

    /// Printed by ssh's LocalCommand once authentication and forwarding
    /// succeeded; also what makes a Lincoln-owned ssh recognizable in `ps`.
    public static func readySentinel(for tunnelID: UUID) -> String {
        sentinelPrefix + tunnelID.uuidString
    }

    /// Arguments for ssh (executable excluded).
    /// - Parameter controlPath: the resolved ControlPath to own when
    ///   `tunnel.shareControlMaster` is set; nil disables multiplexing.
    public static func arguments(for tunnel: Tunnel, controlPath: String? = nil, environment: Environment = Environment()) -> [String] {
        var args: [String] = ["-N"]

        func option(_ key: String, _ value: String) {
            args.append("-o")
            args.append("\(key)=\(value)")
        }

        // Forwards are exactly what Lincoln shows, even if the alias already
        // carries DynamicForward/LocalForward lines in ssh_config.
        option("ClearAllForwardings", "yes")
        option("ExitOnForwardFailure", "yes")
        // Keys only. Keyboard-interactive stays enabled for Duo.
        option("PasswordAuthentication", "no")
        option("NumberOfPasswordPrompts", "0")
        option("ServerAliveInterval", String(environment.serverAliveInterval))
        option("ServerAliveCountMax", String(environment.serverAliveCountMax))
        option("PermitLocalCommand", "yes")
        option("LocalCommand", "echo \(readySentinel(for: tunnel.id))")

        if tunnel.shareControlMaster, let controlPath = controlPath, !controlPath.isEmpty, controlPath != "none" {
            option("ControlMaster", "yes")
            option("ControlPath", controlPath)
            option("ControlPersist", "no")
        } else {
            option("ControlMaster", "no")
            option("ControlPath", "none")
        }

        if let port = tunnel.port {
            args.append("-p")
            args.append(String(port))
        }
        if let user = tunnel.user?.trimmingCharacters(in: .whitespaces), !user.isEmpty {
            args.append("-l")
            args.append(user)
        }
        if let identity = tunnel.identityFile?.trimmingCharacters(in: .whitespaces), !identity.isEmpty {
            args.append("-i")
            args.append(identity)
            option("IdentitiesOnly", "yes")
        }
        for forward in tunnel.forwards where forward.isValid {
            args.append(contentsOf: forward.sshArguments)
        }
        for extra in tunnel.extraOptions {
            let key = extra.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            option(key, extra.value.trimmingCharacters(in: .whitespaces))
        }
        args.append("--")
        args.append(tunnel.trimmedHost)
        return args
    }

    /// Shell-quoted command line for logs and the console header.
    public static func commandLine(for tunnel: Tunnel, controlPath: String? = nil, environment: Environment = Environment()) -> String {
        ([environment.sshExecutable] + arguments(for: tunnel, controlPath: controlPath, environment: environment))
            .map(shellQuoted)
            .joined(separator: " ")
    }

    /// An equivalent ssh_config block the user can paste into their own
    /// config by hand. Lincoln never writes it for them.
    public static func sshConfigSnippet(for tunnel: Tunnel) -> String {
        var lines: [String] = ["Host lincoln-\(slug(tunnel.displayName))"]
        lines.append("    HostName \(tunnel.trimmedHost)")
        if let user = tunnel.user, !user.isEmpty { lines.append("    User \(user)") }
        if let port = tunnel.port { lines.append("    Port \(port)") }
        if let identity = tunnel.identityFile, !identity.isEmpty {
            lines.append("    IdentityFile \(identity)")
            lines.append("    IdentitiesOnly yes")
        }
        for forward in tunnel.forwards where forward.isValid {
            lines.append("    \(forward.configLine)")
        }
        lines.append("    SessionType none")
        lines.append("    ExitOnForwardFailure yes")
        lines.append("    PasswordAuthentication no")
        for extra in tunnel.extraOptions where !extra.key.isEmpty {
            lines.append("    \(extra.key) \(extra.value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func shellQuoted(_ argument: String) -> String {
        let safe = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@%,+".contains($0) }
        if !argument.isEmpty && safe { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "tunnel" : trimmed
    }
}
