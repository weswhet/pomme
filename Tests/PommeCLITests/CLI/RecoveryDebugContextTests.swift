import Testing

@Suite("Recovery debug diagnostics")
struct RecoveryDebugContextTests {
    @Test func taskLocalDefaultsToDisabledAndScopesEnabledValue() async throws {
        #expect(PommeRecoveryDebugContext.screenshotsEnabled == false)

        try await PommeRecoveryDebugContext.$screenshotsEnabled.withValue(true) {
            #expect(PommeRecoveryDebugContext.screenshotsEnabled == true)
        }

        #expect(PommeRecoveryDebugContext.screenshotsEnabled == false)
    }

    @Test func helperMetadataIsRemovedBeforePublicRendering() {
        var payload: [String: Any] = [
            "ok": true,
            PommeRecoveryDebugScreenshotOutput.directoryKey: "/tmp/pomme-recovery-debug-dev",
            PommeRecoveryDebugScreenshotOutput.filesKey: ["/tmp/pomme-recovery-debug-dev/0001.png"]
        ]

        PommeRecoveryDebugScreenshotOutput.renderAndRemove(from: &payload)

        #expect(payload["ok"] as? Bool == true)
        #expect(payload[PommeRecoveryDebugScreenshotOutput.directoryKey] == nil)
        #expect(payload[PommeRecoveryDebugScreenshotOutput.filesKey] == nil)
    }
}
