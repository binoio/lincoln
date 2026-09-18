//
//  Tunnel.swift
//  LincolnCore
//
//  The persisted description of one SSH tunnel. Lincoln never edits
//  ~/.ssh/config; a Tunnel references a host alias (or hostname) and layers
//  its own forwards and options on top via ssh command-line arguments. At
//  run time a tunnel is an ssh ControlMaster: its control socket is what
//  Lincoln starts (in Terminal.app), checks and stops.
//

import Foundation

/// One port forwarding rule, mirroring ssh's -D / -L / -R.
public struct Forward: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case dynamic
        case local
        case remote

        public var id: String { rawValue }

        public var flag: String {
            switch self {
            case .dynamic: return "-D"
            case .local: return "-L"
            case .remote: return "-R"
            }
        }

        public var configKeyword: String {
            switch self {
            case .dynamic: return "DynamicForward"
            case .local: return "LocalForward"
            case .remote: return "RemoteForward"
            }
        }

        public var displayName: String {
            switch self {
            case .dynamic: return "SOCKS (dynamic)"
            case .local: return "Local"
            case .remote: return "Remote"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Address to bind the listening side to. Empty means ssh's default
    /// (loopback, or GatewayPorts for remote forwards).
    public var bindAddress: String
    public var listenPort: Int
    /// Destination host for local/remote forwards. Ignored for dynamic.
    public var targetHost: String
    /// Destination port for local/remote forwards. Ignored for dynamic.
    public var targetPort: Int

    public init(
        id: UUID = UUID(),
        kind: Kind,
        bindAddress: String = "",
        listenPort: Int,
        targetHost: String = "",
        targetPort: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public static func dynamic(port: Int, bindAddress: String = "") -> Forward {
        Forward(kind: .dynamic, bindAddress: bindAddress, listenPort: port)
    }

    public static func local(port: Int, host: String, hostPort: Int, bindAddress: String = "") -> Forward {
        Forward(kind: .local, bindAddress: bindAddress, listenPort: port, targetHost: host, targetPort: hostPort)
    }

    public static func remote(port: Int, host: String, hostPort: Int, bindAddress: String = "") -> Forward {
        Forward(kind: .remote, bindAddress: bindAddress, listenPort: port, targetHost: host, targetPort: hostPort)
    }

    /// The value ssh expects after -D/-L/-R (and after the ssh_config keyword).
    public var specification: String {
        let bind = bindAddress.isEmpty ? "" : "\(Forward.bracketed(bindAddress)):"
        switch kind {
        case .dynamic:
            return "\(bind)\(listenPort)"
        case .local, .remote:
            return "\(bind)\(listenPort):\(Forward.bracketed(targetHost)):\(targetPort)"
        }
    }

    /// Command-line arguments for this forward, e.g. ["-L", "10445:files.princeton.edu:445"].
    public var sshArguments: [String] {
        [kind.flag, specification]
    }

    /// The ssh_config line equivalent, e.g. "LocalForward 10445 files.princeton.edu:445".
    public var configLine: String {
        let bind = bindAddress.isEmpty ? "" : "\(Forward.bracketed(bindAddress)):"
        switch kind {
        case .dynamic:
            return "\(kind.configKeyword) \(bind)\(listenPort)"
        case .local, .remote:
            return "\(kind.configKeyword) \(bind)\(listenPort) \(Forward.bracketed(targetHost)):\(targetPort)"
        }
    }

    public var summary: String {
        switch kind {
        case .dynamic:
            return "SOCKS on \(bindAddress.isEmpty ? "localhost" : bindAddress):\(listenPort)"
        case .local:
            return "\(bindAddress.isEmpty ? "localhost" : bindAddress):\(listenPort) → \(targetHost):\(targetPort)"
        case .remote:
            return "remote \(bindAddress.isEmpty ? "*" : bindAddress):\(listenPort) → \(targetHost):\(targetPort)"
        }
    }

    public var isValid: Bool {
        guard (1...65535).contains(listenPort) else { return false }
        switch kind {
        case .dynamic:
            return true
        case .local, .remote:
            return !targetHost.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(targetPort)
        }
    }

    /// Parses the ssh_config forms (also as `ssh -G` prints them, with
    /// bracketed hosts):
    ///   DynamicForward [bind_address:]port
    ///   LocalForward   [bind_address:]port host:hostport
    ///   RemoteForward  [bind_address:]port host:hostport
    /// Returns nil when the specification is malformed.
    public static func parse(kind: Kind, configValue: String) -> Forward? {
        let parts = configValue.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        switch kind {
        case .dynamic:
            guard parts.count == 1, let (bind, port) = splitBindAndPort(parts[0]) else { return nil }
            return Forward(kind: .dynamic, bindAddress: bind, listenPort: port)
        case .local, .remote:
            guard parts.count == 2,
                  let (bind, port) = splitBindAndPort(parts[0]),
                  let (host, hostPort) = splitHostAndPort(parts[1]) else { return nil }
            return Forward(kind: kind, bindAddress: bind, listenPort: port, targetHost: host, targetPort: hostPort)
        }
    }

    /// Parses one `ssh -G` output line such as "localforward 10445 [files.princeton.edu]:445".
    public static func parse(configDumpLine line: String) -> Forward? {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let kind: Kind
        switch parts[0].lowercased() {
        case "dynamicforward": kind = .dynamic
        case "localforward": kind = .local
        case "remoteforward": kind = .remote
        default: return nil
        }
        return parse(kind: kind, configValue: parts[1])
    }

    /// Same listener (kind, bind address, port), ignoring ids and, for
    /// dynamic forwards, nothing else.
    public func listensLike(_ other: Forward) -> Bool {
        kind == other.kind
            && listenPort == other.listenPort
            && Forward.normalizedBind(bindAddress) == Forward.normalizedBind(other.bindAddress)
    }

    private static func normalizedBind(_ bind: String) -> String {
        let lowered = bind.lowercased()
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1" ? "" : lowered
    }

    /// Parses the command-line form used after -D/-L/-R, e.g. "10445:files.princeton.edu:445".
    public static func parse(kind: Kind, argument: String) -> Forward? {
        switch kind {
        case .dynamic:
            return parse(kind: kind, configValue: argument)
        case .local, .remote:
            // Split off the trailing host:hostport, honoring [v6]:port on the target.
            guard let lastColon = argument.lastIndex(of: ":") else { return nil }
            let portString = String(argument[argument.index(after: lastColon)...])
            let head = String(argument[..<lastColon])
            guard let hostStart = head.lastIndex(of: ":") else { return nil }
            let host = String(head[head.index(after: hostStart)...])
            let listen = String(head[..<hostStart])
            guard let hostPort = Int(portString), let (bind, port) = splitBindAndPort(listen) else { return nil }
            return Forward(kind: kind, bindAddress: bind, listenPort: port, targetHost: unbracketed(host), targetPort: hostPort)
        }
    }

    private static func splitBindAndPort(_ text: String) -> (String, Int)? {
        if let port = Int(text) { return ("", port) }
        guard let lastColon = text.lastIndex(of: ":") else { return nil }
        let bind = unbracketed(String(text[..<lastColon]))
        guard let port = Int(text[text.index(after: lastColon)...]) else { return nil }
        // ssh -G prints "[*]:port" for GatewayPorts-style binds.
        return (bind == "*" ? "*" : bind, port)
    }

    private static func splitHostAndPort(_ text: String) -> (String, Int)? {
        guard let lastColon = text.lastIndex(of: ":") else { return nil }
        let host = unbracketed(String(text[..<lastColon]))
        guard !host.isEmpty, let port = Int(text[text.index(after: lastColon)...]) else { return nil }
        return (host, port)
    }

    private static func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    private static func unbracketed(_ host: String) -> String {
        if host.hasPrefix("["), host.hasSuffix("]") { return String(host.dropFirst().dropLast()) }
        return host
    }
}

/// An extra `-o Key=Value` option applied to a tunnel.
public struct SSHOption: Codable, Hashable, Identifiable {
    public var id: UUID
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }

    public var argument: String { "\(key)=\(value)" }
}

public struct Tunnel: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// An alias from ~/.ssh/config (preferred, so ProxyJump/keys/etc. are
    /// inherited) or a bare hostname.
    public var host: String
    /// nil = inherit from ssh_config.
    public var user: String?
    /// nil = inherit from ssh_config.
    public var port: Int?
    /// Path to a private key. nil = inherit (ssh-agent / IdentityFile in config).
    public var identityFile: String?
    public var forwards: [Forward]
    public var extraOptions: [SSHOption]
    /// Open a Terminal window and connect when Lincoln launches.
    public var autoConnect: Bool
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        forwards: [Forward] = [],
        extraOptions: [SSHOption] = [],
        autoConnect: Bool = false,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.forwards = forwards
        self.extraOptions = extraOptions
        self.autoConnect = autoConnect
        self.notes = notes
    }

    public var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? trimmedHost : trimmed
    }

    /// user@host[:port] as the user would type it.
    public var destinationSummary: String {
        var text = trimmedHost
        if let user = user?.trimmingCharacters(in: .whitespaces), !user.isEmpty {
            text = "\(user)@\(text)"
        }
        if let port = port, port != 22 {
            text += ":\(port)"
        }
        return text
    }

    public var validationErrors: [String] {
        var errors: [String] = []
        if trimmedHost.isEmpty {
            errors.append("Host is required.")
        } else if trimmedHost.contains(where: { $0.isWhitespace }) {
            errors.append("Host must not contain whitespace.")
        }
        if let port = port, !(1...65535).contains(port) {
            errors.append("Port must be between 1 and 65535.")
        }
        if forwards.isEmpty {
            errors.append("Add at least one forward (SOCKS, local or remote).")
        }
        for (index, forward) in forwards.enumerated() where !forward.isValid {
            errors.append("Forward \(index + 1) is incomplete.")
        }
        let listenPorts = forwards.filter { $0.kind != .remote }.map { "\($0.bindAddress):\($0.listenPort)" }
        if Set(listenPorts).count != listenPorts.count {
            errors.append("Two forwards listen on the same local port.")
        }
        for option in extraOptions {
            let key = option.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty || key.contains(where: { $0.isWhitespace || $0 == "=" }) {
                errors.append("Option \"\(option.key)\" has an invalid name.")
            }
        }
        return errors
    }

    public var isValid: Bool { validationErrors.isEmpty }
}

/// The on-disk document. `schemaVersion` lets a future Lincoln migrate a file
/// written by an older one; `desiredUp` records which tunnels the user had
/// running so a relaunch (even a year later) picks up where they left off.
public struct TunnelDocument: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var tunnels: [Tunnel]
    public var desiredUp: [UUID]

    public init(schemaVersion: Int = TunnelDocument.currentSchemaVersion, tunnels: [Tunnel] = [], desiredUp: [UUID] = []) {
        self.schemaVersion = schemaVersion
        self.tunnels = tunnels
        self.desiredUp = desiredUp
    }

    public static let empty = TunnelDocument()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tunnels, desiredUp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        tunnels = try container.decodeIfPresent([Tunnel].self, forKey: .tunnels) ?? []
        desiredUp = try container.decodeIfPresent([UUID].self, forKey: .desiredUp) ?? []
    }

    public func tunnel(withID id: UUID) -> Tunnel? {
        tunnels.first { $0.id == id }
    }

    public mutating func upsert(_ tunnel: Tunnel) {
        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels[index] = tunnel
        } else {
            tunnels.append(tunnel)
        }
    }

    public mutating func remove(id: UUID) {
        tunnels.removeAll { $0.id == id }
        desiredUp.removeAll { $0 == id }
    }

    public mutating func setDesiredUp(_ up: Bool, id: UUID) {
        if up {
            if !desiredUp.contains(id) { desiredUp.append(id) }
        } else {
            desiredUp.removeAll { $0 == id }
        }
    }
}
