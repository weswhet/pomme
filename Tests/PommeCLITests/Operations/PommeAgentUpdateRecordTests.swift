import Foundation
import Testing

@Suite("Agent update record")
struct PommeAgentUpdateRecordTests {
    private let original = String(repeating: "a", count: 64)
    private let updated = String(repeating: "b", count: 64)
    private let key = Data(repeating: 7, count: 32)

    private func plan(uuid: UUID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!) throws -> PommeProvisioningPlan {
        let descriptor = try PommeRecoveryProfileSelector.descriptor(version: "26.6.2", build: "25G83")
        return try PommeProvisioningPlan(
            vm: .init(name: "pomme-agent-update", uuid: uuid, bundlePath: "/tmp/pomme-agent-update.bundle"),
            restore: .init(version: "26.6.2", build: "25G83", restoreImageDigest: original),
            display: .required,
            profile: try .init(descriptor: descriptor),
            normalAgent: try .init(identifier: "com.github.weswhet.pomme.agent", executableDigest: original, role: .normal),
            recoveryAgent: try .init(identifier: "com.github.weswhet.pomme.recovery", executableDigest: original, role: .recovery),
            finalState: .stopped
        )
    }

    @Test func verifiedRecordSupersedesTheCreationPin() throws {
        let plan = try plan()
        let record = try PommeAgentUpdateRecord.make(
            plan: plan, previousExecutableDigest: original, executableDigest: updated, key: key)
        #expect(try record.verifiedDigest(plan: plan, key: key) == updated)
    }

    @Test func rejectsOtherVMOtherKeyAndTampering() throws {
        let plan = try plan()
        let record = try PommeAgentUpdateRecord.make(
            plan: plan, previousExecutableDigest: original, executableDigest: updated, key: key)
        #expect(throws: (any Error).self) { try record.verifiedDigest(plan: self.plan(uuid: UUID()), key: key) }
        #expect(throws: (any Error).self) { try record.verifiedDigest(plan: plan, key: Data(repeating: 8, count: 32)) }
        let forged = PommeAgentUpdateRecord(
            unsigned: .init(schema: 1, vmUUID: plan.vm.uuid, planDigest: plan.digest,
                            previousExecutableDigest: original, executableDigest: String(repeating: "c", count: 64),
                            updatedAt: record.unsigned.updatedAt),
            integrity: record.integrity)
        #expect(throws: (any Error).self) { try forged.verifiedDigest(plan: plan, key: key) }
    }

    @Test func storesPrivatelyAndLoadsBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-agent-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(PommeAgentUpdateRecord.fileName)
        #expect(try PommeAgentUpdateRecord.load(at: url) == nil)
        let record = try PommeAgentUpdateRecord.make(
            plan: plan(), previousExecutableDigest: original, executableDigest: updated, key: key)
        try record.write(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try PommeAgentUpdateRecord.load(at: url) == record)
    }
}
