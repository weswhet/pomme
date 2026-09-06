import Foundation
import Testing

@Suite("PommeCore Recovery provisioning")
struct PommeCoreRecoveryProvisioningTests {
    @Test("experimental Recovery evidence preserves the new OS identity", arguments: [
        ("26.6.2", "25G83"), ("27.0.0", "26A5351b")
    ])
    func experimentalRecoveryEvidence(version: String, build: String) throws {
        let descriptor = try PommeRecoveryProfileSelector.descriptor(version: version, build: build)
        let digest = String(repeating: "a", count: 64)
        let plan = try PommeProvisioningPlan(
            vm: .init(
                name: "pomme-experimental-evidence",
                uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
                bundlePath: "/tmp/pomme-experimental-evidence.bundle"
            ),
            restore: .init(version: version, build: build, restoreImageDigest: digest),
            display: .required,
            profile: try .init(descriptor: descriptor),
            normalAgent: try .init(identifier: "com.github.weswhet.pomme.agent", executableDigest: digest, role: .normal),
            recoveryAgent: try .init(identifier: "com.github.weswhet.pomme.recovery", executableDigest: digest, role: .recovery),
            finalState: .stopped
        )

        let evidence = try PommeCore.recoveryProfileEvidence(for: plan)

        #expect(evidence.build == .experimental(version: version, build: build))
        #expect(evidence.manifestHash == .experimentalProfile(descriptor.digest))
        #expect(throws: PommeRecoveryInputQualificationError.self) {
            _ = try PommeRecoveryProfileSelector.reviewedDescriptor(for: evidence)
        }
    }

    @Test("normal-agent provisioning requires granular Pomme operations")
    func provisioningAgentCapabilityPolicy() {
        #expect(PommeCore.supportsProvisioningAgentCapabilities([
            "agent.describe",
            "process.start",
            "file.open",
            "mdm.enrollment",
            "maintenance",
            "maintenance.update.begin"
        ]))
        #expect(!PommeCore.supportsProvisioningAgentCapabilities([
            "process",
            "file",
            "stream",
            "maintenance"
        ]))
        #expect(!PommeCore.supportsProvisioningAgentCapabilities([
            "process.start",
            "file.open",
            "maintenance"
        ]))
    }

    @Test("normal AMFI forwarding strips only the host digest marker")
    func normalAMFIForwardingIsClosed() throws {
        let digest = String(repeating: "a", count: 64)
        let volumeGroupUUID = "11111111-2222-3333-4444-555555555555"
        let payload = JSONValue.object([
            PommeSecurityNormalAgent.normalAMFIDigestMarker: .string(digest),
            "volumeGroupUUID": .string(volumeGroupUUID),
        ])

        let forwarded = try PommeCore.normalAMFIForwardPayload(
            operation: "amfi.normal.disable",
            payload: payload,
            expectedExecutableDigest: digest
        )
        #expect(forwarded == .object([
            "volumeGroupUUID": .string(volumeGroupUUID),
        ]))

        var extra = payload.objectValue!
        extra["unexpected"] = .string("rejected")
        #expect(throws: PommeSecurityNormalAgentError.self) {
            _ = try PommeCore.normalAMFIForwardPayload(
                operation: "amfi.normal.disable",
                payload: .object(extra),
                expectedExecutableDigest: digest
            )
        }

        var wrongMarker = payload.objectValue!
        wrongMarker[PommeSecurityNormalAgent.normalAMFIDigestMarker] =
            .string(String(repeating: "b", count: 64))
        #expect(throws: PommeSecurityNormalAgentError.self) {
            _ = try PommeCore.normalAMFIForwardPayload(
                operation: "amfi.normal.disable",
                payload: .object(wrongMarker),
                expectedExecutableDigest: digest
            )
        }

        #expect(throws: PommeSecurityNormalAgentError.self) {
            _ = try PommeCore.normalAMFIForwardPayload(
                operation: "amfi.disable",
                payload: payload,
                expectedExecutableDigest: digest
            )
        }
    }

    @Test("normal AMFI capability receipt is pinned and strictly typed")
    func normalAMFICapabilityReceiptIsStrict() {
        let digest = String(repeating: "a", count: 64)
        let description = JSONValue.object([
            "role": .string("persistent"),
            "protocol": .string(PommeAgentProtocol.name),
            "version": .integer(Int64(PommeAgentProtocol.version)),
            "executableSHA256": .string(digest),
            "normalAMFIWorkflowVersion": .integer(
                Int64(PommeSecurityNormalAgent.normalAMFIWorkflowVersion)
            ),
            "capabilities": .array(
                PommeSecurityNormalAgent.normalAMFIOperations.map(JSONValue.string)
            ),
        ])
        #expect(PommeCore.normalAMFICapabilityReceipt(
            description, expectedExecutableDigest: digest))

        var old = description.objectValue!
        old.removeValue(forKey: "normalAMFIWorkflowVersion")
        #expect(!PommeCore.normalAMFICapabilityReceipt(
            .object(old), expectedExecutableDigest: digest))

        var coerced = description.objectValue!
        coerced["version"] = .string("1")
        #expect(!PommeCore.normalAMFICapabilityReceipt(
            .object(coerced), expectedExecutableDigest: digest))

        var malformedCapabilities = description.objectValue!
        malformedCapabilities["capabilities"] = .array([
            .string("amfi.normal.disable"), .bool(true),
        ])
        #expect(!PommeCore.normalAMFICapabilityReceipt(
            .object(malformedCapabilities), expectedExecutableDigest: digest))
    }

    @Test("previous resolves the captured stopped state")
    func previousStoppedState() throws {
        let state = try PommeCore.capturedProvisioningFinalState(from: [
            "helperRunning": false,
            "vmState": "stopped",
            "bootMode": "none"
        ])
        #expect(state == .stopped)
    }

    @Test("previous resolves the captured normal or Recovery state")
    func previousRunningState() throws {
        let normal = try PommeCore.capturedProvisioningFinalState(from: [
            "helperRunning": true,
            "vmState": "running",
            "bootMode": "normal"
        ])
        let recovery = try PommeCore.capturedProvisioningFinalState(from: [
            "helperRunning": true,
            "vmState": "running",
            "bootMode": "recovery"
        ])
        #expect(normal == .normalRunning)
        #expect(recovery == .recoveryRunning)
    }

    @Test("previous rejects transient and paused states instead of changing them")
    func previousRejectsUnstableState() {
        for vmState in ["starting", "paused", "error"] {
            #expect(throws: RunnerError.self) {
                _ = try PommeCore.capturedProvisioningFinalState(from: [
                    "helperRunning": true,
                    "vmState": vmState,
                    "bootMode": "normal"
                ])
            }
        }
    }

    @Test("provisioning runtime metadata carries identity without a credential")
    func runtimeMetadataIsNonSecret() throws {
        let vmUUID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let groupUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let metadata = PommeProvisioningRuntimeMetadata(
            vmUUID: vmUUID,
            startupVolumeGroupUUID: groupUUID
        )
        #expect(metadata.vmUUID == vmUUID)
        #expect(metadata.startupVolumeGroupUUID == groupUUID)
        let encoded = try PommeProvisioningCoding.encode(metadata)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.localizedCaseInsensitiveContains("secret"))
        #expect(!text.localizedCaseInsensitiveContains("token"))
    }

    @Test("provisioning input contains only a non-secret credential reference")
    func provisioningInputOmitsSecret() throws {
        let input = PommeProvisioningInput(
            restoreImagePath: "/tmp/restore.ipsw",
            memorySizeBytes: 8 * 1024 * 1024 * 1024,
            diskSizeBytes: 60 * 1024 * 1024 * 1024,
            hardwareModelData: Data([1, 2, 3]),
            machineIdentifierData: Data([4, 5, 6]),
            agentCredentialAccount: "agent-token"
        )
        let encoded = try PommeProvisioningCoding.encode(input)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("agentCredentialAccount"))
        #expect(!text.contains("agentSecret"))
        #expect(!text.contains("persistentToken"))
        #expect(!text.contains(String(repeating: "a", count: 64)))
    }

    @Test("provisioning journal contains no credential reference or secret")
    func provisioningJournalOmitsCredential() throws {
        let digest = String(repeating: "a", count: 64)
        let plan = try PommeProvisioningPlan(
            vm: .init(
                name: "pomme-journal-test",
                uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
                bundlePath: "/tmp/pomme-journal-test.macvm"
            ),
            restore: .init(version: "26.6.0", build: "25G72", restoreImageDigest: digest),
            display: .required,
            profile: .tahoe,
            normalAgent: try .init(
                identifier: "com.github.weswhet.pomme.agent",
                executableDigest: digest,
                role: .normal
            ),
            recoveryAgent: try .init(
                identifier: "com.github.weswhet.pomme.recovery",
                executableDigest: digest,
                role: .recovery
            ),
            finalState: .stopped
        )
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 7, count: 32))
        let journal = try signer.make(generation: 1, plan: plan, events: [])
        let text = String(decoding: try PommeProvisioningCoding.encode(journal), as: UTF8.self)
        #expect(!text.contains("agentSecret"))
        #expect(!text.contains("agentCredentialAccount"))
        #expect(!text.contains("agent-token"))
    }

    @Test("startup volume-group metadata is optional, immutable, and idempotent")
    func startupVolumeGroupPersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-core-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let vmUUID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let groupUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let plan = try PommeProvisioningPlan(
            vm: .init(name: "pomme-runtime-test", uuid: vmUUID, bundlePath: root.path),
            restore: .init(version: "26.6.0", build: "25G72", restoreImageDigest: String(repeating: "a", count: 64)),
            display: .required,
            profile: .tahoe,
            normalAgent: try .init(identifier: "com.github.weswhet.pomme.agent", executableDigest: String(repeating: "a", count: 64), role: .normal),
            recoveryAgent: try .init(identifier: "com.github.weswhet.pomme.recovery", executableDigest: String(repeating: "a", count: 64), role: .recovery),
            finalState: .stopped
        )
        let bundle = BundleLayout(rootURL: root)
        let mismatchedUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        try writeMetadataPayload(
            [Constants.vmUUIDMetadataKey: mismatchedUUID.uuidString.lowercased()],
            bundle: bundle
        )
        let mismatchedMetadata = try Data(contentsOf: bundle.metadataURL)
        #expect(throws: PommeProvisioningError.ownershipMismatch) {
            _ = try PommeCore.provisioningRuntimeMetadata(for: plan)
        }
        // The ownership rejection is metadata-only and must not alter the VM
        // bundle or reach any runtime effect.
        #expect(try Data(contentsOf: bundle.metadataURL) == mismatchedMetadata)

        try writeMetadataPayload([Constants.vmUUIDMetadataKey: vmUUID.uuidString.lowercased()], bundle: bundle)

        #expect(try PommeCore.provisioningRuntimeMetadata(for: plan).startupVolumeGroupUUID == nil)
        try PommeCore.persistProvisioningStartupVolumeGroup(groupUUID, for: plan)
        #expect(try PommeCore.provisioningRuntimeMetadata(for: plan).startupVolumeGroupUUID == groupUUID)
        try PommeCore.persistProvisioningStartupVolumeGroup(groupUUID, for: plan)
        #expect(throws: PommeProvisioningError.self) {
            try PommeCore.persistProvisioningStartupVolumeGroup(UUID(), for: plan)
        }
    }

    @Test("Recovery waits once for a releasing auxiliary-storage lock")
    func waitsForAuxiliaryStorageRelease() async throws {
        let conflicts = ConflictSequence([true, false])
        let sleeps = SleepRecorder()

        try await PommeCore.waitForLiveRecoveryAuxiliaryStorageRelease(
            at: URL(fileURLWithPath: "/tmp/pomme-auxiliary-storage-test"),
            vmName: "dev",
            maxRetries: 1,
            retryDelayNanoseconds: 123,
            hasConflict: { _ in conflicts.next() },
            sleep: { await sleeps.append($0) }
        )

        #expect(conflicts.count == 2)
        #expect(await sleeps.values == [123])
    }

    @Test("Recovery rejects an auxiliary-storage lock beyond the one retry")
    func rejectsPersistentAuxiliaryStorageLock() async {
        let conflicts = ConflictSequence([true, true])

        await #expect(throws: PommeLiveRecoveryIntegration.Error.runtimeRejected) {
            try await PommeCore.waitForLiveRecoveryAuxiliaryStorageRelease(
                at: URL(fileURLWithPath: "/tmp/pomme-auxiliary-storage-test"),
                vmName: "dev",
                maxRetries: 1,
                retryDelayNanoseconds: 0,
                hasConflict: { _ in conflicts.next() },
                sleep: { _ in }
            )
        }
        #expect(conflicts.count == 2)
    }

    @Test("Recovery treats an unknown auxiliary-storage inode as conflicting")
    func rejectsUnknownAuxiliaryStorageState() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-missing-auxiliary-\(UUID().uuidString)")

        #expect(PommeCore.liveRecoveryAuxiliaryStorageHasConflictingLock(missing))
    }
}

private final class ConflictSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]
    private var invocationCount = 0

    init(_ values: [Bool]) { self.values = values }

    func next() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        invocationCount += 1
        return values.isEmpty ? false : values.removeFirst()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount
    }
}

private actor SleepRecorder {
    private(set) var values: [UInt64] = []

    func append(_ value: UInt64) { values.append(value) }
}
