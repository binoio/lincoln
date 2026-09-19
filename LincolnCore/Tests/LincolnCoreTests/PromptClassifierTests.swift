import XCTest
@testable import LincolnCore

final class PromptClassifierTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(PromptClassifier.kind(prompt: "Passcode or option (1-2): ", hint: nil), .text)
        XCTAssertEqual(PromptClassifier.kind(prompt: "Enter passphrase for key '/x/id_ed25519': ", hint: nil), .secret)
        XCTAssertEqual(PromptClassifier.kind(prompt: "alice@tg's password: ", hint: nil), .secret)
        XCTAssertEqual(PromptClassifier.kind(prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ", hint: nil), .confirmation)
        XCTAssertEqual(PromptClassifier.kind(prompt: "Anything", hint: "confirm"), .confirmation)
        XCTAssertEqual(PromptClassifier.kind(prompt: "PIN: ", hint: nil), .secret)
    }

    func testNotificationHint() {
        XCTAssertTrue(PromptClassifier.isNotification(hint: "none"))
        XCTAssertFalse(PromptClassifier.isNotification(hint: "confirm"))
        XCTAssertFalse(PromptClassifier.isNotification(hint: nil))
    }
}
