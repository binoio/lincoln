import XCTest
@testable import LincolnCore

final class SSHCommandBuilderTests: XCTestCase {
    private let tunnel = TestSupport.sampleTunnel()
    private let controlPath = "/Users/alice/.ssh/sockets/socket-alice@tigressgateway.princeton.edu:22"

    func testGoldenMasterArguments() {
        let args = SSHCommandBuilder.masterArguments(for: tunnel, controlPath: controlPath)
        XCTAssertEqual(args, [
            "-M", "-N", "-f",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-D", "1080",
            "-L", "10445:files.princeton.edu:445",
            "--", "tg"
        ])
    }

    func testDestinationArgumentsAreSharedByEveryForm() {
        var custom = tunnel
        custom.user = "alice"
        custom.port = 2222
        let destination = ["-p", "2222", "-l", "alice", "--", "tg"]
        XCTAssertEqual(SSHCommandBuilder.destinationArguments(for: custom), destination)
        XCTAssertEqual(SSHCommandBuilder.configDumpArguments(for: custom), ["-G"] + destination)
        XCTAssertEqual(SSHCommandBuilder.checkArguments(for: custom, controlPath: "/tmp/s"), ["-O", "check", "-o", "ControlPath=/tmp/s"] + destination)
        XCTAssertEqual(SSHCommandBuilder.exitArguments(for: custom, controlPath: "/tmp/s"), ["-O", "exit", "-o", "ControlPath=/tmp/s"] + destination)
        XCTAssertEqual(SSHCommandBuilder.sessionArguments(for: custom, controlPath: "/tmp/s"), ["-o", "ControlPath=/tmp/s"] + destination)
        XCTAssertTrue(SSHCommandBuilder.masterArguments(for: custom, controlPath: "/tmp/s").joined(separator: " ").hasSuffix("-p 2222 -l alice -- tg"))
    }

    func testIdentityAndExtras() {
        var custom = tunnel
        custom.identityFile = "~/.ssh/id_ed25519"
        custom.extraOptions = [SSHOption(key: "Compression", value: "yes"), SSHOption(key: " ", value: "ignored")]
        let joined = SSHCommandBuilder.masterArguments(for: custom, controlPath: "/tmp/s", environment: .init(serverAliveInterval: 10, serverAliveCountMax: 2)).joined(separator: " ")
        XCTAssertTrue(joined.contains("ServerAliveInterval=10 -o ServerAliveCountMax=2"))
        XCTAssertTrue(joined.contains("-i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes"))
        XCTAssertTrue(joined.contains("-o Compression=yes -- tg"))
        XCTAssertFalse(joined.contains("ignored"))
    }

    func testForwardsAlreadyInConfigAreNotAddedTwice() {
        // `ssh -G tg` reports DynamicForward 1080 from the config; adding -D 1080
        // again would fail to bind and, with ExitOnForwardFailure, exit.
        let configured = [Forward.dynamic(port: 1080, bindAddress: "localhost")]
        let args = SSHCommandBuilder.masterArguments(for: tunnel, controlPath: "/tmp/s", configuredForwards: configured)
        XCTAssertFalse(args.contains("-D"))
        XCTAssertTrue(args.contains("10445:files.princeton.edu:445"))
        XCTAssertFalse(args.contains("ClearAllForwardings=yes"), "ClearAllForwardings also clears command-line forwards")
        let script = SSHCommandBuilder.terminalScript(for: tunnel, controlPath: "/tmp/s", statusFile: "/tmp/x", configuredForwards: configured)
        XCTAssertFalse(script.contains("-D 1080"))
    }

    func testInvalidForwardsAreSkippedAndPinnedOptionsComeFirst() {
        var custom = tunnel
        custom.forwards.append(Forward.local(port: 0, host: "", hostPort: 0))
        custom.extraOptions = [SSHOption(key: "PasswordAuthentication", value: "yes")]
        let args = SSHCommandBuilder.masterArguments(for: custom, controlPath: "/tmp/s")
        XCTAssertEqual(args.filter { $0 == "-L" }.count, 1)
        XCTAssertLessThan(args.firstIndex(of: "PasswordAuthentication=no")!, args.firstIndex(of: "PasswordAuthentication=yes")!)
    }

    func testMasterPIDParsing() {
        XCTAssertEqual(SSHCommandBuilder.masterPID(fromCheckOutput: "Master running (pid=4242)\n"), 4242)
        XCTAssertNil(SSHCommandBuilder.masterPID(fromCheckOutput: "Control socket connect(/tmp/s): No such file or directory\n"))
    }

    func testTerminalScript() {
        let script = SSHCommandBuilder.terminalScript(for: tunnel, controlPath: "/tmp/sock dir/s", statusFile: "/tmp/state/x.status")
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(script.contains("/usr/bin/ssh -M -N -f -o 'ControlPath=/tmp/sock dir/s' -o ExitOnForwardFailure=yes"))
        XCTAssertTrue(script.contains("ssh_status=$?"), "`status` is read-only in zsh")
        XCTAssertTrue(script.contains("> /tmp/state/x.status"))
        XCTAssertTrue(script.contains("'Gateway SOCKS'"))
        XCTAssertTrue(script.hasSuffix("fi\n"))
    }

    func testShellQuoting() {
        XCTAssertEqual(SSHCommandBuilder.shellQuoted("it's"), "'it'\\''s'")
        XCTAssertEqual(SSHCommandBuilder.shellQuoted(""), "''")
        XCTAssertEqual(SSHCommandBuilder.shellQuoted("ControlPath=/a/b:22"), "ControlPath=/a/b:22")
        XCTAssertEqual(SSHCommandBuilder.commandLine(executable: "/usr/bin/ssh", arguments: ["-o", "ProxyCommand=nc %h %p"]), "/usr/bin/ssh -o 'ProxyCommand=nc %h %p'")
    }

    func testConfigSnippet() {
        var custom = tunnel
        custom.user = "alice"
        XCTAssertEqual(SSHCommandBuilder.sshConfigSnippet(for: custom), """
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
