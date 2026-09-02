import Darwin
import Foundation
import Testing

@Suite("State-only VM snapshot store")
struct VMSnapshotStoreTests {
    @Test("A completed snapshot has exactly the two state-only artifacts and owner-only metadata")
    func stateOnlyLayoutAndPermissions() throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }

        let record = try fixture.publish("before-upgrade", state: "machine-state")
        let snapshot = try VMSnapshotStore.snapshotURL(bundle: fixture.bundle, name: record.name)
        let names = try FileManager.default.contentsOfDirectory(atPath: snapshot.path)
        let snapshotAttributes = try FileManager.default.attributesOfItem(atPath: snapshot.path)
        let manifestAttributes = try FileManager.default.attributesOfItem(
            atPath: snapshot.appendingPathComponent(VMSnapshotStore.manifestName).path
        )
        let stateAttributes = try FileManager.default.attributesOfItem(
            atPath: VMSnapshotStore.machineStateURL(in: snapshot).path
        )

        #expect(Set(names) == [VMSnapshotStore.machineStateName, VMSnapshotStore.manifestName])
        #expect(try Data(contentsOf: VMSnapshotStore.machineStateURL(in: snapshot)) == Data("machine-state".utf8))
        #expect(((snapshotAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o700)
        #expect((snapshotAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
        #expect(((manifestAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o600)
        #expect((manifestAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
        #expect(((stateAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o600)
        #expect((stateAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())

        // Mutable backing files stay in the bundle; their absence from the
        // two-file snapshot is the state-only contract.
        #expect(!names.contains(fixture.bundle.diskImageURL.lastPathComponent))
        #expect(!names.contains(fixture.bundle.auxiliaryStorageURL.lastPathComponent))
        #expect(try Data(contentsOf: fixture.bundle.diskImageURL) == Data("disk".utf8))
        #expect(try Data(contentsOf: fixture.bundle.auxiliaryStorageURL) == Data("auxiliary".utf8))
    }

    @Test("Helper save targets are generated direct stages and never arbitrary host paths")
    func confinesHelperSaveTarget() throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }

        let stage = try VMSnapshotStore.prepare(bundle: fixture.bundle, name: "confined")
        let target = try VMSnapshotStore.writableMachineStateURL(
            bundle: fixture.bundle,
            stageName: stage.lastPathComponent
        )
        #expect(target == VMSnapshotStore.machineStateURL(in: stage))

        try fixture.writeState("already-written", to: stage)
        #expect(throws: Error.self) {
            try VMSnapshotStore.writableMachineStateURL(bundle: fixture.bundle, stageName: stage.lastPathComponent)
        }
        #expect(throws: Error.self) {
            try VMSnapshotStore.writableMachineStateURL(bundle: fixture.bundle, stageName: "../outside")
        }
        #expect(throws: Error.self) {
            try VMSnapshotStore.writableMachineStateURL(
                bundle: fixture.bundle,
                stageName: "\(VMSnapshotStore.stagePrefix)missing"
            )
        }

        let external = fixture.root.appendingPathComponent("external-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let linkedStage = fixture.bundle.snapshotsURL.appendingPathComponent(
            "\(VMSnapshotStore.stagePrefix)linked",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: linkedStage, withDestinationURL: external)
        #expect(throws: Error.self) {
            try VMSnapshotStore.writableMachineStateURL(bundle: fixture.bundle, stageName: linkedStage.lastPathComponent)
        }
    }

    @Test("Required restore staging is fail-closed and owner-only")
    func requiredRestoreStaging() throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }

        try fixture.publish("restore-me", state: "saved-state")
        try VMSnapshotStore.installMachineState(bundle: fixture.bundle, name: "restore-me")

        #expect(FileManager.default.fileExists(atPath: fixture.bundle.requiredSnapshotRestoreURL.path))
        #expect(try Data(contentsOf: fixture.bundle.saveStateURL) == Data("saved-state".utf8))
        for url in [fixture.bundle.requiredSnapshotRestoreURL, fixture.bundle.saveStateURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o600)
        }
        #expect(throws: Error.self) {
            try VMSnapshotStore.installMachineState(bundle: fixture.bundle, name: "restore-me")
        }

        try VMSnapshotStore.removeRequiredRestoreArtifacts(bundle: fixture.bundle)
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.requiredSnapshotRestoreURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.saveStateURL.path))
    }

    @Test("Names cannot escape the snapshot root and publication never overwrites")
    func rejectsTraversalAndOverwrite() throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }

        for unsafeName in ["", ".hidden", "../outside", "before/upgrade", "before upgrade"] {
            #expect(throws: Error.self) { try VMSnapshotStore.snapshotURL(bundle: fixture.bundle, name: unsafeName) }
            #expect(throws: Error.self) { try VMSnapshotStore.prepare(bundle: fixture.bundle, name: unsafeName) }
        }

        try fixture.publish("first", state: "first-state")
        #expect(throws: Error.self) { try VMSnapshotStore.prepare(bundle: fixture.bundle, name: "first") }

        let secondStage = try VMSnapshotStore.prepare(bundle: fixture.bundle, name: "second")
        try fixture.writeState("second-state", to: secondStage)
        #expect(throws: Error.self) {
            try VMSnapshotStore.complete(bundle: fixture.bundle, name: "first", stage: secondStage, sourceState: "paused")
        }
        let first = try VMSnapshotStore.snapshotURL(bundle: fixture.bundle, name: "first")
        #expect(try Data(contentsOf: VMSnapshotStore.machineStateURL(in: first)) == Data("first-state".utf8))
        #expect(FileManager.default.fileExists(atPath: secondStage.path))
    }

    @Test("Listing is newest first and deliberately does not hash saved machine state")
    func listsNewestFirstWithoutFullStateValidation() throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }

        try fixture.publish("older", state: "old")
        try fixture.publish("newer", state: "new")
        try fixture.setCreatedAt("older", to: "2025-01-01T00:00:00Z")
        try fixture.setCreatedAt("newer", to: "2025-01-02T00:00:00Z")
        let newer = try VMSnapshotStore.snapshotURL(bundle: fixture.bundle, name: "newer")
        try Data("tampered-state".utf8).write(to: VMSnapshotStore.machineStateURL(in: newer), options: .atomic)

        let listed = try VMSnapshotStore.list(bundle: fixture.bundle)
        #expect(listed.map(\.name) == ["newer", "older"])
        #expect(listed.first?.drift.isEmpty == true)

        // Listing is intentionally lightweight, but the manifest verification
        // used by restore preflight must fail closed for a tampered state file.
        #expect(throws: Error.self) { try VMSnapshotStore.manifest(bundle: fixture.bundle, name: "newer") }
    }

    @Test("Drift identifies configuration and VM identity changes without hashing backing files")
    func classifiesConfigurationAndIdentityDrift() throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }

        try fixture.publish("baseline", state: "state")
        let manifest = try VMSnapshotStore.manifest(bundle: fixture.bundle, name: "baseline")
        try fixture.writeMetadata(uuid: "22222222-2222-2222-2222-222222222222")

        #expect(try VMSnapshotStore.drift(bundle: fixture.bundle, manifest: manifest) == ["vmUUID"])
    }

    @Test("Unsafe snapshot links fail closed and delete leaves no visible or tombstone artifact")
    func rejectsUnsafeLinksAndDeletesThroughTombstone() throws {
        let fixture = try SnapshotFixture()
        defer { fixture.remove() }
        let external = fixture.root.appendingPathComponent("external-state")
        try Data("outside".utf8).write(to: external)

        try FileManager.default.createSymbolicLink(at: fixture.bundle.snapshotsURL, withDestinationURL: fixture.root)
        #expect(throws: Error.self) { try VMSnapshotStore.prepare(bundle: fixture.bundle, name: "linked-root") }
        try FileManager.default.removeItem(at: fixture.bundle.snapshotsURL)

        try fixture.publish("linked-state", state: "good")
        let linked = try VMSnapshotStore.snapshotURL(bundle: fixture.bundle, name: "linked-state")
        try FileManager.default.removeItem(at: VMSnapshotStore.machineStateURL(in: linked))
        try FileManager.default.createSymbolicLink(
            at: VMSnapshotStore.machineStateURL(in: linked), withDestinationURL: external
        )
        #expect(throws: Error.self) { try VMSnapshotStore.manifest(bundle: fixture.bundle, name: "linked-state") }
        #expect(try Data(contentsOf: external) == Data("outside".utf8))

        try FileManager.default.removeItem(at: linked)
        try fixture.publish("delete-me", state: "delete-state")
        try VMSnapshotStore.delete(bundle: fixture.bundle, name: "delete-me")
        #expect(!FileManager.default.fileExists(atPath: try VMSnapshotStore.snapshotURL(bundle: fixture.bundle, name: "delete-me").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.bundle.snapshotsURL.path)
            .allSatisfy { !$0.hasPrefix(VMSnapshotStore.tombstonePrefix) })
    }
}

private final class SnapshotFixture {
    let root: URL
    let bundle: BundleLayout

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-snapshot-store-\(UUID().uuidString)", isDirectory: true)
        bundle = BundleLayout(rootURL: root.appendingPathComponent("fixture.bundle", isDirectory: true))
        try FileManager.default.createDirectory(at: bundle.rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeMetadata(uuid: "11111111-1111-1111-1111-111111111111")
        for (url, data) in [
            (bundle.diskImageURL, Data("disk".utf8)),
            (bundle.auxiliaryStorageURL, Data("auxiliary".utf8)),
            (bundle.hardwareModelURL, Data("hardware".utf8)),
            (bundle.machineIdentifierURL, Data("identifier".utf8))
        ] {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func publish(_ name: String, state: String) throws -> VMSnapshotRecord {
        let stage = try VMSnapshotStore.prepare(bundle: bundle, name: name)
        try writeState(state, to: stage)
        return try VMSnapshotStore.complete(bundle: bundle, name: name, stage: stage, sourceState: "paused")
    }

    func writeState(_ value: String, to directory: URL) throws {
        let url = VMSnapshotStore.machineStateURL(in: directory)
        try Data(value.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func writeMetadata(uuid: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [Constants.vmUUIDMetadataKey: uuid], options: [.sortedKeys])
        try data.write(to: bundle.metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.metadataURL.path)
    }

    func setCreatedAt(_ name: String, to value: String) throws {
        let snapshot = try VMSnapshotStore.snapshotURL(bundle: bundle, name: name)
        let manifestURL = snapshot.appendingPathComponent(VMSnapshotStore.manifestName)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var record = try #require(object["record"] as? [String: Any])
        record["createdAt"] = value
        object["record"] = record
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
