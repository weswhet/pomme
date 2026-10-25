import Foundation

enum VMRunStateSnapshot: Equatable, Sendable {
    case stopped
    case running(BootMode)
    case paused(previousBootMode: BootMode)

    func resolving(_ requested: VMFinalState) -> Self {
        switch requested {
        case .previous:
            // Stopping a paused guest ends its session, so a VM paused in
            // Recovery isn't booted into Recovery again only to be paused.
            self == .paused(previousBootMode: .recovery) ? .stopped : self
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

    /// True when reaching this state starts recoveryOS.
    var bootsRecovery: Bool {
        switch self {
        case .running(.recovery), .paused(previousBootMode: .recovery): true
        default: false
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

enum VMStateTransactionError: PommeDescribedError, Equatable, Sendable {
    case captureFailed(PommeRetainedCause = .init())
    case transitionFailed(PommeRetainedCause = .init())
    case finalStateUnverified(PommeRetainedCause = .init())

    var code: PommeErrorCode {
        switch self {
        case .captureFailed: .recoveryRunStateUnavailable
        case .transitionFailed: .recoveryCleanupUnverified
        case .finalStateUnverified: .recoveryFinalStateUnverified
        }
    }

    var errorDescription: String? {
        switch self {
        case .captureFailed(let cause):
            cause.describing("Pomme couldn't record whether the VM was running, paused, or stopped.")
        case .transitionFailed(let cause):
            cause.describing("Pomme couldn't finish Recovery cleanup before it restored the VM's run state.")
        case .finalStateUnverified(let cause):
            cause.describing("Pomme couldn't confirm that the VM returned to the requested run state.")
        }
    }

    var recoverySuggestion: String? {
        "Run `pomme status NAME` to see the VM's state."
    }

    var underlying: (any Error)? {
        switch self {
        case .captureFailed(let cause), .transitionFailed(let cause), .finalStateUnverified(let cause): cause.underlying
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
        catch { throw VMStateTransactionError.captureFailed(PommeRetainedCause(error)) }
        do { try await afterCleanup() }
        catch { throw VMStateTransactionError.transitionFailed(PommeRetainedCause(error)) }
        let requested = original.resolving(finalState)
        do {
            try await port.request(requested)
            guard try await port.prove(requested) else {
                throw VMStateTransactionError.finalStateUnverified()
            }
        } catch let error as VMStateTransactionError {
            throw error
        } catch {
            throw VMStateTransactionError.finalStateUnverified(PommeRetainedCause(error))
        }
        return .init(original: original, requested: requested, verified: true)
    }
}
