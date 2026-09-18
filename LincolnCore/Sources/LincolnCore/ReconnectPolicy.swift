//
//  ReconnectPolicy.swift
//  LincolnCore
//

import Foundation

/// Exponential backoff with a cap. `maximumInitialAttempts` bounds retries
/// of a connection that never came up (unreachable host, DNS); a tunnel that
/// was connected and then dropped retries indefinitely.
public struct ReconnectPolicy: Equatable {
    public var baseDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var maximumInitialAttempts: Int
    /// 0...1 fraction of the delay added as random jitter. 0 in tests.
    public var jitterFraction: Double

    public init(baseDelay: TimeInterval = 1, maximumDelay: TimeInterval = 60, maximumInitialAttempts: Int = 5, jitterFraction: Double = 0.2) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.maximumInitialAttempts = maximumInitialAttempts
        self.jitterFraction = jitterFraction
    }

    public static let `default` = ReconnectPolicy()
    public static let immediate = ReconnectPolicy(baseDelay: 0, maximumDelay: 0, maximumInitialAttempts: 1, jitterFraction: 0)

    /// Delay before attempt `attempt` (1-based).
    public func delay(forAttempt attempt: Int, random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let raw = baseDelay * pow(2, Double(min(exponent, 30)))
        let capped = min(raw, maximumDelay)
        guard jitterFraction > 0, capped > 0 else { return capped }
        return capped + random(0...(capped * jitterFraction))
    }

    public func allowsInitialRetry(afterAttempt attempt: Int) -> Bool {
        maximumInitialAttempts <= 0 || attempt < maximumInitialAttempts
    }
}
