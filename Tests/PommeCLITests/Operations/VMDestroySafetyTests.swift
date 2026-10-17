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
        #expect(payload["credentialsRetained"] as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: bundle.rootURL.path))
    }

    /// A bundle with a provisioning journal but no signing key, as when a
    /// bundle is copied without its records: its ownership can't be proved.
    private func unprovenBundle(name: String) throws -> (root: URL, reference: VMReference) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-destroy-\(UUID().uuidString)", isDirectory: true)
        let bundle = BundleLayout(rootURL: root.appendingPathComponent("\(name).bundle", isDirectory: true))
        let records = bundle.rootURL.appendingPathComponent(".pomme", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let journal = records.appendingPathComponent("provisioning-v1.json")
        try Data("{}".utf8).write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        return (root, VMReference(name: name, bundle: bundle))
    }

    @Test("Deleting a VM whose records don't match keeps the bundle without force")
    func unprovenDeletionRequiresForce() throws {
        let (root, reference) = try unprovenBundle(name: "t1")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: PommeProvisioningError.ownershipMismatch) {
            try PommeCore.destroyVMPayload(reference: reference, confirmation: nil)
        }
        #expect(FileManager.default.fileExists(atPath: reference.bundle.rootURL.path))
    }

    @Test("Force deletes a VM whose records don't match and keeps its Keychain items")
    func unprovenForcedDeletionKeepsCredentials() throws {
        let (root, reference) = try unprovenBundle(name: "t1")
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = try PommeCore.destroyVMPayload(
            reference: reference, confirmation: nil, retainingUnprovenCredentials: true)

        #expect(payload["ok"] as? Bool == true)
        #expect(payload["credentialsRetained"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: reference.bundle.rootURL.path))
        let result = PommeApplication.deletionResult(reference: reference, payload: payload, stopResult: nil)
        #expect(result.text.contains("kept the VM's Keychain items"))
    }

    @Test("Only ownership and journal errors let force skip credential cleanup")
    func unprovenOwnershipClassification() {
        #expect(PommeCore.isUnprovenOwnership(PommeProvisioningError.ownershipMismatch))
        #expect(PommeCore.isUnprovenOwnership(PommeProvisioningError.integrityFailure))
        #expect(PommeCore.isUnprovenOwnership(PommeProvisioningError.invalidJournal))
        #expect(!PommeCore.isUnprovenOwnership(PommeProvisioningError.generationFailure))
        #expect(!PommeCore.isUnprovenOwnership(CocoaError(.fileWriteNoPermission)))
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
