//
//  TerminalLauncher.swift
//  Lincoln
//
//  Terminal.app is Lincoln's console: ssh runs there with the user's login
//  shell, keys and agent, and Duo/passphrase prompts are answered there.
//  Lincoln hands Terminal a generated `.command` script, which needs no
//  Apple Events permission.
//

import Foundation
import AppKit
import LincolnCore

@MainActor
protocol TerminalLaunching {
    /// Writes `script` to a `.command` file named after `name` and opens it in
    /// Terminal.app. Returns the script's URL.
    @discardableResult
    func launch(script: String, name: String) throws -> URL
}

enum TerminalLauncherError: LocalizedError {
    case terminalNotFound

    var errorDescription: String? {
        switch self {
        case .terminalNotFound: return "Terminal.app was not found."
        }
    }
}

@MainActor
struct TerminalAppLauncher: TerminalLaunching {
    static let terminalBundleIdentifier = "com.apple.Terminal"

    let scriptsDirectory: URL
    let fileManager: FileManager

    init(scriptsDirectory: URL = TunnelStore.defaultDirectory().appendingPathComponent("commands", isDirectory: true), fileManager: FileManager = .default) {
        self.scriptsDirectory = scriptsDirectory
        self.fileManager = fileManager
    }

    @discardableResult
    func launch(script: String, name: String) throws -> URL {
        let url = try write(script: script, name: name)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalAppLauncher.terminalBundleIdentifier) else {
            throw TerminalLauncherError.terminalNotFound
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration) { _, error in
            if let error = error {
                LogStore.log(level: .error, category: "Terminal", message: "Terminal.app failed to open \(url.lastPathComponent)", details: error.localizedDescription)
            }
        }
        LogStore.log(level: .info, category: "Terminal", message: "Opened \(url.lastPathComponent) in Terminal.app")
        return url
    }

    /// Writes the script with mode 0700 into the scripts directory.
    func write(script: String, name: String) throws -> URL {
        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = scriptsDirectory.appendingPathComponent("\(TerminalAppLauncher.fileName(for: name)).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func fileName(for name: String) -> String {
        let allowed = name.map { character -> Character in
            (character.isLetter || character.isNumber || character == "-" || character == "_") ? character : "-"
        }
        let trimmed = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "tunnel" : trimmed
    }
}
