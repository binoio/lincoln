import XCTest
@testable import LincolnCore

final class ConsoleBufferTests: XCTestCase {
    func testLinesAndTail() {
        var buffer = ConsoleBuffer()
        buffer.append("Duo two-factor login\n 1. Duo Push\nPasscode or option (1-2): ")
        XCTAssertEqual(buffer.lines, ["Duo two-factor login", " 1. Duo Push"])
        XCTAssertEqual(buffer.tail, "Passcode or option (1-2): ")
        buffer.append("\n")
        XCTAssertEqual(buffer.lines.count, 3)
        XCTAssertEqual(buffer.tail, "")
    }

    func testSplitChunksJoinAcrossAppends() {
        var buffer = ConsoleBuffer()
        buffer.append("Pass")
        buffer.append("code: ")
        XCTAssertEqual(buffer.tail, "Passcode: ")
        XCTAssertEqual(buffer.text, "Passcode: ")
        buffer.flushTail()
        XCTAssertEqual(buffer.lines, ["Passcode: "])
    }

    func testCapAndSystemLines() {
        var buffer = ConsoleBuffer(maximumLines: 3)
        buffer.append("1\n2\n3\n4\n")
        XCTAssertEqual(buffer.lines, ["2", "3", "4"])
        buffer.appendSystemLine("— connected —")
        XCTAssertEqual(buffer.lines, ["3", "4", "— connected —"])
        XCTAssertEqual(buffer.recentText(lineCount: 2), "4\n— connected —")
        buffer.clear()
        XCTAssertEqual(buffer.text, "")
    }

    func testEmptyAppendIsNoOp() {
        var buffer = ConsoleBuffer()
        buffer.append("")
        XCTAssertEqual(buffer, ConsoleBuffer())
    }
}
