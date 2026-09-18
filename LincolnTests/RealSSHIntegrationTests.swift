import XCTest
import LincolnCore
@testable import Lincoln

/// End to end through the real pieces: PTYProcess → /usr/bin/ssh → console →
/// state machine. Uses a refused local port so it never touches the network.
@MainActor
final class RealSSHIntegrationTests: XCTestCase {
    func testRefusedConnectionSurfacesSSHErrorAndFails() async throws {
        let settings = SettingsManager(defaults: TestFixtures.isolatedDefaults(), loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        let environment = SSHEnvironment(settings: settings)
        let tunnel = Tunnel(
            name: "refused",
            host: "127.0.0.1",
            port: 1,
            forwards: [.dynamic(port: 18080)],
            extraOptions: [SSHOption(key: "ConnectTimeout", value: "3"), SSHOption(key: "StrictHostKeyChecking", value: "no")],
            autoReconnect: false
        )
        let supervisor = TunnelSupervisor(tunnel: tunnel, processFactory: PTYProcessFactory(), environment: environment, policy: .immediate)

        let settled = expectation(description: "failed")
        settled.assertForOverFulfill = false
        supervisor.onStateChange = { supervisor in
            if case .failed = supervisor.state { settled.fulfill() }
        }
        supervisor.start()
        await fulfillment(of: [settled], timeout: 15)

        guard case .failed(let reason) = supervisor.state else {
            return XCTFail("expected failed, got \(supervisor.state)")
        }
        XCTAssertTrue(reason.lowercased().contains("refused") || reason.lowercased().contains("connect"), reason)
        XCTAssertTrue(supervisor.console.text.contains("/usr/bin/ssh -N"), "console shows the command line")
        XCTAssertTrue(supervisor.console.text.contains("ssh exited"), supervisor.console.text)
        XCTAssertTrue(supervisor.lastCommandLine.contains("-o PasswordAuthentication=no"))
    }
}
