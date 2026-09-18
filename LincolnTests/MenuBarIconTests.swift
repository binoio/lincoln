import XCTest
@testable import Lincoln

final class MenuBarIconTests: XCTestCase {
    func testIconsAreTemplateImagesOfMenuBarSize() {
        for variant in [MenuBarIcon.Variant.disconnected, .connected, .attention] {
            let image = MenuBarIcon.image(for: variant)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertTrue(image.isTemplate)
            XCTAssertNotNil(image.tiffRepresentation)
        }
    }

    func testVariantsRenderDifferently() {
        let a = MenuBarIcon.disconnected.tiffRepresentation
        let b = MenuBarIcon.connected.tiffRepresentation
        let c = MenuBarIcon.attention.tiffRepresentation
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
    }

    @MainActor
    func testAppIconIsAvailable() {
        XCTAssertNotNil(NSImage(named: "AppIcon"))
    }
}
