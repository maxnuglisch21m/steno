import Foundation

/// Running an `async` operation that might never come back.
///
/// Swift's structured concurrency deliberately has no way to abandon a child task:
/// `withThrowingTaskGroup` waits for every child before it returns, so racing a
/// `Task.sleep` against a hung operation inside a group does not help — the group
/// itself blocks on the hang. Cancellation does not help either, because the operation
/// that matters here is stuck inside a synchronous C call in the audio daemon and will
/// never reach a cancellation point.
///
/// So the operation is run as an unstructured task and simply stopped being waited on.
/// The task is handed back with the timeout, because abandoning it is not the same as
/// forgetting it: a `start` that finishes two minutes late has opened a microphone
/// that has to be closed again and written a file that has to be removed.
enum Deadline {
    /// What came back, or the fact that nothing did.
    enum Outcome<Success: Sendable>: Sendable {
        /// The operation finished in time, successfully or not.
        case finished(Result<Success, any Error>)
        /// The operation is still running. It is the caller's to clean up.
        case timedOut(Task<Success, any Error>)

        /// The value, when there is one.
        var value: Success? {
            guard case .finished(.success(let value)) = self else { return nil }
            return value
        }
    }

    /// Runs `operation`, and gives up waiting after `limit`.
    ///
    /// The two inner tasks are what makes this a race the caller can win: whichever
    /// resumes the continuation first decides the outcome, and the loser's resume is
    /// dropped by `Once`. The task awaiting a hung operation lingers, which is the
    /// price of a call that cannot be cancelled — it costs one suspended task and no
    /// thread.
    static func run<Success: Sendable>(
        _ limit: Duration,
        operation: @escaping @Sendable () async throws -> Success
    ) async -> Outcome<Success> {
        let task = Task(operation: operation)
        return await withCheckedContinuation { continuation in
            let once = Once<Outcome<Success>>(continuation)
            Task {
                let result = await task.result
                once.resume(with: .finished(result))
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(with: .timedOut(task))
            }
        }
    }

    /// Resumes a continuation exactly once, whoever gets there first.
    ///
    /// A lock rather than an actor: both callers are already on their own tasks, and
    /// an actor hop here would mean the loser's `resume` could be reordered behind the
    /// winner's in a way that is harder to reason about than one `NSLock` around one
    /// boolean.
    private final class Once<Value: Sendable>: @unchecked Sendable {
        private let continuation: CheckedContinuation<Value, Never>
        private let lock = NSLock()
        private var hasResumed = false

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func resume(with value: Value) {
            let shouldResume: Bool = lock.withLock {
                guard !hasResumed else { return false }
                hasResumed = true
                return true
            }
            guard shouldResume else { return }
            continuation.resume(returning: value)
        }
    }
}
