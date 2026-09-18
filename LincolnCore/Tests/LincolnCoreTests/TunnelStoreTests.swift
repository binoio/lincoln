import XCTest
@testable import LincolnCore

final class TunnelStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lincoln-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: TunnelStore { TunnelStore(fileURL: directory.appendingPathComponent("tunnels.json")) }

    func testMissingFileLoadsEmptyDocument() throws {
        let result = try store.load()
        XCTAssertEqual(result.document, .empty)
        XCTAssertNil(result.quarantinedFileURL)
    }

    func testRoundTripIsStableAndIdempotent() throws {
        var document = TunnelDocument()
        document.upsert(TestSupport.sampleTunnel())
        document.setDesiredUp(true, id: TestSupport.sampleTunnel().id)
        try store.save(document)
        let first = try Data(contentsOf: store.fileURL)
        let loaded = try store.load().document
        XCTAssertEqual(loaded, document)
        try store.save(loaded)
        let second = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(first, second, "Saving an unchanged document must produce byte-identical output")
        XCTAssertTrue(String(data: first, encoding: .utf8)!.contains("\"schemaVersion\" : 1"))
    }

    func testDirectoryIsCreatedPrivately() throws {
        try store.save(.empty)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
    }

    func testCorruptFileIsQuarantinedNotDeleted() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)
        let result = try store.load()
        XCTAssertEqual(result.document, .empty)
        let quarantine = try XCTUnwrap(result.quarantinedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(quarantine.lastPathComponent.hasPrefix("tunnels.json.corrupt-"))
    }

    func testFutureSchemaVersionIsRejected() {
        let data = Data("{\"schemaVersion\": 99, \"tunnels\": [], \"desiredUp\": []}".utf8)
        XCTAssertThrowsError(try TunnelStore.decode(data)) { error in
            XCTAssertEqual(error as? TunnelStoreError, .unsupportedSchemaVersion(99))
        }
    }

    func testUnknownFieldsFromOtherVersionsAreIgnored() throws {
        // A file written by a build with extra per-tunnel fields still loads.
        let json = """
        {"schemaVersion": 1, "desiredUp": [], "tunnels": [{"id": "00000000-0000-0000-0000-000000000009", "name": "x", "host": "tg",
          "forwards": [], "extraOptions": [], "autoConnect": true, "notes": "", "shareControlMaster": true, "autoReconnect": false}]}
        """
        let (document, _) = try TunnelStore.decode(Data(json.utf8))
        XCTAssertEqual(document.tunnels.first?.autoConnect, true)
    }

    func testMissingSchemaVersionDefaultsToOne() throws {
        let data = Data("{\"tunnels\": [], \"desiredUp\": []}".utf8)
        let (document, migrated) = try TunnelStore.decode(data)
        XCTAssertEqual(document.tunnels, [])
        XCTAssertNil(migrated)
    }

    func testDefaultLocationIsApplicationSupport() {
        let url = TunnelStore.defaultFileURL()
        XCTAssertTrue(url.path.hasSuffix("/Lincoln/tunnels.json"))
    }
}
