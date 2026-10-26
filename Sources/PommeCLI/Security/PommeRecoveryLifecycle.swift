import Foundation
import os

enum PommeRecoveryLifecycleError: PommeDescribedError, Equatable, Sendable {
    case operationFailed(PommeRetainedCause = .init())
    case cleanupFailed(PommeRetainedCause = .init())
    case finalStateFailed(PommeRetainedCause = .init())
    case cleanupAndFinalStateFailed(PommeRetainedCause = .init())

    var code: PommeErrorCode {
        switch self {
        case .operationFailed: .recoveryOperationFailed
        case .cleanupFailed, .cleanupAndFinalStateFailed: .recoveryCleanupUnverified
        case .finalStateFailed: .recoveryFinalStateUnverified
        }
    }

    var errorDescription: String? {
        switch self {
        case .operationFailed(let cause):
            cause.describing("The Recovery operation didn't finish.")
        case .cleanupFailed(let cause):
            cause.describing("Pomme couldn't confirm that the Recovery session's files were removed.")
        case .finalStateFailed(let cause):
            cause.describing("Pomme couldn't confirm that the VM reached the requested final state after Recovery.")
        case .cleanupAndFinalStateFailed(let cause):
            cause.describing("The Recovery operation failed, and Pomme couldn't confirm that its files were removed or that the VM reached its final state.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .operationFailed: nil
        case .cleanupFailed, .cleanupAndFinalStateFailed:
            "Run `pomme stop NAME`, then run the same command again; Pomme cleans up the earlier session first."
        case .finalStateFailed:
            "Run `pomme status NAME` to see the VM's state."
        }
    }

    var underlying: (any Error)? {
        switch self {
        case .operationFailed(let cause), .cleanupFailed(let cause), .finalStateFailed(let cause),
             .cleanupAndFinalStateFailed(let cause):
            cause.underlying
        }
    }
}
struct PommeRecoveryLifecycleResult<Output: Sendable>: Sendable {
    let output: Output?
    let cleanup: PommeRecoveryCleanupEvidence
    let finalState: VMFinalState
    let finalStateVerified: Bool
    let operationSucceeded: Bool
}

/// The lifecycle tail is deliberately independent from display interaction.
/// It always attempts known cleanup after an operation attempt and refuses to
/// request the VM's final state until every cleanup bit is proven.
enum PommeRecoveryLifecycle {
    static func run<Output: Sendable>(
        operation: () async throws -> Output,
        cleanup: () async throws -> PommeRecoveryCleanupEvidence,
        requestFinalState: @escaping @Sendable (VMFinalState) async throws -> Void,
        proveFinalState: @escaping @Sendable (VMFinalState) async throws -> Bool,
        finalState: VMFinalState,
        cleanupRequired: Bool = true
    ) async throws -> PommeRecoveryLifecycleResult<Output> {
        var operationResult: Result<Output, Error>
        do {
            operationResult = .success(try await operation())
        } catch {
            // A later cleanup failure replaces this error in what the caller
            // sees, so record it now. Operation errors can carry guest
            // output, so only its codes are logged.
            logCodes(of: error, context: "Recovery operation")
            operationResult = .failure(error)
        }

        let cleanupResult: Result<PommeRecoveryCleanupEvidence, Error>
        if cleanupRequired {
            do {
                let evidence = try await cleanup()
                guard evidence.isComplete else {
                    throw PommeRecoveryLifecycleError.cleanupFailed()
                }
                cleanupResult = .success(evidence)
            } catch {
                logCodes(of: error, context: "Recovery cleanup")
                cleanupResult = .failure(error)
            }
        } else {
            cleanupResult = .failure(PommeRecoveryLifecycleError.cleanupFailed())
        }

        guard case .success(let cleanupEvidence) = cleanupResult else {
            // Final state is intentionally not requested when cleanup is
            // unknown. This is the key safety ordering of the lifecycle.
            let cause = cleanupResult.failureValue.map(PommeRetainedCause.wrapping) ?? .init()
            throw operationResult.isFailure
                ? PommeRecoveryLifecycleError.cleanupAndFinalStateFailed(cause)
                : PommeRecoveryLifecycleError.cleanupFailed(cause)
        }

        var finalStateSucceeded = false
        PommeUnifiedLog.recovery.notice(
            "Recovery cleanup proven; requesting final state \(finalState.rawValue, privacy: .public)")
        do {
            try await requestFinalState(finalState)
            finalStateSucceeded = try await proveFinalState(finalState)
            guard finalStateSucceeded else {
                throw PommeRecoveryLifecycleError.finalStateFailed()
            }
        } catch {
            logCodes(of: error, context: "Recovery final state \(finalState.rawValue)")
            let cause = PommeRetainedCause.wrapping(error)
            throw operationResult.isFailure
                ? PommeRecoveryLifecycleError.cleanupAndFinalStateFailed(cause)
                : PommeRecoveryLifecycleError.finalStateFailed(cause)
        }

        guard case .success(let output) = operationResult else {
            throw PommeRecoveryLifecycleError.operationFailed(operationResult.failureValue.map(PommeRetainedCause.wrapping) ?? .init())
        }
        return .init(
            output: output,
            cleanup: cleanupEvidence,
            finalState: finalState,
            finalStateVerified: finalStateSucceeded,
            operationSucceeded: true
        )
    }
}

/// Logs an error's catalog code, type, and domain code without its text.
private func logCodes(of error: any Error, context: String) {
    let code = PommeErrorReport(error, redaction: .secrets).code.rawValue
    let nsError = error as NSError
    PommeUnifiedLog.recovery.error("""
        \(context, privacy: .public) failed: code=\(code, privacy: .public) \
        type=\(String(reflecting: type(of: error)), privacy: .public) \
        domain=\(nsError.domain, privacy: .public) domainCode=\(nsError.code, privacy: .public)
        """)
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }

    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private extension PommeRetainedCause {
    /// Keeps `error` unless it's this lifecycle's own bare failure, which
    /// adds nothing to the message. Operation errors can carry guest output,
    /// so only codes are kept.
    static func wrapping(_ error: any Error) -> PommeRetainedCause {
        if let lifecycle = error as? PommeRecoveryLifecycleError, lifecycle.underlying == nil { return .init() }
        return PommeRetainedCause(codesOnly: error)
    }
}
