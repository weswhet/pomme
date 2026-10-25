import Foundation

/// Only bridges image-file work for lifecycle entry points that are already
/// synchronous. VM queue work and lease acquisition stay in the caller.
enum PommeExperimentalRecoveryActivation {
    private final class ResultBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        func store(_ value: Result<Value, Error>) { lock.withLock { result = value } }
        func take() throws -> Value {
            let value = lock.withLock { result }
            guard let value else { throw PommeProvisioningError.integrityFailure }
            return try value.get()
        }
    }

    /// Runs the bridged task's jobs on its own queue. A caller that blocks on
    /// the bridge can occupy a cooperative thread, so the work it waits for
    /// must not need one.
    private final class QueueExecutor: TaskExecutor {
        private let queue = DispatchQueue(label: "com.github.weswhet.pomme.experimental-recovery-activation")

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            let executor = asUnownedTaskExecutor()
            queue.async { job.runSynchronously(on: executor) }
        }
    }

    private static let executor = QueueExecutor()

    static func synchronously<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        try Task.checkCancellation()
        let result = ResultBox<Value>()
        let completion = DispatchSemaphore(value: 0)
        let task = Task.detached(executorPreference: executor) {
            defer { completion.signal() }
            do { result.store(.success(try await operation())) }
            catch { result.store(.failure(error)) }
        }
        while completion.wait(timeout: .now() + 0.1) == .timedOut {
            if Task.isCancelled { task.cancel() }
        }
        return try result.take()
    }
}
