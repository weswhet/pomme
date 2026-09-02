import Foundation
import Testing

@Suite("Snapshot TUI PTY", .serialized)
@MainActor
struct SnapshotTUIPTYTests {
    @Test("Snapshot creation rejects empty input, refreshes without rerunning, and restores the terminal")
    func createsSnapshotAndRefreshesWithoutRerunning() async throws {
        let recorder = SnapshotActionRecorder(records: [])
        let session = try TUITestPTYSession()
        defer { session.close() }

        try session.write("\nvc\nclean\nrqqq")
        try await run(session: session, recorder: recorder)

        #expect(recorder.created == ["clean"])
        #expect(recorder.listRequests >= 2)
        #expect(session.readTranscript().contains("Snapshot name is required."))
        #expect(session.readTranscript().contains("Snapshot clean created."))
        #expect(session.termiosMatchesOriginal)
    }

    @Test("Snapshot deletion requires the exact VM and snapshot confirmation")
    func deleteMismatchDoesNotInvokeMutation() async throws {
        let recorder = SnapshotActionRecorder(records: [record(name: "clean")])
        let session = try TUITestPTYSession()
        defer { session.close() }

        try session.write("\nv\ndwrong\nqqqq")
        try await run(session: session, recorder: recorder)

        #expect(recorder.deleted.isEmpty)
        #expect(session.readTranscript().contains("Confirmation did not match dev/clean."))
        #expect(session.termiosMatchesOriginal)
    }

    @Test("Drifted restore requires explicit drift authorization and leaves the VM paused")
    func restoreWithDriftForwardsAuthorization() async throws {
        let recorder = SnapshotActionRecorder(records: [record(name: "clean", drift: ["disk"])])
        let session = try TUITestPTYSession()
        defer { session.close() }

        try session.write("\nv\nrydev/clean\nrqqq")
        try await run(session: session, recorder: recorder)

        #expect(recorder.restored == [.init(name: "clean", allowDrift: true)])
        let transcript = session.readTranscript()
        #expect(transcript.contains("Snapshot drift detected:"))
        #expect(transcript.contains("Disk.img and AuxiliaryStorage are not copied or replaced."))
        #expect(transcript.contains("inconsistent guest-visible filesystem state."))
        #expect(transcript.contains("VM is paused."))
        #expect(session.termiosMatchesOriginal)
    }

    private func run(session: TUITestPTYSession, recorder: SnapshotActionRecorder) async throws {
        let entries = [vmEntry()]
        var tui = PommeTUI(
            initialVMName: nil,
            terminal: session.terminal,
            createAction: { _, _, _, _, _ in
                PommeOperationResult(title: "Create VM", vmName: nil, ok: true, hostExitCode: 0, text: "OK", payload: [:])
            },
            vmListAction: { entries },
            snapshotListAction: { _ in recorder.list() },
            snapshotCreateAction: { _, snapshot in recorder.create(snapshot) },
            snapshotRestoreAction: { _, snapshot, allowDrift in recorder.restore(snapshot, allowDrift: allowDrift) },
            snapshotDeleteAction: { _, snapshot in recorder.delete(snapshot) }
        )
        try await tui.run()
    }

    private func vmEntry() -> TUIVMEntry {
        TUIVMEntry(payload: [
            "name": "dev",
            "bundlePath": "/tmp/dev.macvm",
            "running": true,
            "vmState": "running",
            "bootMode": "normal",
            "guestAgent": [
                "connection": "connected",
                "role": "normal",
                "protocolVersion": "3",
                "digest": "test-digest",
                "capabilities": ["snapshots"],
                "updateState": "current"
            ]
        ])!
    }

    private func record(name: String, drift: [String] = []) -> VMSnapshotRecord {
        VMSnapshotRecord(
            name: name,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceState: "paused",
            drift: drift,
            machineStateBytes: 1_024,
            diskBytes: 2_048,
            auxiliaryStorageBytes: 512
        )
    }
}

private struct RestoreRequest: Equatable {
    let name: String
    let allowDrift: Bool
}

private final class SnapshotActionRecorder: @unchecked Sendable {
    private var records: [VMSnapshotRecord]
    private(set) var listRequests = 0
    private(set) var created: [String] = []
    private(set) var restored: [RestoreRequest] = []
    private(set) var deleted: [String] = []

    init(records: [VMSnapshotRecord]) {
        self.records = records
    }

    func list() -> [VMSnapshotRecord] {
        listRequests += 1
        return records
    }

    func create(_ name: String) -> PommeOperationResult {
        created.append(name)
        records.append(
            VMSnapshotRecord(
                name: name,
                createdAt: Date(),
                sourceState: "running",
                drift: [],
                machineStateBytes: 1_024,
                diskBytes: 2_048,
                auxiliaryStorageBytes: 512
            )
        )
        return result(title: "Snapshot Create", text: "Created snapshot \(name).")
    }

    func restore(_ name: String, allowDrift: Bool) -> PommeOperationResult {
        restored.append(.init(name: name, allowDrift: allowDrift))
        return result(title: "Snapshot Restore", text: "Restored snapshot \(name); VM is paused.")
    }

    func delete(_ name: String) -> PommeOperationResult {
        deleted.append(name)
        records.removeAll { $0.name == name }
        return result(title: "Snapshot Delete", text: "Deleted snapshot \(name).")
    }

    private func result(title: String, text: String) -> PommeOperationResult {
        PommeOperationResult(title: title, vmName: "dev", ok: true, hostExitCode: 0, text: text, payload: [:])
    }
}
