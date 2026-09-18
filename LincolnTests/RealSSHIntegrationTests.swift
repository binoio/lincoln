import XCTest
import LincolnCore
@testable import Lincoln

/// End to end through the real pieces: generated .command script → /bin/zsh →
/// /usr/bin/ssh (control master) → status file → supervisor. A refused local
/// port keeps it off the network; the script runs headless instead of in
/// Terminal.app.
@MainActor
final class RealSSHIntegrationTests: XCTestCase {
    /// Runs the launch script with zsh instead of opening Terminal.
    private final class HeadlessScriptRunner: TerminalLaunching {
        private(set) var scripts: [String] = []
        func launch(script: String, name: String) throws -> URL {
            scripts.append(script)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("lincoln-\(UUID().uuidString).command")
            try script.write(to: url, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return url
        }
    }

    func testRefusedConnectionFailsViaStatusFile() async throws {
        let settings = SettingsManager(defaults: TestFixtures.isolatedDefaults(), loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        // A short fake home keeps the fallback socket path within the 104-byte
        // limit and keeps the test out of the real ~/.ssh.
        let home = URL(fileURLWithPath: "/tmp/lincoln-it-\(UUID().uuidString.prefix(8))")
        let environment = SSHEnvironment(settings: settings, homeDirectory: home)
        let stateDirectory = home.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: home) }
        let tunnel = Tunnel(
            name: "refused",
            host: "127.0.0.1",
            port: 1,
            forwards: [.dynamic(port: 18081)],
            extraOptions: [SSHOption(key: "ConnectTimeout", value: "3"), SSHOption(key: "StrictHostKeyChecking", value: "no")]
        )
        let runner = HeadlessScriptRunner()
        let supervisor = TunnelSupervisor(
            tunnel: tunnel,
            launcher: runner,
            socket: ControlSocketClient(environment: environment),
            environment: environment,
            stateDirectory: stateDirectory
        )
        supervisor.connectSilentlyFirst = { false }
        supervisor.start()
        // ssh -G runs before the script is written; give it a moment.
        for _ in 0..<40 where runner.scripts.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(supervisor.state.isConnecting)
        XCTAssertEqual(runner.scripts.count, 1)
        XCTAssertNotNil(supervisor.controlPath, "ssh -G resolved a control path")

        // Poll until the script has recorded ssh's exit status.
        for _ in 0..<40 {
            await supervisor.poll()
            if case .failed = supervisor.state { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard case .failed(let reason) = supervisor.state else {
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)) ?? []
            return XCTFail("expected failed, got \(supervisor.state); state dir: \(listing); script:\n\(runner.scripts[0])")
        }
        XCTAssertEqual(reason, "ssh exited with status 255")
        XCTAssertFalse(FileManager.default.fileExists(atPath: supervisor.statusFileURL.path))
        XCTAssertTrue(supervisor.controlPath!.path.hasPrefix(home.path + "/.ssh/sockets/lincoln-"), supervisor.controlPath!.path)
        let sockets = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".ssh/sockets").path)
        XCTAssertEqual((sockets[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
    }
}

/// The silent path against real ssh: Lincoln runs `ssh -M -N -f` itself, gets
/// ssh's own error back, and never touches Terminal.
@MainActor
final class RealSilentLaunchTests: XCTestCase {
    func testRefusedConnectionFailsSilentlyWithSSHMessage() async throws {
        let settings = SettingsManager(defaults: TestFixtures.isolatedDefaults(), loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        let home = URL(fileURLWithPath: "/tmp/lincoln-sl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = SSHEnvironment(settings: settings, homeDirectory: home)
        let tunnel = Tunnel(
            name: "refused",
            host: "127.0.0.1",
            port: 1,
            forwards: [.dynamic(port: 18082)],
            extraOptions: [SSHOption(key: "ConnectTimeout", value: "3")]
        )
        let terminal = MockTerminalLauncher()
        let supervisor = TunnelSupervisor(
            tunnel: tunnel,
            launcher: terminal,
            headless: environment,
            socket: ControlSocketClient(environment: environment),
            environment: environment,
            stateDirectory: home.appendingPathComponent("state")
        )
        supervisor.start()
        for _ in 0..<40 {
            if case .failed = supervisor.state { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertEqual(supervisor.state, .failed(reason: "ssh: connect to host 127.0.0.1 port 1: Connection refused"))
        XCTAssertEqual(supervisor.lastLaunchMode, .silent)
        XCTAssertTrue(terminal.launches.isEmpty)
    }

    func testWatchdogTerminatesHungProcess() async {
        let result = await Task.detached {
            SSHEnvironment.runSynchronously(executable: "/bin/sleep", arguments: ["30"], environment: [:], timeout: 0.3)
        }.value
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.exitCode, 0)
    }
}
