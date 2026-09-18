import XCTest
@testable import LincolnCore

final class SSHConfigParserTests: XCTestCase {
    func testParsesHostBlocksFromText() {
        let hosts = SSHConfigParser.parse(text: """
        # comment
        Host tg
            HostName tigressgateway.princeton.edu
            DynamicForward 1080
        Host a b *.example.org
            User = bob
        Host *
            ProxyJump tg
        """)
        XCTAssertEqual(hosts.count, 3)
        XCTAssertEqual(hosts[0].alias, "tg")
        XCTAssertEqual(hosts[0].hostName, "tigressgateway.princeton.edu")
        XCTAssertEqual(hosts[0].forwards.map(\.specification), ["1080"])
        XCTAssertEqual(hosts[0].forwards.first?.kind, .dynamic)
        XCTAssertEqual(hosts[1].patterns, ["a", "b", "*.example.org"])
        XCTAssertEqual(hosts[1].user, "bob")
        XCTAssertTrue(hosts[1].isConcrete)
        XCTAssertFalse(hosts[2].isConcrete)
        XCTAssertNil(hosts[2].alias)
    }

    func testKeyLookupIsCaseInsensitive() {
        let hosts = SSHConfigParser.parse(text: "Host x\n  hostname h\n  PORT 2200\n  identityfile ~/.ssh/a\n  IdentityFile ~/.ssh/b\n")
        XCTAssertEqual(hosts[0].hostName, "h")
        XCTAssertEqual(hosts[0].port, 2200)
        XCTAssertEqual(hosts[0].identityFiles, ["~/.ssh/a", "~/.ssh/b"])
    }

    func testFixtureWithIncludesAndGlobs() throws {
        let home = try TestSupport.makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let parser = SSHConfigParser(homeDirectory: home)
        let hosts = try parser.parse()
        let aliases = hosts.compactMap { $0.alias }
        // config_local is included first, then the main file, then conf.d/*.conf.
        XCTAssertEqual(aliases, ["example-vm", "localhost", "github.com", "tg", "tigress-tunnel", "princeton-files", "adroit", "della", "quoted host", "extra"])

        let tg = try XCTUnwrap(hosts.first { $0.alias == "tg" })
        XCTAssertEqual(tg.forwards.map(\.summary), ["SOCKS on localhost:1080"])
        XCTAssertEqual(tg.proxyJump, "none")

        let files = try XCTUnwrap(hosts.first { $0.alias == "princeton-files" })
        XCTAssertEqual(files.forwards.map(\.specification), ["10445:files.princeton.edu:445"])
        XCTAssertEqual(files.hostName, "tigressgateway.princeton.edu")

        let vm = try XCTUnwrap(hosts.first { $0.alias == "example-vm" })
        XCTAssertEqual(vm.forwards.first?.kind, .remote)
        XCTAssertEqual(vm.user, "alice")
        XCTAssertTrue(vm.sourcePath.hasSuffix("config_local"))

        let extra = try XCTUnwrap(hosts.first { $0.alias == "extra" })
        XCTAssertEqual(extra.port, 2222)
        XCTAssertEqual(extra.forwards.first?.bindAddress, "127.0.0.1")

        XCTAssertTrue(hosts.contains { $0.isMatchBlock })
        XCTAssertFalse(hosts.contains { $0.isMatchBlock && $0.isConcrete })
        // The missing ~/.colima/ssh_config include is silently skipped.
        XCTAssertEqual(hosts.filter { $0.patterns == ["*"] }.count, 2)
    }

    func testMissingConfigReturnsEmpty() throws {
        let parser = SSHConfigParser(homeDirectory: URL(fileURLWithPath: "/nonexistent/home"))
        XCTAssertEqual(try parser.parse(), [])
    }

    func testIncludeCycleTerminates() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lincoln-cycle-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "Include other\nHost a\n HostName a\n".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Include config\nHost b\n HostName b\n".write(to: ssh.appendingPathComponent("other"), atomically: true, encoding: .utf8)
        let hosts = try SSHConfigParser(homeDirectory: home).parse()
        XCTAssertEqual(hosts.compactMap(\.alias), ["b", "a"])
    }

    func testSplitKeyValueForms() {
        XCTAssertEqual(SSHConfigParser.splitKeyValue("Host tg")?.1, "tg")
        XCTAssertEqual(SSHConfigParser.splitKeyValue("  User=bob  ")?.1, "bob")
        XCTAssertEqual(SSHConfigParser.splitKeyValue("User = bob")?.1, "bob")
        XCTAssertEqual(SSHConfigParser.splitKeyValue("Host\t\"quoted host\"")?.1, "\"quoted host\"")
        XCTAssertEqual(SSHConfigParser.splitWords("a \"b c\" d"), ["a", "b c", "d"])
        XCTAssertEqual(SSHConfigParser.splitWords("\"\" x"), ["", "x"])
        XCTAssertNil(SSHConfigParser.splitKeyValue("# comment"))
        XCTAssertNil(SSHConfigParser.splitKeyValue("   "))
    }
}
