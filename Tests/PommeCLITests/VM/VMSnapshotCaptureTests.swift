import Foundation
import Testing

@Suite("Snapshot capture completion")
struct VMSnapshotCaptureTests {
    private let success: [String: Any] = ["ok": true, "operation": "snapshot-save", "hostExitCode": 0]

    @Test("Consuming restored state removes only the required artifacts")
    func consumesRequiredRestore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-snapshot-consume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = BundleLayout(rootURL: root)
        let unrelated = root.appendingPathComponent("retained")
        try Data("untouched".utf8).write(to: unrelated)
        try Data("state".utf8).write(to: bundle.saveStateURL)
        #expect(throws: (any Error).self) {
            try VMSnapshotStore.consumeRequiredRestore(bundle: bundle)
        }
        #expect(FileManager.default.fileExists(atPath: bundle.saveStateURL.path))
        try Data("required\n".utf8).write(to: bundle.requiredSnapshotRestoreURL)
        try VMSnapshotStore.consumeRequiredRestore(bundle: bundle)
        #expect(!FileManager.default.fileExists(atPath: bundle.saveStateURL.path))
        #expect(!FileManager.default.fileExists(atPath: bundle.requiredSnapshotRestoreURL.path))
        #expect(try Data(contentsOf: unrelated) == Data("untouched".utf8))
        // A partial cleanup remains guarded instead of deleting its last marker.
        try Data("required\n".utf8).write(to: bundle.requiredSnapshotRestoreURL)
        #expect(throws: (any Error).self) {
            try VMSnapshotStore.consumeRequiredRestore(bundle: bundle)
        }
        #expect(FileManager.default.fileExists(atPath: bundle.requiredSnapshotRestoreURL.path))
    }

    @Test("Snapshot lifecycle failures cannot be treated as a completed pause, resume, or stop")
    func requiresSuccessfulLifecycle() throws {
        for (ok, code): (Bool, Int32) in [(false, 1), (true, 1), (false, 0)] {
            let result = PommeOperationResult(
                title: "Stop", vmName: "fixture", ok: ok, hostExitCode: code, text: "",
                payload: ["error": "Native transition failed"])
            do {
                try PommeApplication.requireSnapshotLifecycleSucceeded(result)
                Issue.record("Failed transition was accepted")
            } catch {
                #expect(error.localizedDescription == "Native transition failed")
            }
        }
        try PommeApplication.requireSnapshotLifecycleSucceeded(.init(
            title: "Stop", vmName: "fixture", ok: true, hostExitCode: 0, text: "", payload: [:]))
    }

    @Test("A helper failure is preserved before checking for its missing artifact")
    func preservesSaveFailure() throws {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try VMSnapshotStore.confirmCapture(
                response: ["ok": false, "error": "Native save failed", "hostExitCode": 1], stage: stage)
            Issue.record("Failed save was accepted")
        } catch {
            #expect(error.localizedDescription == "Native save failed")
        }
    }

    @Test("Only a completed save with a nonempty regular artifact is accepted")
    func requiresArtifactAndReceipt() throws {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-snapshot-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let state = VMSnapshotStore.machineStateURL(in: stage)
        #expect(throws: (any Error).self) {
            try VMSnapshotStore.confirmCapture(response: success, stage: stage)
        }
        try Data().write(to: state)
        #expect(throws: (any Error).self) {
            try VMSnapshotStore.confirmCapture(response: success, stage: stage)
        }
        try Data("synthetic state".utf8).write(to: state)
        try VMSnapshotStore.confirmCapture(response: success, stage: stage)
        for response: [String: Any] in [
            ["ok": true],
            ["ok": true, "operation": "pause", "hostExitCode": 0],
            ["ok": true, "operation": "snapshot-save", "hostExitCode": 1],
            ["ok": 1, "operation": "snapshot-save", "hostExitCode": 0]
        ] {
            #expect(throws: (any Error).self) {
                try VMSnapshotStore.confirmCapture(response: response, stage: stage)
            }
        }
        try FileManager.default.removeItem(at: state)
        let target = stage.appendingPathComponent("target")
        try Data("state".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try VMSnapshotStore.confirmCapture(response: success, stage: stage)
        }
    }
}
