import XCTest
import LincolnCore
@testable import Lincoln

/// Real `ssh -O check` / `-O exit` against a socket that does not exist.
@MainActor
final class ControlSocketClientTests: XCTestCase {
    private func makeClient() -> ControlSocketClient {
        let settings = SettingsManager(defaults: TestFixtures.isolatedDefaults(), loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        return ControlSocketClient(environment: SSHEnvironment(settings: settings))
    }

    func testMissingSocketIsNotRunning() async {
        let client = makeClient()
        let tunnel = Tunnel(name: "x", host: "127.0.0.1", port: 1, forwards: [.dynamic(port: 1080)])
        // Unix socket paths must stay under 104 bytes.
        let path = "/tmp/lincoln-test-\(UUID().uuidString.prefix(8)).sock"
        let status = await client.check(tunnel, controlPath: path)
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.pid)
        XCTAssertTrue(status.message.lowercased().contains("control socket"), status.message)

        let accepted = await client.requestExit(tunnel, controlPath: path)
        XCTAssertFalse(accepted)
    }
}
