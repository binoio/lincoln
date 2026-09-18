import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class SSHEnvironmentTests: XCTestCase {
    private func makeEnvironment(home: URL? = nil) -> SSHEnvironment {
        let settings = SettingsManager(defaults: TestFixtures.isolatedDefaults(), loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        return SSHEnvironment(settings: settings, homeDirectory: home)
    }

    func testProcessEnvironmentPrependsPathAndStripsAskpass() {
        let env = SSHEnvironment.makeProcessEnvironment(
            base: ["PATH": "/usr/bin:/bin", "SSH_ASKPASS": "/x", "DISPLAY": ":0", "LANG": "C"],
            extraPath: "~/.homebrew/bin:/opt/homebrew/bin:/usr/bin",
            home: "/Users/alice"
        )
        XCTAssertEqual(env["PATH"], "/Users/alice/.homebrew/bin:/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(env["HOME"], "/Users/alice")
        XCTAssertEqual(env["LANG"], "C")
        XCTAssertNil(env["SSH_ASKPASS"])
        XCTAssertNil(env["DISPLAY"])
        XCTAssertEqual(SSHEnvironment.makeProcessEnvironment(base: [:], extraPath: "", home: "/h")["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testDestinationParsing() {
        let dump = """
        user alice
        hostname tigressgateway.princeton.edu
        port 22
        controlmaster auto
        controlpath /Users/alice/.ssh/sockets/socket-alice@tigressgateway.princeton.edu:22
        """
        let destination = SSHEnvironment.destination(fromConfigDump: dump)
        XCTAssertEqual(destination, SSHDestination(user: "alice", hostName: "tigressgateway.princeton.edu", port: 22,
                                                   configuredControlPath: "/Users/alice/.ssh/sockets/socket-alice@tigressgateway.princeton.edu:22"))
        XCTAssertNil(SSHEnvironment.destination(fromConfigDump: "hostname h\ncontrolpath none\n")?.configuredControlPath)
        XCTAssertEqual(SSHEnvironment.destination(fromConfigDump: "hostname h\n")?.port, 22)
        XCTAssertNil(SSHEnvironment.destination(fromConfigDump: "user alice\n"))
    }

    func testFallbackControlPath() {
        let destination = SSHDestination(user: "alice", hostName: "h.example.org", port: 2222, configuredControlPath: nil)
        XCTAssertEqual(SSHEnvironment.fallbackControlPath(for: destination, home: "/Users/alice"), "/Users/alice/.ssh/sockets/lincoln-alice@h.example.org:2222")
        // Unix sockets cannot exceed 104 bytes: long names are hashed.
        let long = SSHDestination(user: "alice", hostName: String(repeating: "h", count: 80) + ".example.org", port: 22, configuredControlPath: nil)
        let path = SSHEnvironment.fallbackControlPath(for: long, home: "/Users/alice")
        XCTAssertLessThanOrEqual(path.utf8.count, SSHEnvironment.maximumSocketPathLength)
        XCTAssertTrue(path.hasPrefix("/Users/alice/.ssh/sockets/lincoln-"))
        XCTAssertEqual(path, SSHEnvironment.fallbackControlPath(for: long, home: "/Users/alice"), "stable across runs")
    }

    func testPrepareControlPathDirectoryCreatesPrivateDirectory() throws {
        let environment = makeEnvironment()
        let base = TestFixtures.temporaryDirectory("controlpath")
        defer { try? FileManager.default.removeItem(at: base) }
        try environment.prepareControlPathDirectory(base.appendingPathComponent("sockets/socket-a@b:22").path)
        let attributes = try FileManager.default.attributesOfItem(atPath: base.appendingPathComponent("sockets").path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
    }

    func testResolveAgainstRealSSH() async throws {
        // A short fake home keeps the fallback socket path within limits and
        // keeps the test out of the real ~/.ssh.
        let environment = makeEnvironment(home: URL(fileURLWithPath: "/tmp/lincoln-test-home"))
        let version = await environment.version()
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertTrue((version.standardError + version.standardOutput).contains("OpenSSH"))

        // ssh -G never connects; it prints the effective configuration.
        let tunnel = Tunnel(name: "x", host: "example.invalid", user: "alice", port: 2222, forwards: [.dynamic(port: 1080)])
        let maybeResolved = await environment.resolveControlPath(for: tunnel)
        let resolved = try XCTUnwrap(maybeResolved)
        XCTAssertEqual(resolved.destination.user, "alice")
        XCTAssertEqual(resolved.destination.hostName, "example.invalid")
        XCTAssertEqual(resolved.destination.port, 2222)
        XCTAssertFalse(resolved.path.isEmpty)
        if !resolved.isFromConfig {
            XCTAssertTrue(resolved.path.hasSuffix("/.ssh/sockets/lincoln-alice@example.invalid:2222"))
        }
    }
}
