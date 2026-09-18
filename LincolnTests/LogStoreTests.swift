import XCTest
@testable import Lincoln

@MainActor
final class LogStoreTests: XCTestCase {
    func testInitialEntryAndCap() {
        let store = LogStore(maxEntries: 3)
        XCTAssertEqual(store.entries.count, 1)
        for i in 0..<5 {
            store.log(level: .info, category: "Test", message: "m\(i)")
        }
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.last?.message, "m4")
    }

    func testClearAndExport() {
        let store = LogStore()
        store.log(level: .error, category: "Tunnel", message: "boom", details: "trace")
        XCTAssertTrue(store.exportFormattedText.contains("[ERROR] [Tunnel] boom"))
        XCTAssertTrue(store.exportFormattedText.contains("Details:\ntrace"))
        store.clear()
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.message, "Logs cleared.")
    }

    func testStaticLogReachesSharedStore() async {
        let before = LogStore.shared.entries.count
        LogStore.log(level: .warning, category: "Test", message: "static")
        await drainMainQueue()
        XCTAssertEqual(LogStore.shared.entries.count, before + 1)
        XCTAssertEqual(LogStore.shared.entries.last?.level, .warning)
    }
}
