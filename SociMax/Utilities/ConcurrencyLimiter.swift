import Foundation

/// Actor-based semaphore for limiting concurrent async operations
actor ConcurrencyLimiter {
    private let maxConcurrent: Int
    private var currentCount: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async {
        if currentCount < maxConcurrent {
            currentCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        } else {
            currentCount = max(0, currentCount - 1)
        }
    }

    /// Execute a block with the concurrency limit applied
    func withLimit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let result = try await operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}
