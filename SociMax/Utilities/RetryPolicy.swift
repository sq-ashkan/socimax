import Foundation

/// Retry configuration with exponential backoff and jitter
struct RetryPolicy {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let retryableStatusCodes: Set<Int>

    static let `default` = RetryPolicy(
        maxAttempts: 2,
        baseDelay: 1.0,
        maxDelay: 10.0,
        retryableStatusCodes: [429, 500, 502, 503, 504]
    )

    static let aggressive = RetryPolicy(
        maxAttempts: 5,
        baseDelay: 2.0,
        maxDelay: 60.0,
        retryableStatusCodes: [429, 500, 502, 503, 504]
    )

    func delay(for attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(attempt))
        let capped = min(exponential, maxDelay)
        let jitter = Double.random(in: 0...(capped * 0.3))
        return capped + jitter
    }

    func shouldRetry(statusCode: Int, attempt: Int) -> Bool {
        attempt < maxAttempts - 1 && retryableStatusCodes.contains(statusCode)
    }
}
