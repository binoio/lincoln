//
//  MockTunnelProcess.swift
//  LincolnTests
//
//  Scriptable stand-ins for the pty process, ssh environment and notifier.
//

import Foundation
import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class MockTunnelProcess: TunnelProcess {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    var processIdentifier: pid_t = 4242
    private(set) var isRunning = false
    private(set) var started = false
    private(set) var writes: [String] = []
    private(set) var terminateCount = 0
    var startError: Error?
    /// Called on terminate(); defaults to exiting with 143 like a SIGTERM'd ssh.
    var onTerminate: ((MockTunnelProcess) -> Void)?

    let executable: String
    let arguments: [String]
    let environment: [String: String]

    init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    func start() throws {
        if let error = startError { throw error }
        started = true
        isRunning = true
    }

    func write(_ text: String) {
        writes.append(text)
    }

    func terminate() {
        terminateCount += 1
        if let onTerminate = onTerminate {
            onTerminate(self)
        } else {
            exit(status: 143)
        }
    }

    // Test drivers
    func emit(_ text: String) {
        onOutput?(Data(text.utf8))
    }

    func exit(status: Int32) {
        guard isRunning else { return }
        isRunning = false
        onExit?(status)
    }
}

@MainActor
final class MockTunnelProcessFactory: TunnelProcessFactory {
    private(set) var processes: [MockTunnelProcess] = []
    var configure: ((MockTunnelProcess) -> Void)?

    func makeProcess(executable: String, arguments: [String], environment: [String: String]) -> TunnelProcess {
        let process = MockTunnelProcess(executable: executable, arguments: arguments, environment: environment)
        configure?(process)
        processes.append(process)
        return process
    }

    var last: MockTunnelProcess? { processes.last }
}

@MainActor
final class MockSSHEnvironment: SSHEnvironmentProviding {
    var builderEnvironment = SSHCommandBuilder.Environment(sshExecutable: "/usr/bin/ssh")
    var environmentToReturn: [String: String] = ["PATH": "/usr/bin", "TERM": "dumb"]
    var controlPathToReturn: String?
    private(set) var resolveCalls = 0
    private(set) var preparedDirectories: [String] = []
    var prepareError: Error?

    func processEnvironment() -> [String: String] { environmentToReturn }

    func resolveControlPath(for tunnel: Tunnel) async -> String? {
        resolveCalls += 1
        return controlPathToReturn
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

/// Collects scheduled backoff/prompt timers so tests fire them by hand.
@MainActor
final class ManualScheduler {
    struct Entry {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
    }
    private(set) var entries: [Entry] = []

    var scheduler: BackoffScheduler {
        { [unowned self] delay, action in
            let index = self.entries.count
            self.entries.append(Entry(delay: delay, action: action))
            return { self.entries[index].cancelled = true }
        }
    }

    var pending: [Entry] { entries.filter { !$0.cancelled } }

    /// Fires every pending timer (once), in order.
    func fireAll() {
        let toFire = entries.enumerated().filter { !$0.element.cancelled }
        for (index, entry) in toFire {
            entries[index].cancelled = true
            entry.action()
        }
    }

    func fire(where predicate: (TimeInterval) -> Bool) {
        let toFire = entries.enumerated().filter { !$0.element.cancelled && predicate($0.element.delay) }
        for (index, entry) in toFire {
            entries[index].cancelled = true
            entry.action()
        }
    }
}

struct TestFixtures {
    static func tunnel(
        id: UUID = UUID(),
        name: String = "Gateway",
        host: String = "tg",
        autoReconnect: Bool = true,
        shareControlMaster: Bool = false
    ) -> Tunnel {
        Tunnel(id: id, name: name, host: host, forwards: [.dynamic(port: 1080)], shareControlMaster: shareControlMaster, autoReconnect: autoReconnect)
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
    /// Lets queued main-actor tasks (mock callbacks, async spawn) run.
    @MainActor
    func drainMainQueue(iterations: Int = 5) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
