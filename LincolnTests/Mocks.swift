//
//  Mocks.swift
//  LincolnTests
//
//  Scriptable stand-ins for Terminal.app, the control socket and ssh -G.
//

import Foundation
import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class MockTerminalLauncher: TerminalLaunching {
    struct Launch: Equatable {
        var script: String
        var name: String
    }
    private(set) var launches: [Launch] = []
    var launchError: Error?
    /// Optional hook run for every launch (e.g. to simulate ssh writing the status file).
    var onLaunch: ((Launch) -> Void)?

    @discardableResult
    func launch(script: String, name: String) throws -> URL {
        if let error = launchError { throw error }
        let launch = Launch(script: script, name: name)
        launches.append(launch)
        onLaunch?(launch)
        return URL(fileURLWithPath: "/tmp/\(name).command")
    }

    var last: Launch? { launches.last }
}

@MainActor
final class MockHeadlessLauncher: HeadlessMasterLaunching {
    private(set) var launches: [[String]] = []
    private(set) var environments: [[String: String]] = []
    private(set) var timeouts: [TimeInterval] = []
    /// Result returned to the supervisor; default is a silent success.
    var result = SSHCommandResult(standardOutput: "", standardError: "", exitCode: 0)
    /// Output chunks emitted (via onOutput) before returning.
    var outputToEmit: [String] = []
    /// Runs while ssh is "in progress" — e.g. to relay a prompt — before the result is returned.
    var whileRunning: (() async -> Void)?
    /// Simulate the master appearing on this socket path when the launch succeeds.
    var socket: MockControlSocket?
    var socketPath: String?

    func launchMaster(arguments: [String], environmentOverrides: [String: String], timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)?) async -> SSHCommandResult {
        launches.append(arguments)
        environments.append(environmentOverrides)
        timeouts.append(timeout)
        for chunk in outputToEmit { onOutput?(chunk) }
        await Task.yield()
        if let whileRunning = whileRunning { await whileRunning() }
        if result.exitCode == 0, let socket = socket, let path = socketPath {
            socket.running[path] = 9001
        }
        return result
    }

    static let duoDenied = SSHCommandResult(standardOutput: "", standardError: "alice@tigressgateway.princeton.edu: Permission denied (keyboard-interactive).\n", exitCode: 255)
    static let refused = SSHCommandResult(standardOutput: "", standardError: "ssh: connect to host tg port 22: Connection refused\n", exitCode: 255)
}

@MainActor
final class MockControlSocket: ControlSocketChecking {
    /// Socket paths currently "running", with their pid.
    var running: [String: Int32] = [:]
    private(set) var checks: [String] = []
    private(set) var exits: [String] = []
    var exitSucceeds = true

    func check(_ tunnel: Tunnel, controlPath: String) async -> ControlSocketStatus {
        checks.append(controlPath)
        if let pid = running[controlPath] {
            return ControlSocketStatus(isRunning: true, pid: pid, message: "Master running (pid=\(pid))")
        }
        return ControlSocketStatus(isRunning: false, pid: nil, message: "Control socket connect(\(controlPath)): No such file or directory")
    }

    func requestExit(_ tunnel: Tunnel, controlPath: String) async -> Bool {
        exits.append(controlPath)
        guard exitSucceeds, running[controlPath] != nil else { return false }
        running.removeValue(forKey: controlPath)
        return true
    }
}

@MainActor
final class MockSSHEnvironment: SSHEnvironmentProviding {
    var builderEnvironment = SSHCommandBuilder.Environment(sshExecutable: "/usr/bin/ssh")
    /// nil simulates `ssh -G` failing.
    var resolved: ResolvedControlPath? = ResolvedControlPath(
        path: "/tmp/lincoln-tests/sockets/socket-alice@tigressgateway.princeton.edu:22",
        isFromConfig: true,
        destination: SSHDestination(user: "alice", hostName: "tigressgateway.princeton.edu", port: 22, configuredControlPath: "/tmp/lincoln-tests/sockets/socket-alice@tigressgateway.princeton.edu:22")
    )
    private(set) var resolveCalls = 0
    private(set) var preparedDirectories: [String] = []
    var prepareError: Error?

    func resolveControlPath(for tunnel: Tunnel) async -> ResolvedControlPath? {
        resolveCalls += 1
        return resolved
    }

    func prepareControlPathDirectory(_ controlPath: String) throws {
        if let error = prepareError { throw error }
        preparedDirectories.append(controlPath)
    }
}

@MainActor
final class MockNotifier: Notifying {
    private(set) var posted: [(identifier: String, title: String, body: String)] = []
    private(set) var cleared: [String] = []

    func post(identifier: String, title: String, body: String) {
        posted.append((identifier, title, body))
    }

    func clear(identifier: String) {
        cleared.append(identifier)
    }
}

struct TestFixtures {
    static func tunnel(id: UUID = UUID(), name: String = "Gateway", host: String = "tg", autoConnect: Bool = false) -> Tunnel {
        Tunnel(id: id, name: name, host: host, forwards: [.dynamic(port: 1080)], autoConnect: autoConnect)
    }

    static func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lincoln-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    static func isolatedDefaults() -> UserDefaults {
        let name = "io.binoio.LincolnTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

struct FakeLoginItem: LoginItemControlling {
    var enabled = false
    var isEnabled: Bool { enabled }
    func setEnabled(_ enabled: Bool) throws {}
}

extension XCTestCase {
    /// Lets queued main-actor tasks (launch, exit requests) run.
    @MainActor
    func drainMainQueue(iterations: Int = 5) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
