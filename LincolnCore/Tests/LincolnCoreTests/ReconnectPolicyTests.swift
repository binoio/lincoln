import XCTest
@testable import LincolnCore

final class ReconnectPolicyTests: XCTestCase {
    func testExponentialBackoffIsCapped() {
        let policy = ReconnectPolicy(baseDelay: 1, maximumDelay: 60, maximumInitialAttempts: 5, jitterFraction: 0)
        XCTAssertEqual((1...8).map { policy.delay(forAttempt: $0) }, [1, 2, 4, 8, 16, 32, 60, 60])
    }

    func testJitterAddsAtMostFraction() {
        let policy = ReconnectPolicy(baseDelay: 10, maximumDelay: 60, maximumInitialAttempts: 5, jitterFraction: 0.5)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: { $0.upperBound }), 15)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: { $0.lowerBound }), 10)
    }

    func testInitialAttemptLimit() {
        let policy = ReconnectPolicy(maximumInitialAttempts: 3)
        XCTAssertTrue(policy.allowsInitialRetry(afterAttempt: 1))
        XCTAssertTrue(policy.allowsInitialRetry(afterAttempt: 2))
        XCTAssertFalse(policy.allowsInitialRetry(afterAttempt: 3))
        XCTAssertTrue(ReconnectPolicy(maximumInitialAttempts: 0).allowsInitialRetry(afterAttempt: 1_000))
    }

    func testImmediatePolicyHasNoDelay() {
        XCTAssertEqual(ReconnectPolicy.immediate.delay(forAttempt: 5), 0)
    }
}
