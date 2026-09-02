import Testing

@Suite("VM destroy safety")
struct VMDestroySafetyTests {
    @Test("Deletion cannot continue when helper stop is unproved")
    func stopFailureBlocksDeletion() throws {
        #expect(throws: Error.self) {
            try PommeCore.requireDeletionStopSucceeded([
                "ok": false,
                "error": "simulated stop timeout"
            ])
        }
        #expect(throws: Never.self) {
            try PommeCore.requireDeletionStopSucceeded(["ok": true])
        }
    }
}
