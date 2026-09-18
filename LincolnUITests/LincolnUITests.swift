//
//  LincolnUITests.swift
//  LincolnUITests
//

import XCTest

final class LincolnUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchAndWindowElements() throws {
        let app = XCUIApplication()
        app.launch()
        let window = app.windows.firstMatch
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5) || statusItem.waitForExistence(timeout: 5))
    }
}
