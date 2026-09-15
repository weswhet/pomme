import Foundation
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

    @Test("Deleting a stopped VM reports the removed bundle path")
    func deletionReportsBundlePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-destroy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = BundleLayout(rootURL: root.appendingPathComponent("t1.bundle", isDirectory: true))
        try FileManager.default.createDirectory(at: bundle.rootURL, withIntermediateDirectories: true)

        let payload = try PommeCore.destroyVMPayload(reference: VMReference(name: "t1", bundle: bundle), confirmation: nil)

        #expect(payload["bundlePath"] as? String == bundle.rootURL.path)
        #expect(!FileManager.default.fileExists(atPath: bundle.rootURL.path))
    }
}
