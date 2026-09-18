import XCTest
@testable import LincolnCore

final class ANSIStripperTests: XCTestCase {
    func testStripsCSIAndOSC() {
        XCTAssertEqual(ANSIStripper.strip("\u{1B}[1;32mgreen\u{1B}[0m text"), "green text")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}]0;title\u{07}rest"), "rest")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}]0;title\u{1B}\\rest"), "rest")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}(Bplain"), "plain")
    }

    func testCarriageReturnsAndBells() {
        XCTAssertEqual(ANSIStripper.strip("line\r\nnext\r\n"), "line\nnext\n")
        XCTAssertEqual(ANSIStripper.strip("progress\rdone\u{07}"), "progressdone")
    }

    func testPlainTextUnchanged() {
        let text = "Passcode or option (1-2): "
        XCTAssertEqual(ANSIStripper.strip(text), text)
    }
}
