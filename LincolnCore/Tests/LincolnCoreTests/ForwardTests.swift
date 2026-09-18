import XCTest
@testable import LincolnCore

final class ForwardTests: XCTestCase {
    func testDynamicSpecificationAndArguments() {
        let forward = Forward.dynamic(port: 1080)
        XCTAssertEqual(forward.specification, "1080")
        XCTAssertEqual(forward.sshArguments, ["-D", "1080"])
        XCTAssertEqual(forward.configLine, "DynamicForward 1080")
        XCTAssertTrue(forward.isValid)
    }

    func testLocalWithBindAddress() {
        let forward = Forward.local(port: 5901, host: "localhost", hostPort: 5901, bindAddress: "127.0.0.1")
        XCTAssertEqual(forward.specification, "127.0.0.1:5901:localhost:5901")
        XCTAssertEqual(forward.configLine, "LocalForward 127.0.0.1:5901 localhost:5901")
    }

    func testIPv6TargetIsBracketed() {
        let forward = Forward.local(port: 8080, host: "::1", hostPort: 80)
        XCTAssertEqual(forward.specification, "8080:[::1]:80")
    }

    func testParseConfigValues() {
        XCTAssertEqual(Forward.parse(kind: .dynamic, configValue: "1080")?.listenPort, 1080)
        XCTAssertEqual(Forward.parse(kind: .dynamic, configValue: "localhost:1080")?.bindAddress, "localhost")
        let local = Forward.parse(kind: .local, configValue: "10445 files.princeton.edu:445")
        XCTAssertEqual(local?.listenPort, 10445)
        XCTAssertEqual(local?.targetHost, "files.princeton.edu")
        XCTAssertEqual(local?.targetPort, 445)
        let bound = Forward.parse(kind: .remote, configValue: "0.0.0.0:8022 [::1]:22")
        XCTAssertEqual(bound?.bindAddress, "0.0.0.0")
        XCTAssertEqual(bound?.targetHost, "::1")
        XCTAssertNil(Forward.parse(kind: .local, configValue: "10445"))
        XCTAssertNil(Forward.parse(kind: .local, configValue: "abc def:ghi"))
    }

    func testParseCommandLineArgument() {
        let forward = Forward.parse(kind: .local, argument: "127.0.0.1:10445:files.princeton.edu:445")
        XCTAssertEqual(forward?.bindAddress, "127.0.0.1")
        XCTAssertEqual(forward?.listenPort, 10445)
        XCTAssertEqual(forward?.targetHost, "files.princeton.edu")
        XCTAssertEqual(forward?.targetPort, 445)
        XCTAssertNil(Forward.parse(kind: .local, argument: "10445"))
    }

    func testParseConfigDumpLines() {
        XCTAssertEqual(Forward.parse(configDumpLine: "localforward 10445 [files.princeton.edu]:445")?.specification, "10445:files.princeton.edu:445")
        XCTAssertEqual(Forward.parse(configDumpLine: "localforward [127.0.0.1]:5901 [localhost]:5901")?.bindAddress, "127.0.0.1")
        XCTAssertEqual(Forward.parse(configDumpLine: "remoteforward 8022 [localhost]:22")?.kind, .remote)
        XCTAssertEqual(Forward.parse(configDumpLine: "dynamicforward 1080")?.listenPort, 1080)
        XCTAssertNil(Forward.parse(configDumpLine: "forwardagent no"))
        XCTAssertNil(Forward.parse(configDumpLine: "hostname h"))
    }

    func testListensLike() {
        XCTAssertTrue(Forward.dynamic(port: 1080).listensLike(Forward.dynamic(port: 1080, bindAddress: "localhost")))
        XCTAssertTrue(Forward.dynamic(port: 1080, bindAddress: "127.0.0.1").listensLike(Forward.dynamic(port: 1080)))
        XCTAssertFalse(Forward.dynamic(port: 1080).listensLike(Forward.dynamic(port: 1081)))
        XCTAssertFalse(Forward.dynamic(port: 1080).listensLike(Forward.local(port: 1080, host: "h", hostPort: 1)))
        XCTAssertFalse(Forward.dynamic(port: 1080).listensLike(Forward.dynamic(port: 1080, bindAddress: "0.0.0.0")))
    }

    func testValidation() {
        XCTAssertFalse(Forward.local(port: 0, host: "x", hostPort: 1).isValid)
        XCTAssertFalse(Forward.local(port: 10, host: "", hostPort: 1).isValid)
        XCTAssertFalse(Forward.local(port: 10, host: "x", hostPort: 70000).isValid)
        XCTAssertTrue(Forward.remote(port: 10, host: "x", hostPort: 22).isValid)
    }
}
