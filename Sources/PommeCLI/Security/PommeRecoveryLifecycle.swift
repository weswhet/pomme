import Foundation

enum PommeRecoveryLifecycleError: Error, LocalizedError, Equatable, Sendable {
    case operationFailed
    case cleanupFailed
    case finalStateFailed
    case cleanupAndFinalStateFailed

    var errorDescription: String? {
        switch self {
        case .operationFailed:
            "Recovery operation did not complete."
        case .cleanupFailed:
            "Recovery cleanup could not be proven complete."
        case .finalStateFailed:
            "Recovery final-state transition could not be proven."
        case .cleanupAndFinalStateFailed:
            "Recovery cleanup and final-state transition could not be proven."
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
            operationResult = .failure(error)
        }

        let cleanupResult: Result<PommeRecoveryCleanupEvidence, Error>
        if cleanupRequired {
            do {
                let evidence = try await cleanup()
                guard evidence.isComplete else {
                    throw PommeRecoveryLifecycleError.cleanupFailed
                }
                cleanupResult = .success(evidence)
            } catch {
                cleanupResult = .failure(error)
            }
        } else {
            cleanupResult = .failure(PommeRecoveryLifecycleError.cleanupFailed)
        }

        guard case .success(let cleanupEvidence) = cleanupResult else {
            // Final state is intentionally not requested when cleanup is
            // unknown. This is the key safety ordering of the lifecycle.
            throw operationResult.isFailure
                ? PommeRecoveryLifecycleError.cleanupAndFinalStateFailed
                : PommeRecoveryLifecycleError.cleanupFailed
        }

        var finalStateSucceeded = false
        do {
            try await requestFinalState(finalState)
            finalStateSucceeded = try await proveFinalState(finalState)
            guard finalStateSucceeded else {
                throw PommeRecoveryLifecycleError.finalStateFailed
            }
        } catch {
            throw operationResult.isFailure
                ? PommeRecoveryLifecycleError.cleanupAndFinalStateFailed
                : PommeRecoveryLifecycleError.finalStateFailed
        }

        guard case .success(let output) = operationResult else {
            throw PommeRecoveryLifecycleError.operationFailed
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

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
