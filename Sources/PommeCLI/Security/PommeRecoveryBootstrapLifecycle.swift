import Foundation

enum PommeRecoveryBootstrapLifecycleError: Error, LocalizedError, Equatable, Sendable {
    case invalidTimeout
    case timedOut
    case cleanupFailed
    case finalStateFailed
    case cleanupAndFinalStateFailed

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "Recovery lifecycle timeout was invalid."
        case .timedOut:
            "Recovery lifecycle callback timed out."
        case .cleanupFailed:
            "Recovery lifecycle cleanup could not be proven."
        case .finalStateFailed:
            "Recovery lifecycle final state could not be proven."
        case .cleanupAndFinalStateFailed:
            "Recovery lifecycle cleanup and final state could not be proven."
        }
    }
}

enum PommeRecoveryBootstrapCallback {
    typealias Completion = @Sendable (Error?) -> Void

    static func awaitCompletion(
        timeout: TimeInterval,
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        start: @escaping @Sendable (@escaping Completion) -> Void
    ) async throws {
        guard timeout > 0 else { throw PommeRecoveryBootstrapLifecycleError.invalidTimeout }
        let gate = PommeRecoveryBootstrapCallbackGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                start { error in gate.finish(error.map(Result.failure) ?? .success(())) }
                let timeoutTask = Task.detached {
                    await sleep(UInt64(timeout * 1_000_000_000))
                    gate.finish(.failure(PommeRecoveryBootstrapLifecycleError.timedOut))
                }
                gate.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

private final class PommeRecoveryBootstrapCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var terminal: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        let prior = lock.withLock { () -> Result<Void, Error>? in
            guard terminal == nil else { return terminal }
            self.continuation = continuation
            return nil
        }
        guard let prior else { return true }
        continuation.resume(with: prior)
        return false
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let cancel = lock.withLock {
            guard terminal == nil else { return true }
            timeoutTask = task
            return false
        }
        if cancel { task.cancel() }
    }

    func finish(_ result: Result<Void, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard terminal == nil else { return nil }
            terminal = result
            timeoutTask?.cancel()
            timeoutTask = nil
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume(with: result)
    }
}

/// Bounded installer attempt primitive. Cleanup is required after
/// success, failure, and cancellation; unknown cleanup is terminal.
enum PommeRecoveryBootstrapAttempt {
    static func run<Output: Sendable>(
        operation: () async throws -> Output,
        cleanupAndVerifyAbsent: @escaping @Sendable () async throws -> Void
    ) async throws -> Output {
        var primary: Result<Output, Error>
        do { primary = .success(try await operation()) }
        catch { primary = .failure(error) }
        do { try await cleanupAndVerifyAbsent() }
        catch { throw PommeRecoveryBootstrapLifecycleError.cleanupFailed }
        return try primary.get()
    }
}
