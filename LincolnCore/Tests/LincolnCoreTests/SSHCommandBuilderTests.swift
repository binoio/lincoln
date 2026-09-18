import XCTest
@testable import LincolnCore

final class SSHCommandBuilderTests: XCTestCase {
    private let tunnel = TestSupport.sampleTunnel()
    private var sentinel: String { SSHCommandBuilder.readySentinel(for: tunnel.id) }

    func testGoldenArgumentsWithoutControlMaster() {
        let args = SSHCommandBuilder.arguments(for: tunnel)
        XCTAssertEqual(args, [
            "-N",
            "-o", "ClearAllForwardings=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "PermitLocalCommand=yes",
            "-o", "LocalCommand=echo \(sentinel)",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-D", "1080",
            "-L", "10445:files.princeton.edu:445",
            "--", "tg"
        ])
    }

    func testControlMasterOnlyWhenOptedInAndResolved() {
        var shared = tunnel
        shared.shareControlMaster = true
        let args = SSHCommandBuilder.arguments(for: shared, controlPath: "~/.ssh/sockets/socket-%r@%h:%p")
        XCTAssertTrue(args.contains("ControlMaster=yes"))
        XCTAssertTrue(args.contains("ControlPath=~/.ssh/sockets/socket-%r@%h:%p"))
        XCTAssertTrue(args.contains("ControlPersist=no"))
        XCTAssertFalse(args.contains("ControlPath=none"))

        // Opted in but the host resolves ControlPath none → stay isolated.
        let isolated = SSHCommandBuilder.arguments(for: shared, controlPath: "none")
        XCTAssertTrue(isolated.contains("ControlMaster=no"))
        // Not opted in → controlPath is ignored.
        let ignored = SSHCommandBuilder.arguments(for: tunnel, controlPath: "/tmp/x")
        XCTAssertTrue(ignored.contains("ControlMaster=no"))
    }

    func testUserPortIdentityAndExtras() {
        var custom = tunnel
        custom.user = "alice"
        custom.port = 2222
        custom.identityFile = "~/.ssh/id_ed25519"
        custom.extraOptions = [SSHOption(key: "Compression", value: "yes"), SSHOption(key: " ", value: "ignored")]
        let args = SSHCommandBuilder.arguments(for: custom, environment: .init(serverAliveInterval: 10, serverAliveCountMax: 2))
        XCTAssertTrue(args.contains("ServerAliveInterval=10"))
        XCTAssertTrue(args.contains("ServerAliveCountMax=2"))
        let joined = args.joined(separator: " ")
        XCTAssertTrue(joined.contains("-p 2222 -l alice -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes"))
        XCTAssertTrue(joined.hasSuffix("-o Compression=yes -- tg"))
        XCTAssertFalse(joined.contains("ignored"))
    }

    func testInvalidForwardsAreSkipped() {
        var broken = tunnel
        broken.forwards.append(Forward.local(port: 0, host: "", hostPort: 0))
        let args = SSHCommandBuilder.arguments(for: broken)
        XCTAssertEqual(args.filter { $0 == "-L" }.count, 1)
    }

    func testPasswordAuthenticationIsAlwaysDisabledAndForwardsAlwaysCleared() {
        var custom = tunnel
        custom.extraOptions = [SSHOption(key: "PasswordAuthentication", value: "yes")]
        let args = SSHCommandBuilder.arguments(for: custom)
        // The pinned option comes first; ssh uses the first value it sees.
        XCTAssertEqual(args.firstIndex(of: "PasswordAuthentication=no")! < args.firstIndex(of: "PasswordAuthentication=yes")!, true)
        XCTAssertTrue(args.contains("ClearAllForwardings=yes"))
    }

    func testCommandLineIsShellQuoted() {
        var spaced = tunnel
        spaced.extraOptions = [SSHOption(key: "ProxyCommand", value: "nc -x localhost:1080 %h %p")]
        let line = SSHCommandBuilder.commandLine(for: spaced)
        XCTAssertTrue(line.hasPrefix("/usr/bin/ssh -N -o ClearAllForwardings=yes"))
        XCTAssertTrue(line.contains("'LocalCommand=echo \(sentinel)'"))
        XCTAssertTrue(line.contains("'ProxyCommand=nc -x localhost:1080 %h %p'"))
        XCTAssertEqual(SSHCommandBuilder.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(SSHCommandBuilder.shellQuoted(""), "''")
    }

    func testSentinelIsUniquePerTunnel() {
        XCTAssertEqual(sentinel, "LINCOLN_READY_00000000-0000-0000-0000-000000000001")
        XCTAssertNotEqual(sentinel, SSHCommandBuilder.readySentinel(for: UUID()))
    }

    func testConfigSnippet() {
        var custom = tunnel
        custom.user = "alice"
        let snippet = SSHCommandBuilder.sshConfigSnippet(for: custom)
        XCTAssertEqual(snippet, """
        Host lincoln-gateway-socks
            HostName tg
            User alice
            DynamicForward 1080
            LocalForward 10445 files.princeton.edu:445
            SessionType none
            ExitOnForwardFailure yes
            PasswordAuthentication no

        """)
    }
}
