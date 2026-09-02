import ArgumentParser
import Darwin
import Foundation

/// Manages named saved-state snapshots for a managed VM.
struct SnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Manage named VM saved-state snapshots.",
        subcommands: [
            SnapshotCreateCommand.self,
            SnapshotListCommand.self,
            SnapshotRestoreCommand.self,
            SnapshotDeleteCommand.self
        ]
    )
}

/// Creates a named saved-state snapshot.
struct SnapshotCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a named saved-state snapshot."
    )

    @Argument(help: "VM name. Uses POMME_VM_NAME when omitted.")
    var vm: String?

    @Argument(help: "Snapshot name.")
    var snapshot: String?

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        _ = try SnapshotCommandInput.resolve(vm: vm, snapshot: snapshot, action: "create")
    }

    mutating func run() async throws {
        let input = try SnapshotCommandInput.resolve(vm: vm, snapshot: snapshot, action: "create")
        try CLIOutputWriter.write(
            try PommeApplication.snapshotCreate(name: input.vm, snapshot: input.snapshot),
            options: output
        )
    }
}

/// Lists saved-state snapshots for one VM.
struct SnapshotListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List saved-state snapshots for a VM."
    )

    @Argument(help: "VM name. Uses POMME_VM_NAME when omitted.")
    var vm: String?

    @OptionGroup var output: GlobalOptions

    mutating func run() async throws {
        let target = try VMTargetResolver.names(from: vm.map { [$0] } ?? [], allowMultiple: false)[0]
        let snapshots = try PommeApplication.snapshotsList(name: target)
            .sorted { $0.createdAt > $1.createdAt }
        try SnapshotOutput.writeList(vm: target, snapshots: snapshots, options: output)
    }
}

/// Restores a named saved-state snapshot after explicit acknowledgement.
struct SnapshotRestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a named saved-state snapshot."
    )

    @Argument(help: "VM name. Uses POMME_VM_NAME when omitted.")
    var vm: String?

    @Argument(help: "Snapshot name.")
    var snapshot: String?

    @Flag(
        name: .customLong("force"),
        help: "Restore without prompting and accept recorded drift; old machine state may expose inconsistent guest filesystems."
    )
    var force = false

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        _ = try SnapshotCommandInput.resolve(vm: vm, snapshot: snapshot, action: "restore")
    }

    mutating func run() async throws {
        let input = try SnapshotCommandInput.resolve(vm: vm, snapshot: snapshot, action: "restore")
        let record = try PommeApplication.snapshotsList(name: input.vm)
            .first { $0.name == input.snapshot }
        let allowDrift = try SnapshotConfirmation.confirmRestore(
            vm: input.vm,
            snapshot: input.snapshot,
            drift: record?.drift ?? [],
            force: force
        )
        try CLIOutputWriter.write(
            try PommeApplication.snapshotRestore(
                name: input.vm,
                snapshot: input.snapshot,
                allowDrift: allowDrift
            ),
            options: output
        )
    }
}

/// Deletes one named saved-state snapshot.
struct SnapshotDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a named saved-state snapshot."
    )

    @Argument(help: "VM name. Uses POMME_VM_NAME when omitted.")
    var vm: String?

    @Argument(help: "Snapshot name.")
    var snapshot: String?

    @Flag(name: .customLong("force"), help: "Delete without prompting.")
    var force = false

    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        _ = try SnapshotCommandInput.resolve(vm: vm, snapshot: snapshot, action: "delete")
    }

    mutating func run() async throws {
        let input = try SnapshotCommandInput.resolve(vm: vm, snapshot: snapshot, action: "delete")
        try SnapshotConfirmation.confirmDeletion(vm: input.vm, snapshot: input.snapshot, force: force)
        try CLIOutputWriter.write(
            try PommeApplication.snapshotDelete(name: input.vm, snapshot: input.snapshot),
            options: output
        )
    }
}

enum SnapshotCommandInput {
    struct Resolved: Equatable {
        let vm: String
        let snapshot: String
    }

    static func resolve(vm: String?, snapshot: String?, action: String) throws -> Resolved {
        let target: String
        let snapshotName: String
        if let snapshot {
            target = try VMTargetResolver.names(from: vm.map { [$0] } ?? [], allowMultiple: false)[0]
            snapshotName = snapshot
        } else if let vm {
            target = try VMTargetResolver.names(from: [], allowMultiple: false)[0]
            snapshotName = vm
        } else {
            throw ValidationError("Snapshot \(action) requires a snapshot name.")
        }

        return Resolved(vm: target, snapshot: try validateVMName(snapshotName))
    }
}

private enum SnapshotConfirmation {
    static func confirmRestore(vm: String, snapshot: String, drift: [String], force: Bool) throws -> Bool {
        if !drift.isEmpty {
            fputs(
                "Warning: snapshot '\(snapshot)' for VM '\(vm)' has recorded drift: \(drift.joined(separator: ", ")). Restore stores machine state only; Disk.img and AuxiliaryStorage are not copied or replaced. Backing-file drift may expose stale or inconsistent guest-visible filesystem state. --force acknowledges this risk, but VM identity/configuration drift is still rejected.\n",
                stderr
            )
        }
        guard !force else {
            return true
        }
        guard isatty(STDIN_FILENO) == 1 else {
            throw ValidationError("Restore requires an interactive terminal. Pass --force to restore without prompting and accept recorded drift; old machine state may expose inconsistent guest filesystems.")
        }

        fputs(
            "Restore snapshot '\(snapshot)' for VM '\(vm)'? This restores machine state only; Disk.img and AuxiliaryStorage are not copied or replaced. The VM will be paused. [y/N] ",
            stderr
        )
        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              response == "y" || response == "yes"
        else {
            throw CleanExit.message("Restore cancelled.")
        }
        return !drift.isEmpty
    }

    static func confirmDeletion(vm: String, snapshot: String, force: Bool) throws {
        guard !force else {
            return
        }
        guard isatty(STDIN_FILENO) == 1 else {
            throw ValidationError("Deletion requires an interactive terminal. Pass --force to delete without prompting.")
        }

        fputs("Delete snapshot '\(snapshot)' for VM '\(vm)'? This cannot be undone. [y/N] ", stderr)
        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              response == "y" || response == "yes"
        else {
            throw CleanExit.message("Deletion cancelled.")
        }
    }
}

enum SnapshotOutput {
    static func writeList(vm: String, snapshots: [VMSnapshotRecord], options: GlobalOptions) throws {
        let listPayload: [String: Any] = [
            "ok": true,
            "name": vm,
            "snapshots": snapshots.map(payload(for:))
        ]

        try CLIOutputWriter.write(payload: listPayload, text: table(vm: vm, snapshots: snapshots), options: options)
    }

    static func payload(for snapshot: VMSnapshotRecord) -> [String: Any] {
        [
            "name": snapshot.name,
            "createdAt": snapshotTimestamp(snapshot.createdAt),
            "sourceState": snapshot.sourceState,
            "drift": snapshot.drift,
            "machineStateBytes": snapshot.machineStateBytes,
            "diskBytes": snapshot.diskBytes,
            "auxiliaryStorageBytes": snapshot.auxiliaryStorageBytes
        ]
    }

    static func table(vm: String, snapshots: [VMSnapshotRecord]) -> String {
        let heading = "SNAPSHOT\tCREATED\tSOURCE STATE\tDRIFT\tMACHINE STATE\tDISK REFERENCE\tAUXILIARY REFERENCE"
        let rows = snapshots.map { snapshot in
            [
                snapshot.name,
                snapshotTimestamp(snapshot.createdAt),
                snapshot.sourceState,
                snapshot.drift.isEmpty ? "-" : snapshot.drift.joined(separator: ","),
                String(snapshot.machineStateBytes),
                String(snapshot.diskBytes),
                String(snapshot.auxiliaryStorageBytes)
            ].joined(separator: "\t")
        }
        return ([heading] + rows).joined(separator: "\n")
    }

}

private func snapshotTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
