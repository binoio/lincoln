import XCTest
@testable import LincolnCore

final class TunnelTests: XCTestCase {
    func testDefaultsAndDisplayName() {
        let tunnel = Tunnel(name: "", host: "tg")
        XCTAssertEqual(tunnel.displayName, "tg")
        XCTAssertTrue(tunnel.autoReconnect)
        XCTAssertTrue(tunnel.reconnectOnWake)
        XCTAssertFalse(tunnel.shareControlMaster)
        XCTAssertFalse(tunnel.autoConnect)
    }

    func testDestinationSummary() {
        XCTAssertEqual(Tunnel(name: "x", host: "tg").destinationSummary, "tg")
        XCTAssertEqual(Tunnel(name: "x", host: "tg", user: "alice", port: 2222).destinationSummary, "alice@tg:2222")
        XCTAssertEqual(Tunnel(name: "x", host: "tg", port: 22).destinationSummary, "tg")
    }

    func testValidationErrors() {
        XCTAssertEqual(Tunnel(name: "x", host: "").validationErrors, ["Host is required.", "Add at least one forward (SOCKS, local or remote)."])
        XCTAssertTrue(Tunnel(name: "x", host: "bad host", forwards: [.dynamic(port: 1)]).validationErrors.contains("Host must not contain whitespace."))
        let duplicate = Tunnel(name: "x", host: "tg", forwards: [.dynamic(port: 1080), .local(port: 1080, host: "a", hostPort: 1)])
        XCTAssertTrue(duplicate.validationErrors.contains("Two forwards listen on the same local port."))
        let badOption = Tunnel(name: "x", host: "tg", forwards: [.dynamic(port: 1080)], extraOptions: [SSHOption(key: "Bad Key", value: "1")])
        XCTAssertTrue(badOption.validationErrors.contains("Option \"Bad Key\" has an invalid name."))
        XCTAssertTrue(TestSupport.sampleTunnel().isValid)
    }

    func testDocumentMutation() {
        var document = TunnelDocument()
        let tunnel = TestSupport.sampleTunnel()
        document.upsert(tunnel)
        XCTAssertEqual(document.tunnels.count, 1)
        var renamed = tunnel
        renamed.name = "Renamed"
        document.upsert(renamed)
        XCTAssertEqual(document.tunnels.count, 1)
        XCTAssertEqual(document.tunnel(withID: tunnel.id)?.name, "Renamed")
        document.setDesiredUp(true, id: tunnel.id)
        document.setDesiredUp(true, id: tunnel.id)
        XCTAssertEqual(document.desiredUp, [tunnel.id])
        document.remove(id: tunnel.id)
        XCTAssertTrue(document.tunnels.isEmpty)
        XCTAssertTrue(document.desiredUp.isEmpty)
    }
}
