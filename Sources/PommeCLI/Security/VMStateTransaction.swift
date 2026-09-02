import Foundation

enum VMRunStateSnapshot: Equatable, Sendable {
    case stopped
    case running(BootMode)
    case paused(previousBootMode: BootMode)

    func resolving(_ requested: VMFinalState) -> Self {
        switch requested {
        case .previous:
            self
        case .stopped:
            .stopped
        case .normal:
            .running(.normal)
        case .recovery:
            .running(.recovery)
        case .paused:
            .paused(previousBootMode: bootModeBeforePause)
        }
    }

    private var bootModeBeforePause: BootMode {
        switch self {
        case .running(let mode), .paused(let mode): mode
        case .stopped: .normal
        }
    }
}
/// Only the VM lifecycle is represented here. SIP and AMFI are intentionally
/// absent: those actions are admitted and verified by PommeRecoverySession.
protocol PommeVMFinalStatePort: Sendable {
    func captureRunState() async throws -> VMRunStateSnapshot
    func request(_ state: VMRunStateSnapshot) async throws
    func prove(_ state: VMRunStateSnapshot) async throws -> Bool
}

enum VMStateTransactionError: Error, LocalizedError, Equatable, Sendable {
    case captureFailed
    case transitionFailed
    case finalStateUnverified

    var errorDescription: String? {
        switch self {
        case .captureFailed:
            "VM run-state capture failed."
        case .transitionFailed:
            "VM run-state transition failed."
        case .finalStateUnverified:
            "VM final run state could not be verified."
        }
    }
}

struct VMStateTransactionResult: Equatable, Sendable {
    let original: VMRunStateSnapshot
    let requested: VMRunStateSnapshot
    let verified: Bool
}

/// Captures the original VM state and restores a requested final state only
/// after the Recovery session's cleanup barrier has completed.
struct VMStateTransaction: Sendable {
    let port: any PommeVMFinalStatePort

    init(port: any PommeVMFinalStatePort) {
        self.port = port
    }

    func restore(finalState: VMFinalState, afterCleanup: @escaping @Sendable () async throws -> Void) async throws -> VMStateTransactionResult {
        let original: VMRunStateSnapshot
        do { original = try await port.captureRunState() }
        catch { throw VMStateTransactionError.captureFailed }
        do { try await afterCleanup() }
        catch { throw VMStateTransactionError.transitionFailed }
        let requested = original.resolving(finalState)
        do {
            try await port.request(requested)
            guard try await port.prove(requested) else {
                throw VMStateTransactionError.finalStateUnverified
            }
        } catch let error as VMStateTransactionError {
            throw error
        } catch {
            throw VMStateTransactionError.finalStateUnverified
        }
        return .init(original: original, requested: requested, verified: true)
    }
}
