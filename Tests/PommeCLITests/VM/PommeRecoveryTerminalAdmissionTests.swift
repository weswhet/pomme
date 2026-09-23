import Testing

@Suite("Recovery terminal admission cleanup")
struct PommeRecoveryTerminalAdmissionTests {
    @Test("Abandoned OCR prevents complete cleanup without skipping host cleanup")
    func abandonedOCRRunsAllCleanup() {
        var calls: [String] = []
        let complete = PommeRecoveryTerminalAdmission.performCleanup(
            sensitiveFramesCleared: false,
            clearStaging: { calls.append("staging") },
            clearState: { calls.append("state") },
            removeBootstrap: { calls.append("bootstrap") }
        )
        #expect(!complete)
        #expect(calls == ["staging", "state", "bootstrap"])
    }

    @Test("Cleared OCR preserves successful host cleanup")
    func clearedOCRCompletesCleanup() {
        #expect(PommeRecoveryTerminalAdmission.performCleanup(
            sensitiveFramesCleared: true,
            clearStaging: {},
            clearState: {},
            removeBootstrap: {}
        ))
    }

    @Test("Host cleanup failure still clears state and bootstrap", arguments: [true, false])
    func stagingFailureRunsRemainingCleanup(framesCleared: Bool) {
        var calls: [String] = []
        let complete = PommeRecoveryTerminalAdmission.performCleanup(
            sensitiveFramesCleared: framesCleared,
            clearStaging: {
                calls.append("staging")
                throw PommeRecoveryTerminalAdmission.Error.cleanupFailed
            },
            clearState: { calls.append("state") },
            removeBootstrap: { calls.append("bootstrap") }
        )
        #expect(!complete)
        #expect(calls == ["staging", "state", "bootstrap"])
    }
}
