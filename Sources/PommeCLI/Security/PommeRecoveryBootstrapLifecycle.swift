import Foundation
import os

enum PommeRecoveryBootstrapLifecycleError: PommeDescribedError, Equatable, Sendable {
    case invalidTimeout
    case timedOut
    case cleanupFailed(PommeRetainedCause = .init())
    case finalStateFailed
    case cleanupAndFinalStateFailed

    var code: PommeErrorCode {
        switch self {
        case .invalidTimeout: .recoveryRequestRejected
        case .timedOut: .recoveryTimedOut
        case .cleanupFailed, .cleanupAndFinalStateFailed: .recoveryCleanupUnverified
        case .finalStateFailed: .recoveryFinalStateUnverified
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "The Recovery bootstrap time limit isn't a positive number of seconds."
        case .timedOut:
            "The Recovery bootstrap step didn't finish within its time limit."
        case .cleanupFailed(let cause):
            cause.describing("Pomme couldn't confirm that the Recovery bootstrap files were removed.")
        case .finalStateFailed:
            "Pomme couldn't confirm the VM's final state after the Recovery bootstrap."
        case .cleanupAndFinalStateFailed:
            "Pomme couldn't confirm that the Recovery bootstrap files were removed or that the VM reached its final state."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidTimeout: nil
        case .timedOut, .cleanupFailed, .cleanupAndFinalStateFailed:
            "Run `pomme stop NAME`, then run the same command again."
        case .finalStateFailed: "Run `pomme status NAME` to see the VM's state."
        }
    }

    var underlying: (any Error)? {
        if case .cleanupFailed(let cause) = self { return cause.underlying }
        return nil
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
        catch {
            // A cleanup failure below replaces this error, so record its
            // codes now; installer errors can carry guest output.
            let nsError = error as NSError
            PommeUnifiedLog.recovery.error("""
                Recovery bootstrap attempt failed: \
                code=\(PommeErrorReport(error).code.rawValue, privacy: .public) \
                type=\(String(reflecting: type(of: error)), privacy: .public) \
                domain=\(nsError.domain, privacy: .public) domainCode=\(nsError.code, privacy: .public)
                """)
            primary = .failure(error)
        }
        do { try await cleanupAndVerifyAbsent() }
        catch {
            PommeUnifiedLog.error(error, context: "Recovery bootstrap cleanup", logger: PommeUnifiedLog.recovery)
            throw PommeRecoveryBootstrapLifecycleError.cleanupFailed(PommeRetainedCause(error))
        }
        return try primary.get()
    }
}
