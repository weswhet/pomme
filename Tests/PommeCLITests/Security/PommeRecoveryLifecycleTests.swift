import Foundation
import Testing

@Suite("Pomme Recovery lifecycle")
struct PommeRecoveryLifecycleTests {
    @Test("Operation failure still cleans up before restoring final state")
    func operationFailureStillFinalizes() async {
        let calls = LifecycleCallCounter()
        let evidence = PommeRecoveryCleanupEvidence(
            shareRemoved: true,
            launcherRemoved: true,
            credentialRemoved: true,
            listenerClosed: true,
            sensitiveFramesCleared: true,
            unknownStateRejected: true
        )
        await #expect(throws: PommeRecoveryLifecycleError.operationFailed) {
            try await PommeRecoveryLifecycle.run(
                operation: { throw PommeRecoverySessionError.guestOperationFailed },
                cleanup: {
                    calls.incrementCleanup()
                    return evidence
                },
                requestFinalState: { _ in calls.incrementFinalState() },
                proveFinalState: { _ in true },
                finalState: .normal
            ) as PommeRecoveryLifecycleResult<Int>
        }
        #expect(calls.cleanup == 1)
        #expect(calls.finalState == 1)
    }

    @Test("Unknown cleanup blocks final-state transition")
    func cleanupFailureIsAuthoritative() async {
        let calls = LifecycleCallCounter()
        let incomplete = PommeRecoveryCleanupEvidence(
            shareRemoved: true,
            launcherRemoved: false,
            credentialRemoved: true,
            listenerClosed: true,
            sensitiveFramesCleared: true,
            unknownStateRejected: false
        )
        await #expect(throws: PommeRecoveryLifecycleError.cleanupFailed) {
            try await PommeRecoveryLifecycle.run(
                operation: { 1 },
                cleanup: { incomplete },
                requestFinalState: { _ in calls.incrementFinalState() },
                proveFinalState: { _ in true },
                finalState: .stopped
            )
        }
        #expect(calls.finalState == 0)
    }
}

private final class LifecycleCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var cleanupValue = 0
    private var finalStateValue = 0

    var cleanup: Int { lock.withLock { cleanupValue } }
    var finalState: Int { lock.withLock { finalStateValue } }
    func incrementCleanup() { lock.withLock { cleanupValue += 1 } }
    func incrementFinalState() { lock.withLock { finalStateValue += 1 } }
}
