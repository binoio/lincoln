//
//  SSHConfigParser.swift
//  LincolnCore
//
//  Read-only parser for ~/.ssh/config. Lincoln uses it to offer host aliases
//  and to import existing DynamicForward/LocalForward/RemoteForward lines as
//  tunnel templates. It never writes ssh configuration.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct SSHConfigOption: Hashable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct SSHConfigHost: Hashable, Identifiable {
    public var patterns: [String]
    public var options: [SSHConfigOption]
    /// Path of the file this block came from (config or an Include).
    public var sourcePath: String
    public var isMatchBlock: Bool

    public var id: String { "\(sourcePath):\(patterns.joined(separator: " "))" }

    public init(patterns: [String], options: [SSHConfigOption] = [], sourcePath: String = "", isMatchBlock: Bool = false) {
        self.patterns = patterns
        self.options = options
        self.sourcePath = sourcePath
        self.isMatchBlock = isMatchBlock
    }

    /// The first alias without wildcard/negation characters, if any.
    public var alias: String? {
        guard !isMatchBlock else { return nil }
        return patterns.first { SSHConfigHost.isConcrete($0) }
    }

    public var isConcrete: Bool { !isMatchBlock && alias != nil }

    public static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains(where: { "*?!".contains($0) })
    }

    public func value(for key: String) -> String? {
        options.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public func values(for key: String) -> [String] {
        options.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map { $0.value }
    }

    public var hostName: String? { value(for: "HostName") }
    public var user: String? { value(for: "User") }
    public var port: Int? { value(for: "Port").flatMap(Int.init) }
    public var identityFiles: [String] { values(for: "IdentityFile") }
    public var proxyJump: String? { value(for: "ProxyJump") }

    public var forwards: [Forward] {
        options.compactMap { option in
            let kind: Forward.Kind
            switch option.key.lowercased() {
            case "dynamicforward": kind = .dynamic
            case "localforward": kind = .local
            case "remoteforward": kind = .remote
            default: return nil
            }
            return Forward.parse(kind: kind, configValue: option.value)
        }
    }
}

public struct SSHConfigParser {
    public var homeDirectory: URL
    public var fileManager: FileManager
    /// Guard against Include cycles.
    public var maximumIncludeDepth = 16

    public init(homeDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    public var sshDirectory: URL { homeDirectory.appendingPathComponent(".ssh", isDirectory: true) }
    public var defaultConfigURL: URL { sshDirectory.appendingPathComponent("config") }

    /// Parses the user's config, following Include directives. Missing include
    /// targets are skipped, as ssh itself does.
    public func parse(fileURL: URL? = nil) throws -> [SSHConfigHost] {
        let url = fileURL ?? defaultConfigURL
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var visited = Set<String>()
        return parse(text: text, sourcePath: url.path, depth: 0, visited: &visited)
    }

    /// Parses config text without touching the file system (Includes are ignored).
    public static func parse(text: String, sourcePath: String = "<memory>") -> [SSHConfigHost] {
        var parser = SSHConfigParser(homeDirectory: URL(fileURLWithPath: "/nonexistent"))
        parser.maximumIncludeDepth = 0
        var visited = Set<String>()
        return parser.parse(text: text, sourcePath: sourcePath, depth: 0, visited: &visited)
    }

    private func parse(text: String, sourcePath: String, depth: Int, visited: inout Set<String>) -> [SSHConfigHost] {
        visited.insert(sourcePath)
        var hosts: [SSHConfigHost] = []
        var current: SSHConfigHost?
        // Hosts pulled in by an Include that appears inside a Host block are
        // emitted after that block so file order is preserved.
        var deferred: [SSHConfigHost] = []

        func flush() {
            if let block = current { hosts.append(block) }
            current = nil
            hosts.append(contentsOf: deferred)
            deferred.removeAll()
        }

        for rawLine in text.components(separatedBy: .newlines) {
            guard let (key, value) = SSHConfigParser.splitKeyValue(rawLine) else { continue }
            switch key.lowercased() {
            case "host":
                flush()
                current = SSHConfigHost(patterns: SSHConfigParser.splitWords(value), sourcePath: sourcePath)
            case "match":
                flush()
                current = SSHConfigHost(patterns: [value], sourcePath: sourcePath, isMatchBlock: true)
            case "include":
                guard depth < maximumIncludeDepth else { continue }
                for path in resolveIncludes(value) where !visited.contains(path) {
                    guard let included = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                    // Included blocks are independent of the enclosing Host block
                    // for Lincoln's purposes: we only harvest Host definitions.
                    let nested = parse(text: included, sourcePath: path, depth: depth + 1, visited: &visited)
                    if current == nil {
                        hosts.append(contentsOf: nested)
                    } else {
                        deferred.append(contentsOf: nested)
                    }
                }
            default:
                current?.options.append(SSHConfigOption(key: key, value: SSHConfigParser.unquoted(value)))
            }
        }
        flush()
        return hosts
    }

    /// Splits "Key value", "Key=value" and "Key = value" forms; nil for blank
    /// and comment lines.
    static func splitKeyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (trimmed, "")
        }
        let key = String(trimmed[..<separator])
        var rest = trimmed[separator...]
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" {
            rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        }
        let value = String(rest).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// Splits on whitespace while keeping "quoted words" together.
    static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        var sawQuote = false
        for character in text {
            switch character {
            case "\"":
                inQuotes.toggle()
                sawQuote = true
            case " ", "\t":
                if inQuotes {
                    current.append(character)
                } else if !current.isEmpty || sawQuote {
                    words.append(current)
                    current = ""
                    sawQuote = false
                }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty || sawQuote { words.append(current) }
        return words
    }

    private static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Expands an Include value (one or more space-separated paths, ~ and
    /// globs allowed; relative paths are relative to ~/.ssh) into existing files.
    func resolveIncludes(_ value: String) -> [String] {
        var results: [String] = []
        for token in SSHConfigParser.splitWords(value) {
            var path = token
            if path.hasPrefix("~/") {
                path = homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
            } else if path == "~" {
                path = homeDirectory.path
            } else if !path.hasPrefix("/") {
                path = sshDirectory.appendingPathComponent(path).path
            }
            results.append(contentsOf: expandGlob(path))
        }
        return results
    }

    private func expandGlob(_ path: String) -> [String] {
        guard path.contains(where: { "*?[".contains($0) }) else {
            return fileManager.fileExists(atPath: path) ? [path] : []
        }
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().path
        let pattern = url.lastPathComponent
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            .filter { fnmatch(pattern, $0, 0) == 0 }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
    }
}
