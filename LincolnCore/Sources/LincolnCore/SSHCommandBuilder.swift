//
//  SSHCommandBuilder.swift
//  LincolnCore
//
//  Turns a Tunnel into deterministic ssh argument vectors. The user's
//  ~/.ssh/config is still consulted by ssh (no -F), so ProxyJump, UseKeychain,
//  IdentityFile and friends apply exactly as they do in a terminal; Lincoln
//  only pins the options a managed ControlMaster needs.
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

    /// Arguments that identify the destination the same way for every ssh
    /// invocation (master, check, exit, interactive), so ControlPath tokens
    /// and Match blocks resolve identically.
    public static func destinationArguments(for tunnel: Tunnel) -> [String] {
        var args: [String] = []
        if let port = tunnel.port {
            args += ["-p", String(port)]
        }
        if let user = tunnel.user?.trimmingCharacters(in: .whitespaces), !user.isEmpty {
            args += ["-l", user]
        }
        args += ["--", tunnel.trimmedHost]
        return args
    }

    /// `ssh -G` arguments used to resolve the effective configuration.
    public static func configDumpArguments(for tunnel: Tunnel) -> [String] {
        ["-G"] + destinationArguments(for: tunnel)
    }

    /// The command that runs in Terminal.app: a backgrounding ControlMaster
    /// carrying the tunnel's forwards. Duo/passphrase prompts happen there;
    /// after authentication ssh forks away and the window can be closed.
    ///
    /// - Parameter configuredForwards: forwards the user's ssh config already
    ///   defines for this host (from `ssh -G`). They stay active, as they
    ///   would for a terminal `ssh <host>`, and are not added a second time —
    ///   ssh would fail to bind the duplicate and, with ExitOnForwardFailure,
    ///   exit. (ClearAllForwardings is not an option: it also clears the
    ///   forwards given on the command line.)
    public static func masterArguments(for tunnel: Tunnel, controlPath: String, configuredForwards: [Forward] = [], environment: Environment = Environment()) -> [String] {
        var args: [String] = ["-M", "-N", "-f"]

        func option(_ key: String, _ value: String) {
            args.append("-o")
            args.append("\(key)=\(value)")
        }

        option("ControlPath", controlPath)
        option("ExitOnForwardFailure", "yes")
        // Keys only. Keyboard-interactive stays enabled for Duo.
        option("PasswordAuthentication", "no")
        option("NumberOfPasswordPrompts", "0")
        option("ServerAliveInterval", String(environment.serverAliveInterval))
        option("ServerAliveCountMax", String(environment.serverAliveCountMax))

        if let identity = tunnel.identityFile?.trimmingCharacters(in: .whitespaces), !identity.isEmpty {
            args.append("-i")
            args.append(identity)
            option("IdentitiesOnly", "yes")
        }
        for forward in tunnel.forwards where forward.isValid && !configuredForwards.contains(where: { $0.listensLike(forward) }) {
            args.append(contentsOf: forward.sshArguments)
        }
        for extra in tunnel.extraOptions {
            let key = extra.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            option(key, extra.value.trimmingCharacters(in: .whitespaces))
        }
        args.append(contentsOf: destinationArguments(for: tunnel))
        return args
    }

    /// The same master, but started by Lincoln itself with no terminal:
    /// only key authentication is attempted and nothing may prompt. Succeeds
    /// silently when the agent/keychain holds the key; otherwise fails fast
    /// (before any Duo push) so the Terminal flow can take over.
    public static func headlessMasterArguments(for tunnel: Tunnel, controlPath: String, configuredForwards: [Forward] = [], environment: Environment = Environment()) -> [String] {
        var args = masterArguments(for: tunnel, controlPath: controlPath, configuredForwards: configuredForwards, environment: environment)
        // Insert right after ControlPath so these precede any user extras
        // (ssh honors the first occurrence of an option).
        let insertAt = 5
        args.insert(contentsOf: [
            "-o", "BatchMode=yes",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "PreferredAuthentications=publickey"
        ], at: insertAt)
        return args
    }

    /// Whether a failed headless attempt should be retried in Terminal.app
    /// because ssh needed a person: another authentication factor, a key
    /// passphrase, or a host-key confirmation.
    public static func requiresInteraction(stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("permission denied")
            || lowered.contains("host key verification failed")
            || lowered.contains("keyboard-interactive")
            || lowered.contains("passphrase")
            || lowered.contains("too many authentication failures")
    }

    /// Last meaningful line of ssh's stderr, for failure reasons.
    public static func failureReason(stderr: String, status: Int32) -> String {
        let line = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Pseudo-terminal") && !$0.hasPrefix("Warning: Permanently added") }
            .last
        return line ?? "ssh exited with status \(status)"
    }

    /// `ssh -O check`: exit 0 and "Master running (pid=N)" when the master is up.
    public static func checkArguments(for tunnel: Tunnel, controlPath: String) -> [String] {
        ["-O", "check", "-o", "ControlPath=\(controlPath)"] + destinationArguments(for: tunnel)
    }

    /// `ssh -O exit`: asks the master to close all sessions and quit.
    public static func exitArguments(for tunnel: Tunnel, controlPath: String) -> [String] {
        ["-O", "exit", "-o", "ControlPath=\(controlPath)"] + destinationArguments(for: tunnel)
    }

    /// An interactive session that reuses the master (no second Duo prompt).
    public static func sessionArguments(for tunnel: Tunnel, controlPath: String) -> [String] {
        ["-o", "ControlPath=\(controlPath)"] + destinationArguments(for: tunnel)
    }

    /// Parses the pid out of `ssh -O check` output ("Master running (pid=123)").
    public static func masterPID(fromCheckOutput output: String) -> Int32? {
        guard let range = output.range(of: "pid=") else { return nil }
        let digits = output[range.upperBound...].prefix { $0.isNumber }
        return Int32(digits)
    }

    /// Shell-quoted command line for display and for the Terminal script.
    public static func commandLine(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuoted).joined(separator: " ")
    }

    /// The `.command` script Terminal.app runs. It records ssh's exit status
    /// in `statusFile` so Lincoln learns about failures without owning a tty.
    public static func terminalScript(for tunnel: Tunnel, controlPath: String, statusFile: String, configuredForwards: [Forward] = [], environment: Environment = Environment()) -> String {
        let command = commandLine(executable: environment.sshExecutable, arguments: masterArguments(for: tunnel, controlPath: controlPath, configuredForwards: configuredForwards, environment: environment))
        let name = shellQuoted(tunnel.displayName)
        let destination = shellQuoted(tunnel.destinationSummary)
        let status = shellQuoted(statusFile)
        return """
        #!/bin/zsh
        # Generated by Lincoln. Runs the ControlMaster for one tunnel; safe to close
        # this window once ssh has backgrounded itself.
        printf '\\e[1mLincoln: connecting %s (%s)\\e[0m\\n' \(name) \(destination)
        \(command)
        ssh_status=$?
        printf '%s\\n' "$ssh_status" > \(status)
        if [ "$ssh_status" -eq 0 ]; then
            printf '\\e[32mLincoln: tunnel is up.\\e[0m The control master keeps running; you can close this window.\\n'
        else
            printf '\\e[31mLincoln: ssh exited with status %s.\\e[0m\\n' "$ssh_status"
        fi

        """
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
