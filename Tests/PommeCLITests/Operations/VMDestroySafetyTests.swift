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

    @Test("Deletion reports the automatic stop outcome", arguments: ["guest-stopped", "forced", "already-stopped"])
    func deletionReportsStopOutcome(method: String) throws {
        let reference = VMReference(name: "t1", bundle: BundleLayout(rootURL: URL(fileURLWithPath: "/tmp/t1.bundle")))
        let stop = PommeOperationResult(
            title: "Stop", vmName: "t1", ok: true, hostExitCode: 0, text: "OK stopped",
            payload: ["ok": true, "stopMethod": method, "guestShutdownRequested": method == "guest-stopped"]
        )

        let result = PommeApplication.deletionResult(
            reference: reference, payload: ["ok": true, "bundlePath": reference.bundle.rootURL.path], stopResult: stop
        )

        #expect(result.ok)
        #expect(result.payload["stopMethod"] as? String == method)
        #expect(result.payload["guestShutdownRequested"] as? Bool == (method == "guest-stopped"))
        #expect(result.text.contains("OK destroyed name=t1"))
        #expect(result.text.contains("the VM was powered off") == (method == "forced"))
        let json = try JSONSerialization.data(withJSONObject: result.payload)
        let decoded = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(decoded["stopMethod"] as? String == method)
    }

    @Test("Deletion does not invent an unavailable stop outcome")
    func deletionWithoutStopOutcome() {
        let reference = VMReference(name: "t1", bundle: BundleLayout(rootURL: URL(fileURLWithPath: "/tmp/t1.bundle")))
        let payload: [String: Any] = ["ok": true, "bundlePath": reference.bundle.rootURL.path]
        let stop = PommeOperationResult(
            title: "Stop", vmName: "t1", ok: true, hostExitCode: 0, text: "OK stopped", payload: ["ok": true]
        )

        let unknown = PommeApplication.deletionResult(reference: reference, payload: payload, stopResult: stop)
        #expect(unknown.payload["stopMethod"] is NSNull)
        #expect(unknown.payload["guestShutdownRequested"] as? Bool == false)
        #expect(!unknown.text.contains("forced"))

        let stopped = PommeApplication.deletionResult(reference: reference, payload: payload, stopResult: nil)
        #expect(stopped.payload["stopMethod"] == nil)
        #expect(stopped.payload["guestShutdownRequested"] == nil)
    }


    @Test("Deletion waits until the helper has exited")
    func deletionWaitsForHelperExit() throws {
        var observations = 0
        try PommeCore.waitForDeletionHelperExit(timeout: 1, pollInterval: 0.001) {
            observations += 1
            return observations < 3
        }
        #expect(observations == 3)
    }

    @Test("Deletion cannot proceed while the helper remains alive")
    func deletionRejectsHelperExitTimeout() {
        #expect(throws: Error.self) {
            try PommeCore.waitForDeletionHelperExit(timeout: 0, pollInterval: 0.001) { true }
        }
    }

    @Test("Deletion accepts an exited helper without waiting")
    func deletionAcceptsExitedHelper() throws {
        try PommeCore.waitForDeletionHelperExit(timeout: 0, pollInterval: 0.001) { false }
    }

    @Test("Deletion does not interpret an observation failure as helper exit")
    func deletionPropagatesHelperObservationFailure() {
        enum ObservationFailure: Error, Equatable { case unavailable }
        #expect(throws: ObservationFailure.unavailable) {
            try PommeCore.waitForDeletionHelperExit(timeout: 1, pollInterval: 0.001) {
                throw ObservationFailure.unavailable
            }
        }
    }

}
