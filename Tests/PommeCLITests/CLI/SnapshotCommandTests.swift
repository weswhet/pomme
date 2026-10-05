import ArgumentParser
import Foundation
import Testing

@Suite("Named saved-state snapshot commands")
struct SnapshotCommandTests {
    @Test("Snapshot is public and exposes only its four actions")
    func publicCommandVocabulary() {
        let rootHelp = PommeCLI.helpMessage()
        let snapshotHelp = SnapshotCommand.helpMessage()

        #expect(rootHelp.contains("snapshot"))
        #expect(snapshotHelp.contains("create"))
        #expect(snapshotHelp.contains("list"))
        #expect(snapshotHelp.contains("restore"))
        #expect(snapshotHelp.contains("delete"))
        #expect(!snapshotHelp.contains("overwrite"))
    }

    @Test("Create, restore, and delete parse the documented explicit targets")
    func explicitTargetSyntax() throws {
        var create = try SnapshotCreateCommand.parse(["dev", "--snapshot", "before-upgrade", "--json"])
        var restore = try SnapshotRestoreCommand.parse(["dev", "--snapshot", "before-upgrade", "--force"])
        var delete = try SnapshotDeleteCommand.parse(["--snapshot", "before-upgrade", "dev", "--format", "jsonl"])

        try create.validate()
        try restore.validate()
        try delete.validate()

        #expect(create.vm == "dev")
        #expect(create.snapshot == "before-upgrade")
        #expect(create.output.json)
        #expect(restore.force)
        #expect(delete.force == false)
        #expect(delete.output.format == .jsonl)
    }

    @Test("Mutation commands require --snapshot, including in the old positional form", arguments: [
        SnapshotCreateCommand.self as ParsableCommand.Type,
        SnapshotRestoreCommand.self,
        SnapshotDeleteCommand.self
    ])
    func mutationCommandsRequireSnapshotName(_ command: ParsableCommand.Type) {
        for arguments in [["dev"], ["dev", "before-upgrade"]] {
            do {
                _ = try command.parse(arguments)
                Issue.record("\(command._commandName) accepted \(arguments) without --snapshot.")
            } catch {
                #expect(command.fullMessage(for: error).contains("Missing expected argument '--snapshot <name>'"))
            }
        }
    }

    @Test("The snapshot name is not a second positional value", arguments: [
        SnapshotCreateCommand.self as ParsableCommand.Type,
        SnapshotRestoreCommand.self,
        SnapshotDeleteCommand.self
    ])
    func positionalSnapshotIsRejected(_ command: ParsableCommand.Type) {
        do {
            _ = try command.parse(["dev", "before-upgrade", "--snapshot", "before-upgrade"])
            Issue.record("\(command._commandName) accepted a positional snapshot name.")
        } catch {
            #expect(command.fullMessage(for: error).contains("Unexpected argument 'before-upgrade'"))
        }
    }

    @Test("Snapshot names use the managed-name validator")
    func snapshotNameValidation() {
        #expect(throws: Error.self) {
            try SnapshotCommandInput.resolve(vm: "dev", snapshot: "")
        }
        do {
            _ = try SnapshotCommandInput.resolve(vm: "dev", snapshot: "before/upgrade")
            Issue.record("An invalid snapshot name was accepted.")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Invalid snapshot name before/upgrade."))
        }
    }

    @Test("Snapshot list output is newest first and preserves structured fields")
    func listPresentation() {
        let older = VMSnapshotRecord(
            name: "older",
            createdAt: Date(timeIntervalSince1970: 1),
            sourceState: "paused",
            drift: [],
            machineStateBytes: 10,
            diskBytes: 20,
            auxiliaryStorageBytes: 30
        )
        let newer = VMSnapshotRecord(
            name: "newer",
            createdAt: Date(timeIntervalSince1970: 2),
            sourceState: "paused",
            drift: ["hardwareModel"],
            machineStateBytes: 40,
            diskBytes: 50,
            auxiliaryStorageBytes: 60
        )

        let text = SnapshotOutput.table(vm: "dev", snapshots: [newer, older])
        let payload = SnapshotOutput.payload(for: newer)

        #expect(text.contains("SNAPSHOT\tCREATED"))
        #expect(text.contains("DISK REFERENCE"))
        #expect(text.range(of: "newer")!.lowerBound < text.range(of: "older")!.lowerBound)
        #expect(payload["name"] as? String == "newer")
        #expect(payload["drift"] as? [String] == ["hardwareModel"])
        #expect(payload["machineStateBytes"] as? Int64 == 40)
    }
}
