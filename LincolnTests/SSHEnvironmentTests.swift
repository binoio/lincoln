import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class SSHEnvironmentTests: XCTestCase {
    func testProcessEnvironmentPrependsPathAndPinsTerminal() {
        let env = SSHEnvironment.makeProcessEnvironment(
            base: ["PATH": "/usr/bin:/bin", "SSH_ASKPASS": "/x", "DISPLAY": ":0", "LANG": "C"],
            extraPath: "~/.homebrew/bin:/opt/homebrew/bin:/usr/bin",
            sshAuthSock: "",
            home: "/Users/alice"
        )
        XCTAssertEqual(env["PATH"], "/Users/alice/.homebrew/bin:/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(env["TERM"], "dumb")
        XCTAssertEqual(env["HOME"], "/Users/alice")
        XCTAssertEqual(env["LANG"], "C")
        XCTAssertNil(env["SSH_ASKPASS"])
        XCTAssertNil(env["DISPLAY"])
        XCTAssertNil(env["SSH_AUTH_SOCK"])
    }

    func testSSHAuthSockOverrideAndDefaultLang() {
        let env = SSHEnvironment.makeProcessEnvironment(base: [:], extraPath: "", sshAuthSock: " ~/.ssh/agent/sock ", home: "/Users/alice")
        XCTAssertEqual(env["SSH_AUTH_SOCK"], "/Users/alice/.ssh/agent/sock")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testControlPathParsing() {
        let dump = """
        user alice
        hostname tigressgateway.princeton.edu
        port 22
        controlmaster auto
        controlpath /Users/alice/.ssh/sockets/socket-alice@tigressgateway.princeton.edu:22
        """
        XCTAssertEqual(SSHEnvironment.controlPath(fromConfigDump: dump), "/Users/alice/.ssh/sockets/socket-alice@tigressgateway.princeton.edu:22")
        XCTAssertNil(SSHEnvironment.controlPath(fromConfigDump: "controlpath none\n"))
        XCTAssertNil(SSHEnvironment.controlPath(fromConfigDump: "user alice\n"))
    }

    func testPrepareControlPathDirectoryCreatesPrivateDirectory() throws {
        let settings = SettingsManager(defaults: TestFixtures.isolatedDefaults(), loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        let environment = SSHEnvironment(settings: settings)
        let base = TestFixtures.temporaryDirectory("controlpath")
        defer { try? FileManager.default.removeItem(at: base) }
        let socket = base.appendingPathComponent("sockets/socket-a@b:22").path
        try environment.prepareControlPathDirectory(socket)
        let attributes = try FileManager.default.attributesOfItem(atPath: base.appendingPathComponent("sockets").path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
    }

    func testResolveControlPathAgainstRealSSH() async throws {
        let settings = SettingsManager(defaults: TestFixtures.isolatedDefaults(), loginItem: FakeLoginItem())
        settings.appliesActivationPolicy = false
        let environment = SSHEnvironment(settings: settings)
        let version = await environment.version()
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertTrue(version.standardError.contains("OpenSSH") || version.standardOutput.contains("OpenSSH"))

        // ssh -G never connects; it just prints the effective configuration.
        let tunnel = Tunnel(name: "x", host: "example.invalid", user: "alice", port: 2222, forwards: [.dynamic(port: 1080)])
        let result = await environment.run(arguments: ["-G", "-p", "2222", "-l", "alice", "--", "example.invalid"])
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("user alice"))
        _ = await environment.resolveControlPath(for: tunnel)
    }
}
