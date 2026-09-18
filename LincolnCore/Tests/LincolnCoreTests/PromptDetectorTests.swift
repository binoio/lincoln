import XCTest
@testable import LincolnCore

final class PromptDetectorTests: XCTestCase {
    func testDuoPasscodePrompt() {
        let prompt = PromptDetector.detect(lineTail: "Passcode or option (1-2): ")
        XCTAssertEqual(prompt?.kind, .passcode)
        XCTAssertEqual(prompt?.isSecret, false)
    }

    func testPassphraseIsSecret() {
        XCTAssertEqual(PromptDetector.detect(lineTail: "Enter passphrase for key '/Users/x/.ssh/id_ed25519':")?.kind, .secret)
        XCTAssertEqual(PromptDetector.detect(lineTail: "alice@tg's password:")?.kind, .secret)
    }

    func testHostKeyConfirmation() {
        let prompt = PromptDetector.detect(lineTail: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
        XCTAssertEqual(prompt?.kind, .hostKeyConfirmation)
    }

    func testGenericQuestion() {
        XCTAssertEqual(PromptDetector.detect(lineTail: "Choose an option:")?.kind, .generic)
        XCTAssertEqual(PromptDetector.detect(lineTail: "Verification code:")?.kind, .passcode)
    }

    func testNonPromptsAreIgnored() {
        XCTAssertNil(PromptDetector.detect(lineTail: ""))
        XCTAssertNil(PromptDetector.detect(lineTail: "Welcome to tigressgateway"))
        XCTAssertNil(PromptDetector.detect(lineTail: "debug1: Authentications that can continue"))
        XCTAssertNil(PromptDetector.detect(lineTail: String(repeating: "x", count: 600) + ":"))
    }

    func testSentinelDetection() {
        let id = UUID()
        XCTAssertTrue(PromptDetector.containsReadySentinel("banner\n\(SSHCommandBuilder.readySentinel(for: id))\n", tunnelID: id))
        XCTAssertFalse(PromptDetector.containsReadySentinel("LINCOLN_READY_other", tunnelID: id))
    }

    func testAuthenticationFailureAndDuoMenu() {
        XCTAssertTrue(PromptDetector.containsAuthenticationFailure("alice@tg: Permission denied (publickey,keyboard-interactive)."))
        XCTAssertFalse(PromptDetector.containsAuthenticationFailure("all good"))
        XCTAssertTrue(PromptDetector.looksLikeDuoMenu("Duo two-factor login for alice\n\n 1. Duo Push to XXX-XXX-1234\n 2. Phone call\n"))
        XCTAssertFalse(PromptDetector.looksLikeDuoMenu("Last login: today"))
    }
}
