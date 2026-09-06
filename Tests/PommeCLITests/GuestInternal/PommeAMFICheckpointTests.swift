import Foundation
import Darwin
import Testing

@Suite("AMFI durable checkpoints", .serialized)
struct PommeAMFICheckpointTests {
    @Test("Full policy disables to permissive and restores exact effective baseline")
    func fullToPermissiveAndExactRestore() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store)
        let payload = fixture.credentialsPayload
        let baselinePolicy = fixture.policyCanonicalBytes
        let baselineBootArguments = fixture.bootArgumentBytes

        let disabled = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: payload
        )
        #expect(disabled.objectValue?["amfiDisabled"] == .bool(true))
        #expect(disabled.objectValue?["securityMode"] == .string("permissive"))
        #expect(fixture.secretArguments == [["-a", "-v", fixture.groupUUID.uuidString.lowercased()]])
        #expect(fixture.policyGeneration == 2)
        #expect(fixture.policySPih != String(repeating: "B", count: 96))
        #expect(fixture.policyNSih != String(repeating: "F", count: 96))

        let disabledRecord = try store.loadRecord()
        #expect(disabledRecord.phase == .disabledVerified)
        #expect(disabledRecord.policyCheckpoint?.action == .disable)
        #expect(disabledRecord.policyCheckpoint?.generation == 2)
        #expect(disabledRecord.nativeTransition?.receipt == true)
        #expect(disabledRecord.nvramCheckpoint?.receipt == true)
        #expect(disabledRecord.snapshot.localPolicy == baselinePolicy)
        #expect(disabledRecord.snapshot.nvram.value(for: "boot-args")?.present == true)
        #expect(disabledRecord.snapshot.nvram.value(for: "boot-args")?.bytes == baselineBootArguments)
        #expect(fixture.bootArgumentBytes == PommeBootArguments.addingOverride(to: baselineBootArguments))

        let enabled = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: payload
        )
        #expect(enabled.objectValue?["amfiDisabled"] == .bool(false))
        #expect(enabled.objectValue?["securityMode"] == .string("full"))
        #expect(try !store.isPresent())
        #expect(fixture.secretArguments == [
            ["-a", "-v", fixture.groupUUID.uuidString.lowercased()],
            ["-f", "-v", fixture.groupUUID.uuidString.lowercased()]
        ])
        #expect(fixture.bootArgumentBytes == baselineBootArguments)
        #expect(fixture.bootArguments == String(decoding: baselineBootArguments, as: UTF8.self))

        let restoredPolicy = try policyFields(fixture.policyCanonicalBytes)
        let originalPolicy = try policyFields(baselinePolicy)
        let regeneratedAndNonceKeys: Set<String> = [
            "spih", "spih_exists", "nsih", "stng", "stng_exists",
            "lpnh", "os_lpnh"
        ]
        #expect(Set(restoredPolicy.keys) == Set(originalPolicy.keys))
        for key in originalPolicy.keys where !regeneratedAndNonceKeys.contains(key) {
            #expect(restoredPolicy[key] == originalPolicy[key])
        }
        #expect(fixture.policyGeneration == 3)
        #expect(fixture.policySPih != String(repeating: "B", count: 96))
        #expect(fixture.policyNSih != String(repeating: "F", count: 96))
    }

    @Test("A present but empty boot-args value is restored byte for byte")
    func presentEmptyBootArgumentsRestoreExactly() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "full",
            initialBootArgumentBytes: Data()
        )
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )
        let baseline = try store.loadRecord()
        #expect(baseline.snapshot.nvram.value(for: "boot-args")?.present == true)
        #expect(baseline.snapshot.nvram.value(for: "boot-args")?.bytes == Data())

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.credentialsPayload
        )
        #expect(fixture.bootArgumentBytes == Data())
        #expect(fixture.bootArguments.isEmpty)
        #expect(try !store.isPresent())
    }

    @Test("A literal percent sequence in unrelated boot-args is restored exactly")
    func literalPercentBootArgumentsRestoreExactly() throws {
        let original = Data("foo=%20 keep=1".utf8)
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "full",
            initialBootArgumentBytes: original
        )
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )
        #expect(try store.loadRecord().snapshot.nvram.value(for: "boot-args")?.bytes == original)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.credentialsPayload
        )
        #expect(fixture.bootArgumentBytes == original)
        #expect(fixture.bootArguments == "foo=%20 keep=1")
    }

    @Test("A policy receipt resumes through NVRAM without a duplicate policy write")
    func policyReceiptResumesWithoutDuplicatePolicyWrite() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        try fixture.installPolicyReceipt(store: store)
        let operations = fixture.operations(store: store)

        let result = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )

        #expect(result.objectValue?["verified"] == .bool(true))
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 1)
        #expect(PommeBootArguments.containsOverride(fixture.bootArgumentBytes))
        let record = try store.loadRecord()
        #expect(record.phase == .disabledVerified)
        #expect(record.policyCheckpoint?.action == .disable)
        #expect(record.policyCheckpoint?.generation == 2)
        #expect(record.nvramCheckpoint?.receipt == true)

        let status = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(status.objectValue?["baselinePhase"] == .string("disabledVerified"))
        #expect(status.objectValue?["reconciliationRequired"] == .bool(false))

        let repeated = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.credentialsPayload
        )
        #expect(repeated.objectValue?["amfiDisabled"] == .bool(true))
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 1)
        #expect(try store.loadRecord().phase == .disabledVerified)
    }

    @Test("A failed enable rolls back to the disabled target and retries the same command")
    func enableRollbackThenSameCommandRetry() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store)
        let payload = fixture.credentialsPayload
        let baselinePolicy = fixture.policyCanonicalBytes
        let baselineBootArguments = fixture.bootArgumentBytes

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: payload
        )
        #expect(try store.loadRecord().phase == .disabledVerified)

        fixture.failNextNVRAMWrite()
        #expect(throws: PommeGuestRecoverySecurityError.commandFailed) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.enable",
                payload: payload
            )
        }

        let rolledBack = try store.loadRecord()
        #expect(rolledBack.phase == .rollbackVerified)
        #expect(rolledBack.policyCheckpoint?.action == .rollback)
        #expect(rolledBack.nativeTransition?.action == .rollback)
        #expect(rolledBack.nativeTransition?.receipt == true)
        #expect(rolledBack.nvramCheckpoint?.action == .rollback)
        #expect(rolledBack.nvramCheckpoint?.receipt == true)
        #expect(fixture.securityMode == "permissive")
        #expect(fixture.customBootArguments)

        let enabled = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: payload
        )
        #expect(enabled.objectValue?["amfiDisabled"] == .bool(false))
        #expect(enabled.objectValue?["securityMode"] == .string("full"))
        #expect(try !store.isPresent())
        #expect(fixture.secretOperationCount == 4)
        #expect(fixture.bootArgumentBytes == baselineBootArguments)

        let restoredPolicy = try policyFields(fixture.policyCanonicalBytes)
        let originalPolicy = try policyFields(baselinePolicy)
        let regeneratedAndNonceKeys: Set<String> = [
            "spih", "spih_exists", "nsih", "stng", "stng_exists",
            "lpnh", "os_lpnh"
        ]
        #expect(Set(restoredPolicy.keys) == Set(originalPolicy.keys))
        for key in originalPolicy.keys where !regeneratedAndNonceKeys.contains(key) {
            #expect(restoredPolicy[key] == originalPolicy[key])
        }
    }

    @Test("A changed rollback manifest remains unresolved before enable retry")
    func enableRollbackManifestDriftStaysPending() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store)
        let payload = fixture.credentialsPayload

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: payload
        )
        fixture.failNextNVRAMWrite()
        #expect(throws: PommeGuestRecoverySecurityError.commandFailed) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.enable",
                payload: payload
            )
        }
        #expect(try store.loadRecord().phase == .rollbackVerified)

        fixture.driftNativeManifest()
        let policyWritesBeforeRetry = fixture.secretOperationCount
        let nvramWritesBeforeRetry = fixture.nvramWriteCount
        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.enable",
                payload: payload
            )
        }
        #expect(fixture.secretOperationCount == policyWritesBeforeRetry)
        #expect(fixture.nvramWriteCount == nvramWritesBeforeRetry)
        #expect(try store.loadRecord().phase == .rollbackVerified)
    }

    @Test("Exact policy checkpoint metadata drift is rejected before native writes")
    func policyCheckpointMetadataDriftIsRejected() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        try fixture.installPolicyReceipt(store: store)
        fixture.driftNativeManifest()
        let operations = fixture.operations(store: store)

        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
        }
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 0)
        #expect(try store.loadRecord().phase == .policyApplied)
    }

    @Test("A changed legacy checkpoint remains unresolved")
    func legacyCheckpointMetadataDriftIsUnresolved() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        try fixture.installLegacyBaseline(store: store)
        fixture.simulateNativePolicyWrite()
        let operations = fixture.operations(store: store)

        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
        }
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 0)
        #expect(try store.loadRecord().isLegacy)
    }

    @Test("A native policy effect without a receipt remains pending and is never adopted")
    func unreceiptedNativePolicyEffectStaysPending() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "full",
            throwAfterPolicyEffect: true
        )
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store)

        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
        }
        let pending = try store.loadRecord()
        #expect(pending.phase == .policyApplying)
        #expect(pending.nativeTransition?.receipt == false)
        #expect(pending.policyCheckpoint == nil)
        #expect(fixture.secretOperationCount == 1)
        #expect(fixture.nvramWriteCount == 0)

        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.credentialsPayload
            )
        }
        #expect(fixture.secretOperationCount == 1)
        #expect(fixture.nvramWriteCount == 0)
        #expect(try store.loadRecord().phase == .policyApplying)
    }

    @Test("Malformed schema 2 checkpoint relationships are rejected")
    func malformedSchema2CheckpointRelationshipsAreRejected() throws {
        func assertRejected(
            _ mutate: (AMFICheckpointFixture, inout [String: Any]) throws -> Void
        ) throws {
            let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
            defer { fixture.cleanup() }
            let store = try fixture.store()
            try fixture.installPolicyReceipt(store: store)
            try fixture.rewriteSnapshotJSON { root in
                try mutate(fixture, &root)
            }

            #expect(throws: PommeGuestRecoverySecurityError.invalidSnapshot) {
                try store.loadRecord()
            }
        }

        try assertRejected { fixture, root in
            let intent = try PommeGuestAMFINativePolicyTransition(
                action: .disable,
                beforePolicy: fixture.policyCanonicalBytes,
                beforeGeneration: 1
            )
            let transition = try jsonObject(intent)
            guard var transitionObject = transition as? [String: Any] else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            transitionObject["afterPolicy"] = Data("after".utf8).base64EncodedString()
            root["phase"] = PommeGuestAMFITransactionPhase.policyApplying.rawValue
            root["policyCheckpoint"] = NSNull()
            root["nativeTransition"] = transitionObject
        }

        try assertRejected { _, root in
            root["phase"] = PommeGuestAMFITransactionPhase.policyApplied.rawValue
            root["nativeTransition"] = NSNull()
        }

        try assertRejected { _, root in
            root["phase"] = PommeGuestAMFITransactionPhase.policyApplied.rawValue
            root["policyCheckpoint"] = NSNull()
        }

        try assertRejected { _, root in
            guard var checkpoint = root["policyCheckpoint"] as? [String: Any] else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            checkpoint["action"] = PommeGuestAMFINativePolicyAction.restore.rawValue
            root["policyCheckpoint"] = checkpoint
        }
    }

    @Test("A v3 policy intent publication failure causes no native effect")
    func v3PolicyIntentPublicationFailureIsBeforeEffect() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let fault = AMFIPublicationFault()
        fault.failNext(.policyApplying)
        let store = try fixture.store(publicationFailureInjector: { phase, replacing in
            try fault.inject(phase: phase, replacing: replacing)
        })
        let operations = fixture.operations(store: store)

        #expect(throws: PommeGuestRecoverySecurityError.invalidSnapshot) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.stagedCredentialsPayload
            )
        }
        let retained = try store.loadRecord()
        #expect(retained.phase == .baselineCaptured)
        #expect(retained.policyCheckpoint == nil)
        #expect(retained.nativeTransition == nil)
        #expect(fixture.secretOperationCount == 0)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        #expect(fixture.secretOperationCount == 1)
        #expect(try store.loadRecord().phase == .policyApplied)
    }

    @Test("A v3 policy effect without receipt is retained and never repeated")
    func v3PolicyReceiptPublicationFailureStopsDuplicatePolicy() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let fault = AMFIPublicationFault()
        fault.failNext(.policyApplied)
        let store = try fixture.store(publicationFailureInjector: { phase, replacing in
            try fault.inject(phase: phase, replacing: replacing)
        })
        let operations = fixture.operations(store: store)

        #expect(throws: PommeGuestRecoverySecurityError.invalidSnapshot) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.stagedCredentialsPayload
            )
        }
        let retained = try store.loadRecord()
        #expect(retained.phase == .policyApplying)
        #expect(retained.nativeTransition?.receipt == false)
        #expect(retained.policyCheckpoint == nil)
        #expect(fixture.secretOperationCount == 1)

        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.stagedCredentialsPayload
            )
        }
        #expect(fixture.secretOperationCount == 1)
        #expect(try store.loadRecord().phase == .policyApplying)
    }

    @Test("Pre-fix split policy-only records project to policyApplied and resume")
    func preFixSplitPolicyOnlyRecordResumesThroughNormalProof() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        try fixture.installPreFixSplitPolicyOnlyRecord(store: store)
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })

        let status = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(status.objectValue?["baselinePresent"] == .bool(true))
        #expect(status.objectValue?["baselinePhase"] == .string("policyApplied"))
        #expect(status.objectValue?["reconciliationRequired"] == .bool(true))
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 0)

        let policyRetry = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        #expect(policyRetry.objectValue?["policyReceipt"] == .bool(true))
        #expect(policyRetry.objectValue?["nvramReceipt"] == .bool(false))
        #expect(fixture.secretOperationCount == 0)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        #expect(fixture.nvramWriteCount == 1)
        #expect(try store.loadRecord().phase == .disabledConfigured)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyDisabled",
            payload: fixture.normalPayload
        )
        #expect(try store.loadRecord().phase == .disabledVerified)
    }

    @Test("Normal NVRAM failure retains policy receipt and retries without policy")
    func v3NormalNVRAMFailureRetainsPolicyReceipt() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        fixture.failNextNVRAMWrite()

        #expect(throws: PommeGuestRecoverySecurityError.commandFailed) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.disable",
                payload: fixture.normalPayload
            )
        }
        let failed = try store.loadRecord()
        #expect(failed.phase == .normalNVRAMApplying)
        #expect(failed.policyCheckpoint?.action == .disable)
        #expect(failed.nativeTransition?.action == .disable)
        #expect(failed.nativeTransition?.receipt == true)
        #expect(failed.nvramCheckpoint?.receipt == false)
        #expect(failed.nvramFailure != nil)
        #expect(fixture.secretOperationCount == 1)
        #expect(fixture.nvramWriteCount == 1)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        #expect(fixture.secretOperationCount == 1)
        #expect(fixture.nvramWriteCount == 2)
        #expect(try store.loadRecord().phase == .disabledConfigured)
        #expect(try store.loadRecord().nvramFailure != nil)
    }

    @Test("Normal NVRAM intent publication failure occurs before the native write")
    func v3NormalNVRAMIntentPublicationFailureIsBeforeEffect() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let fault = AMFIPublicationFault()
        fault.failNext(.normalNVRAMApplying)
        let store = try fixture.store(publicationFailureInjector: { phase, replacing in
            try fault.inject(phase: phase, replacing: replacing)
        })
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )

        #expect(throws: PommeGuestRecoverySecurityError.invalidSnapshot) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.disable",
                payload: fixture.normalPayload
            )
        }
        let retained = try store.loadRecord()
        #expect(retained.phase == .policyApplied)
        #expect(retained.policyCheckpoint?.action == .disable)
        #expect(retained.nativeTransition?.action == .disable)
        #expect(retained.nativeTransition?.receipt == true)
        #expect(retained.nvramCheckpoint == nil)
        #expect(fixture.nvramWriteCount == 0)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        #expect(fixture.nvramWriteCount == 1)
        #expect(try store.loadRecord().phase == .disabledConfigured)
    }

    @Test("Successful normal NVRAM effect with receipt publication failure is acknowledged")
    func v3NormalNVRAMReceiptPublicationFailureIsAcknowledged() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let fault = AMFIPublicationFault()
        fault.failNext(.normalNVRAMApplied)
        let store = try fixture.store(publicationFailureInjector: { phase, replacing in
            try fault.inject(phase: phase, replacing: replacing)
        })
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )

        #expect(throws: PommeGuestRecoverySecurityError.invalidSnapshot) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.disable",
                payload: fixture.normalPayload
            )
        }
        let pending = try store.loadRecord()
        #expect(pending.phase == .normalNVRAMApplying)
        #expect(pending.nvramCheckpoint?.receipt == false)
        #expect(fixture.nvramWriteCount == 1)
        #expect(PommeBootArguments.containsOverride(fixture.bootArgumentBytes))

        // The host can re-enter Recovery to observe the same staged request
        // before the normal agent gets a chance to acknowledge a write whose
        // receipt publication was interrupted.  This must preserve the
        // normal-NVRAM phase and never repeat the authenticated policy write.
        let policyRetry = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        #expect(policyRetry.objectValue?["phase"] == .string("normalNVRAMApplying"))
        #expect(policyRetry.objectValue?["nvramReceipt"] == .bool(false))
        #expect(fixture.secretOperationCount == 1)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        #expect(fixture.nvramWriteCount == 1)
        #expect(try store.loadRecord().phase == .disabledConfigured)
    }

    @Test("Normal boot proof failures retain configured state and tombstone baseline")
    func v3NormalBootProofFailuresRetainState() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        fixture.setNormalEffectiveBootArgumentBytes(Data("wrong=1".utf8))
        #expect(throws: PommeGuestRecoverySecurityError.verificationFailed) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.verifyDisabled",
                payload: fixture.normalPayload
            )
        }
        #expect(try store.loadRecord().phase == .disabledConfigured)

        fixture.setNormalEffectiveBootArgumentBytes(fixture.bootArgumentBytes)
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyDisabled",
            payload: fixture.normalPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.enable",
            payload: fixture.normalPayload
        )
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.stagedCredentialsPayload
        )
        fixture.setNormalEffectiveBootArgumentBytes(fixture.initialBootArgumentBytes)
        fixture.setNormalSysctlFailure(true)
        #expect(throws: PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.verifyEnabled",
                payload: fixture.normalPayload
            )
        }
        #expect(try store.loadRecord().phase == .enabledConfigured)
        #expect(try store.isPresent())

        fixture.setNormalSysctlFailure(false)
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyEnabled",
            payload: fixture.normalPayload
        )
        #expect(try store.loadRecord().phase == .enabledVerified)
    }

    @Test("Normal disable retries an exact baseline reset without rewriting policy")
    func normalDisableRetriesAfterExactBaselineResetWithoutPolicyWrite() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyDisabled",
            payload: fixture.normalPayload
        )

        let record = try store.loadRecord()
        let baselineBootArguments = record.snapshot.nvram.value(for: "boot-args")?.bytes ?? Data()
        let policyWritesBeforeRetry = fixture.secretOperationCount
        let nvramWritesBeforeRetry = fixture.nvramWriteCount
        #expect(record.nvramCheckpoint?.receipt == true)
        #expect(record.nvramCheckpoint?.before == record.snapshot.nvram)
        #expect(fixture.bootArgumentBytes != baselineBootArguments)

        // A foreign value must never be adopted as the retry's starting point.
        fixture.setBootArgumentBytes(Data("foreign=1".utf8))
        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.disable",
                payload: fixture.normalPayload
            )
        }
        #expect(fixture.secretOperationCount == policyWritesBeforeRetry)
        #expect(fixture.nvramWriteCount == nvramWritesBeforeRetry)
        #expect(try store.loadRecord().phase == .disabledVerified)

        // Reboot/lifecycle loss to the exact durable baseline is resumable.
        fixture.setBootArgumentBytes(baselineBootArguments)
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        #expect(fixture.secretOperationCount == policyWritesBeforeRetry)
        #expect(fixture.nvramWriteCount == nvramWritesBeforeRetry + 1)
        #expect(try store.loadRecord().phase == .disabledConfigured)
        #expect(fixture.bootArgumentBytes != baselineBootArguments)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyDisabled",
            payload: fixture.normalPayload
        )
        #expect(fixture.secretOperationCount == policyWritesBeforeRetry)
        #expect(try store.loadRecord().phase == .disabledVerified)
    }

    @Test("Standard SIP-disabled profile uses exact no-op policy receipts")
    func standardSIPDisabledProfileUsesNoOpPolicyReceipts() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "permissive",
            standardSIPDisabledProfile: true
        )
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        let baselinePolicy = fixture.policyCanonicalBytes

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 0)
        let disabledReceipt = try store.loadRecord()
        #expect(disabledReceipt.policyCheckpoint?.action == .disable)
        #expect(disabledReceipt.nativeTransition?.receipt == true)
        #expect(disabledReceipt.nativeTransition?.beforePolicy == baselinePolicy)
        #expect(disabledReceipt.nativeTransition?.afterPolicy == baselinePolicy)
        #expect(disabledReceipt.nativeTransition?.beforeGeneration == 1)
        #expect(disabledReceipt.nativeTransition?.afterGeneration == 1)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyDisabled",
            payload: fixture.normalPayload
        )
        #expect(fixture.nvramWriteCount == 1)
        #expect(fixture.secretOperationCount == 0)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.enable",
            payload: fixture.normalPayload
        )
        let policyEnabled = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.stagedCredentialsPayload
        )
        #expect(policyEnabled.objectValue?["policyReceipt"] == .bool(true))
        #expect(fixture.secretOperationCount == 0)
        let enabledReceipt = try store.loadRecord()
        #expect(enabledReceipt.policyCheckpoint?.action == .restore)
        #expect(enabledReceipt.nativeTransition?.receipt == true)
        #expect(enabledReceipt.nativeTransition?.beforePolicy == baselinePolicy)
        #expect(enabledReceipt.nativeTransition?.afterPolicy == baselinePolicy)
        #expect(enabledReceipt.nativeTransition?.beforeGeneration == 1)
        #expect(enabledReceipt.nativeTransition?.afterGeneration == 1)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyEnabled",
            payload: fixture.normalPayload
        )
        #expect(fixture.nvramWriteCount == 2)
        #expect(fixture.secretOperationCount == 0)
        let status = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(status.objectValue?["baselinePresent"] == .bool(false))
        #expect(status.objectValue?["baselinePhase"] == .string("none"))
        #expect(status.objectValue?["reconciliationRequired"] == .bool(false))
    }

    @Test("Unsupported nonzero SIP masks fail before policy or NVRAM effects")
    func unsupportedCustomSIPMaskIsRejected() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "permissive",
            standardSIPDisabledProfile: true
        )
        defer { fixture.cleanup() }
        fixture.setCustomSIPBits(63)
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })

        #expect(throws: PommeGuestRecoverySecurityError.invalidPolicy) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.stagedCredentialsPayload
            )
        }
        #expect(try store.isPresent() == false)
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 0)
    }

    @Test("Standard SIP-disabled policy drift stops without a guessed reset")
    func standardSIPDisabledPolicyDriftStops() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "permissive",
            standardSIPDisabledProfile: true
        )
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        fixture.driftNativeManifest()

        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.stagedCredentialsPayload
            )
        }
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 0)
        #expect(try store.loadRecord().phase == .policyApplied)
    }

    @Test("Standard SIP-disabled no-op rejects rotating nonce drift")
    func standardSIPDisabledNonceDriftStops() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "permissive",
            standardSIPDisabledProfile: true
        )
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        fixture.driftPolicyNoncesOnly()

        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.stagedCredentialsPayload
            )
        }
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 0)
        #expect(try store.loadRecord().phase == .policyApplied)
    }

    @Test("Standard SIP-disabled restore rejects rotating nonce drift")
    func standardSIPDisabledRestoreNonceDriftStops() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "permissive",
            standardSIPDisabledProfile: true
        )
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyDisabled",
            payload: fixture.normalPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.enable",
            payload: fixture.normalPayload
        )
        fixture.driftPolicyNoncesOnly()

        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.enable",
                payload: fixture.stagedCredentialsPayload
            )
        }
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 2)
        #expect(try store.loadRecord().phase == .normalNVRAMApplied)
    }

    @Test("Legacy restore intent publishes a same-generation no-op receipt")
    func legacyRestoreIntentPublishesNoOpReceiptBeforeClear() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "permissive",
            standardSIPDisabledProfile: true
        )
        defer { fixture.cleanup() }
        let fault = AMFIPublicationFault()
        fault.failNext(.nvramRestored)
        let store = try fixture.store(publicationFailureInjector: { phase, replacing in
            try fault.inject(phase: phase, replacing: replacing)
        })
        try fixture.installPendingRestoreIntent(store: store)
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })

        #expect(throws: PommeGuestRecoverySecurityError.invalidSnapshot) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.enable",
                payload: fixture.credentialsPayload
            )
        }
        let retained = try store.loadRecord()
        #expect(retained.phase == .rollbackVerified)
        #expect(retained.policyCheckpoint?.action == .restore)
        #expect(retained.nativeTransition?.action == .restore)
        #expect(retained.nativeTransition?.receipt == true)
        #expect(retained.nativeTransition?.beforePolicy == fixture.policyCanonicalBytes)
        #expect(retained.nativeTransition?.afterPolicy == fixture.policyCanonicalBytes)
        #expect(retained.nativeTransition?.beforeGeneration == 1)
        #expect(retained.nativeTransition?.afterGeneration == 1)
        #expect(fixture.secretOperationCount == 0)
        // The failed restore receipt triggers an exact NVRAM rollback.
        #expect(fixture.nvramWriteCount == 2)
    }

    @Test("Standard SIP-disabled no-op receipt boundary is retryable")
    func standardSIPDisabledNoOpReceiptBoundaryIsRetryable() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "permissive",
            standardSIPDisabledProfile: true
        )
        defer { fixture.cleanup() }
        let fault = AMFIPublicationFault()
        fault.failNext(.policyApplied)
        let store = try fixture.store(publicationFailureInjector: { phase, replacing in
            try fault.inject(phase: phase, replacing: replacing)
        })
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })

        #expect(throws: PommeGuestRecoverySecurityError.invalidSnapshot) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.stagedCredentialsPayload
            )
        }
        let pending = try store.loadRecord()
        #expect(pending.phase == .policyApplying)
        #expect(pending.nativeTransition?.receipt == false)
        #expect(fixture.secretOperationCount == 0)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        let receipt = try store.loadRecord()
        #expect(receipt.phase == .policyApplied)
        #expect(receipt.policyCheckpoint?.action == .disable)
        #expect(receipt.nativeTransition?.receipt == true)
        #expect(receipt.nativeTransition?.beforePolicy == receipt.nativeTransition?.afterPolicy)
        #expect(receipt.nativeTransition?.beforeGeneration == receipt.nativeTransition?.afterGeneration)
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 0)
    }

    @Test("Final enabled tombstone publication failure is retryable")
    func v3EnabledTombstonePublicationFailureIsRetryable() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let fault = AMFIPublicationFault()
        fault.failNext(.enabledVerified)
        let store = try fixture.store(publicationFailureInjector: { phase, replacing in
            try fault.inject(phase: phase, replacing: replacing)
        })
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyDisabled",
            payload: fixture.normalPayload
        )
        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.enable",
            payload: fixture.normalPayload
        )
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.stagedCredentialsPayload
        )
        fixture.setNormalEffectiveBootArgumentBytes(fixture.initialBootArgumentBytes)

        #expect(throws: PommeGuestRecoverySecurityError.invalidSnapshot) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.verifyEnabled",
                payload: fixture.normalPayload
            )
        }
        #expect(try store.loadRecord().phase == .enabledConfigured)
        #expect(try store.isPresent())

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyEnabled",
            payload: fixture.normalPayload
        )
        #expect(try store.loadRecord().phase == .enabledVerified)
    }

    @Test("Staged AMFI splits Recovery policy from normal NVRAM and final proof")
    func stagedPolicyAndNormalNVRAMTransaction() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })

        let policyDisabled = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        #expect(policyDisabled.objectValue?["stage"] == .string("policy"))
        #expect(policyDisabled.objectValue?["policyReceipt"] == .bool(true))
        #expect(policyDisabled.objectValue?["nvramReceipt"] == .bool(false))
        #expect(policyDisabled.objectValue?["amfiDisabled"] == .bool(false))
        #expect(fixture.secretOperationCount == 1)
        #expect(fixture.nvramWriteCount == 0)
        #expect(try store.loadRecord().version == 3)
        #expect(try store.loadRecord().executionMode == .splitNormalNVRAM)
        #expect(try store.loadRecord().phase == .policyApplied)
        let configuredStatus = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(configuredStatus.objectValue?["baselinePresent"] == .bool(true))
        #expect(configuredStatus.objectValue?["baselinePhase"] == .string("policyApplied"))
        #expect(configuredStatus.objectValue?["reconciliationRequired"] == .bool(true))

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        #expect(fixture.nvramWriteCount == 1)
        #expect(PommeBootArguments.containsOverride(fixture.bootArgumentBytes))
        #expect(try store.loadRecord().phase == .disabledConfigured)

        let verifiedDisabled = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyDisabled",
            payload: fixture.normalPayload
        )
        #expect(verifiedDisabled.objectValue?["verified"] == .bool(true))
        #expect(try store.loadRecord().phase == .disabledVerified)

        let disabledBootArguments = fixture.bootArgumentBytes
        fixture.setBootArgumentBytes(Data("foreign=1".utf8))
        let driftedDisabledStatus = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(driftedDisabledStatus.objectValue?["baselinePresent"] == .bool(true))
        #expect(driftedDisabledStatus.objectValue?["baselinePhase"] == .string("disabledVerified"))
        #expect(driftedDisabledStatus.objectValue?["reconciliationRequired"] == .bool(true))
        fixture.setBootArgumentBytes(disabledBootArguments)

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.enable",
            payload: fixture.normalPayload
        )
        #expect(fixture.bootArgumentBytes == fixture.initialBootArgumentBytes)
        #expect(try store.loadRecord().nvramCheckpoint?.action == .restore)
        #expect(try store.loadRecord().phase == .normalNVRAMApplied)

        let policyEnabled = try operations.execute(
            role: .recovery,
            operation: "amfi.enable",
            payload: fixture.stagedCredentialsPayload
        )
        #expect(policyEnabled.objectValue?["stage"] == .string("policy"))
        #expect(policyEnabled.objectValue?["normalBootProofPending"] == .bool(true))
        #expect(try store.loadRecord().phase == .enabledConfigured)

        let verifiedEnabled = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyEnabled",
            payload: fixture.normalPayload
        )
        #expect(verifiedEnabled.objectValue?["verified"] == .bool(true))
        #expect(try store.loadRecord().phase == .enabledVerified)
        #expect(fixture.secretOperationCount == 2)
        #expect(fixture.nvramWriteCount == 2)

        let status = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(status.objectValue?["baselinePresent"] == .bool(false))
        #expect(status.objectValue?["baselinePhase"] == .string("none"))
        #expect(status.objectValue?["reconciliationRequired"] == .bool(false))

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.verifyEnabled",
            payload: fixture.normalPayload
        )
        #expect(fixture.secretOperationCount == 2)
        #expect(fixture.nvramWriteCount == 2)

        // A completed tombstone is only clean when its restore receipt proves
        // that the write started from the exact disabled target.  Tampering
        // with that source must retain the baseline for reconciliation.
        try fixture.rewriteSnapshotJSON { root in
            let disabledTarget = try PommeNVRAMDelta.bootArguments(
                present: true,
                bytes: Data("tampered=1".utf8)
            )
            let baselineTarget = try PommeNVRAMDelta.bootArguments(
                present: true,
                bytes: fixture.initialBootArgumentBytes
            )
            let checkpoint = try PommeGuestAMFINVRAMCheckpoint(
                action: .restore,
                before: disabledTarget,
                target: baselineTarget,
                receipt: true
            )
            root["nvramCheckpoint"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(checkpoint)
            )
        }
        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.enable",
                payload: fixture.normalPayload
            )
        }
        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.verifyEnabled",
                payload: fixture.normalPayload
            )
        }
        let sourceDriftedStatus = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(sourceDriftedStatus.objectValue?["baselinePresent"] == .bool(true))
        #expect(sourceDriftedStatus.objectValue?["baselinePhase"] == .string("enabledVerified"))
        #expect(sourceDriftedStatus.objectValue?["reconciliationRequired"] == .bool(true))

        fixture.driftNativeManifest()
        let driftedStatus = try operations.execute(
            role: .recovery,
            operation: "amfi.status",
            payload: .object([
                "volumeGroupUUID": .string(fixture.groupUUID.uuidString.lowercased()),
                "includeWorkflowState": .bool(true)
            ])
        )
        #expect(driftedStatus.objectValue?["baselinePresent"] == .bool(true))
        #expect(driftedStatus.objectValue?["baselinePhase"] == .string("enabledVerified"))
        #expect(driftedStatus.objectValue?["reconciliationRequired"] == .bool(true))
    }

    @Test("Staged normal NVRAM rejects foreign boot arguments without a write")
    func stagedNormalNVRAMRejectsForeignState() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )
        fixture.setBootArgumentBytes(Data("foreign=1".utf8))
        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.disable",
                payload: fixture.normalPayload
            )
        }
        #expect(fixture.nvramWriteCount == 0)
        #expect(try store.loadRecord().phase == .policyApplied)
    }

    @Test("Production normal verifier accepts the APFS root snapshot and rejects a same-prefix foreign device")
    func productionNormalEnvironmentVerifierBindsRootDevice() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        // Leave normalEnvironmentVerifier nil: this exercises the production
        // command-backed verifier rather than the deterministic test seam.
        let operations = fixture.operations(store: store)
        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )

        _ = try operations.executeNormalAMFI(
            role: .persistent,
            operation: "amfi.normal.disable",
            payload: fixture.normalPayload
        )
        #expect(fixture.nvramWriteCount == 1)

        fixture.setNormalRootDevice("disk1s10")
        #expect(throws: PommeGuestRecoverySecurityError.recoveryEnvironmentUnverified) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.enable",
                payload: fixture.normalPayload
            )
        }
        #expect(fixture.nvramWriteCount == 1)
    }

    @Test("Policy disable preserves every already-enabled native policy switch")
    func policyDisablePreservesNativeSwitchArguments() throws {
        let fixture = try AMFICheckpointFixture(
            initialSecurityMode: "permissive",
            preserveNativeFlags: true
        )
        defer { fixture.cleanup() }
        let store = try fixture.store()
        let operations = fixture.operations(store: store)

        _ = try operations.execute(
            role: .recovery,
            operation: "amfi.disable",
            payload: fixture.stagedCredentialsPayload
        )

        #expect(fixture.secretArguments == [[
            "-a", "-m", "-k", "-c", "-s", "-v",
            fixture.groupUUID.uuidString.lowercased()
        ]])
        #expect(fixture.nvramWriteCount == 0)
    }

    @Test("Legacy Recovery AMFI records cannot enter the split normal stage")
    func legacyRecordCannotBeAdoptedByStagedMode() throws {
        let fixture = try AMFICheckpointFixture(initialSecurityMode: "full")
        defer { fixture.cleanup() }
        let store = try fixture.store()
        try fixture.installLegacyBaseline(store: store)
        let operations = fixture.operations(store: store, normalEnvironmentVerifier: { _ in })
        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.execute(
                role: .recovery,
                operation: "amfi.disable",
                payload: fixture.stagedCredentialsPayload
            )
        }
        #expect(throws: PommeGuestRecoverySecurityError.snapshotPending) {
            try operations.executeNormalAMFI(
                role: .persistent,
                operation: "amfi.normal.disable",
                payload: fixture.normalPayload
            )
        }
        #expect(fixture.secretOperationCount == 0)
        #expect(fixture.nvramWriteCount == 0)
    }
}

private final class AMFIPublicationFault: @unchecked Sendable {
    private var failures: [PommeGuestAMFITransactionPhase: Int] = [:]

    func failNext(_ phase: PommeGuestAMFITransactionPhase) {
        failures[phase, default: 0] += 1
    }

    func inject(
        phase: PommeGuestAMFITransactionPhase,
        replacing: Bool
    ) throws {
        _ = replacing
        guard let count = failures[phase], count > 0 else { return }
        failures[phase] = count - 1
        throw PommeGuestRecoverySecurityError.invalidSnapshot
    }
}

private final class AMFICheckpointFixture: @unchecked Sendable {
    let groupUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let dataRoot: URL
    let snapshotURL: URL
    private(set) var securityMode: String
    private(set) var customBootArguments: Bool
    private(set) var bootArguments: String
    private(set) var policyNonce: String
    private(set) var policySPih: String
    private(set) var policyNSih: String
    private(set) var policyGeneration: UInt64
    private(set) var secretOperationCount = 0
    private(set) var secretArguments: [[String]] = []
    private(set) var nvramWriteCount = 0
    private(set) var normalRootDevice = "disk1s1s1"
    private var rawBootArgumentBytes: Data
    private var effectiveBootArgumentOverride: Data?
    private var normalSysctlFailure = false
    private var failedNVRAMWritesRemaining = 0
    private let throwAfterPolicyEffect: Bool
    private let preserveNativeFlags: Bool
    private let standardSIPDisabledProfile: Bool
    private var customSIPBitsOverride: UInt64?

    var initialBootArgumentBytes: Data { initialRawBootArgumentBytes }
    private let initialRawBootArgumentBytes: Data

    init(
        initialSecurityMode: String,
        initialBootArgumentBytes: Data = Data("keep=1".utf8),
        throwAfterPolicyEffect: Bool = false,
        preserveNativeFlags: Bool = false,
        standardSIPDisabledProfile: Bool = false
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-amfi-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        dataRoot = directory
        snapshotURL = directory.appendingPathComponent(PommeGuestAMFISnapshotStore.snapshotRelativePath)
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        securityMode = initialSecurityMode
        customBootArguments = false
        rawBootArgumentBytes = initialBootArgumentBytes
        effectiveBootArgumentOverride = nil
        initialRawBootArgumentBytes = initialBootArgumentBytes
        bootArguments = String(decoding: initialBootArgumentBytes, as: UTF8.self)
        policyNonce = String(repeating: "C", count: 96)
        policySPih = String(repeating: "B", count: 96)
        policyNSih = String(repeating: "F", count: 96)
        policyGeneration = 1
        self.throwAfterPolicyEffect = throwAfterPolicyEffect
        self.preserveNativeFlags = preserveNativeFlags
        self.standardSIPDisabledProfile = standardSIPDisabledProfile
        self.customSIPBitsOverride = nil
    }

    deinit {
        try? FileManager.default.removeItem(at: dataRoot)
    }

    var credentialsPayload: JSONValue {
        .object([
            "authorizedUser": .string("owner"),
            "password": .string("fixture-password"),
            "volumeGroupUUID": .string(groupUUID.uuidString.lowercased())
        ])
    }

    var stagedCredentialsPayload: JSONValue {
        guard var object = credentialsPayload.objectValue else { return credentialsPayload }
        object["stage"] = .string("policy")
        return .object(object)
    }

    var normalPayload: JSONValue {
        .object(["volumeGroupUUID": .string(groupUUID.uuidString.lowercased())])
    }

    var bootArgumentBytes: Data { rawBootArgumentBytes }

    var policyCanonicalBytes: Data {
        (try? JSONSerialization.data(withJSONObject: policyObject, options: [.sortedKeys])) ?? Data()
    }

    func store(
        publicationFailureInjector: PommeGuestAMFISnapshotStore.PublicationFailureInjector? = nil
    ) throws -> PommeGuestAMFISnapshotStore {
        try PommeGuestAMFISnapshotStore(
            dataRoot: dataRoot,
            volumeGroupUUID: groupUUID,
            expectedOwner: geteuid(),
            expectedGroup: nil,
            publicationFailureInjector: publicationFailureInjector
        )
    }

    func operations(
        store: PommeGuestAMFISnapshotStore,
        normalEnvironmentVerifier: (@Sendable (UUID) throws -> Void)? = nil
    ) -> PommeGuestRecoverySecurityOperations {
        PommeGuestRecoverySecurityOperations(
            process: { [self] executable, arguments in
                try process(executable: executable, arguments: arguments)
            },
            secretProcess: { [self] executable, arguments, credentials in
                try secretProcess(
                    executable: executable,
                    arguments: arguments,
                    credentials: credentials
                )
            },
            effectiveUserID: { 0 },
            snapshotStore: store,
            nvramMutationVerified: { true },
            normalEnvironmentVerifier: normalEnvironmentVerifier
        )
    }

    func setBootArgumentBytes(_ bytes: Data) {
        rawBootArgumentBytes = bytes
        bootArguments = String(decoding: bytes, as: UTF8.self)
    }

    func setNormalRootDevice(_ device: String) {
        normalRootDevice = device
    }

    func setNormalEffectiveBootArgumentBytes(_ bytes: Data) {
        effectiveBootArgumentOverride = bytes
    }

    func setNormalSysctlFailure(_ enabled: Bool) {
        normalSysctlFailure = enabled
    }

    func setCustomSIPBits(_ bits: UInt64) {
        customSIPBitsOverride = bits
    }

    func installPolicyReceipt(store: PommeGuestAMFISnapshotStore) throws {
        let baseline = try baselineSnapshot()
        try store.save(baseline)
        let beforePolicy = policyCanonicalBytes
        let beforeGeneration = policyGeneration
        simulateNativePolicyWrite()
        let afterPolicy = policyCanonicalBytes
        let afterGeneration = policyGeneration
        let transition = try PommeGuestAMFINativePolicyTransition(
            action: .disable,
            beforePolicy: beforePolicy,
            beforeGeneration: beforeGeneration,
            afterPolicy: afterPolicy,
            afterGeneration: afterGeneration,
            receipt: true
        )
        let checkpoint = try PommeGuestAMFIPolicyCheckpoint(
            action: .disable,
            observedPolicy: afterPolicy,
            generation: afterGeneration
        )
        try store.update(
            phase: .policyApplied,
            policyCheckpoint: checkpoint,
            nativeTransition: transition,
            nvramCheckpoint: nil
        )
    }

    func installPreFixSplitPolicyOnlyRecord(store: PommeGuestAMFISnapshotStore) throws {
        let baseline = try baselineSnapshot()
        try store.save(
            baseline,
            phase: .baselineCaptured,
            executionMode: .splitNormalNVRAM
        )
        let beforePolicy = policyCanonicalBytes
        let beforeGeneration = policyGeneration
        simulateNativePolicyWrite()
        let afterPolicy = policyCanonicalBytes
        let afterGeneration = policyGeneration
        let transition = try PommeGuestAMFINativePolicyTransition(
            action: .disable,
            beforePolicy: beforePolicy,
            beforeGeneration: beforeGeneration,
            afterPolicy: afterPolicy,
            afterGeneration: afterGeneration,
            receipt: true
        )
        let checkpoint = try PommeGuestAMFIPolicyCheckpoint(
            action: .disable,
            observedPolicy: afterPolicy,
            generation: afterGeneration
        )
        // This is the pre-fix durable shape: policy-only Recovery had already
        // published its receipt but incorrectly called the phase configured.
        try store.update(
            phase: .disabledConfigured,
            policyCheckpoint: checkpoint,
            nativeTransition: transition,
            nvramCheckpoint: nil
        )
    }

    func installLegacyBaseline(store: PommeGuestAMFISnapshotStore) throws {
        let baseline = try baselineSnapshot()
        let record = try PommeGuestAMFISnapshotRecord(
            version: 1,
            volumeGroupUUID: groupUUID,
            phase: .baselineCaptured,
            snapshot: baseline,
            policyCheckpoint: nil,
            nativeTransition: nil,
            nvramCheckpoint: nil
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: snapshotURL, options: .atomic)
        guard chmod(snapshotURL.path, 0o600) == 0 else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    func installPendingRestoreIntent(store: PommeGuestAMFISnapshotStore) throws {
        let baseline = try baselineSnapshot()
        try store.save(baseline)
        setBootArgumentBytes(
            PommeBootArguments.addingOverride(to: initialRawBootArgumentBytes)
        )
        let transition = try PommeGuestAMFINativePolicyTransition(
            action: .restore,
            beforePolicy: baseline.localPolicy,
            beforeGeneration: policyGeneration,
            receipt: false
        )
        try store.update(
            phase: .restoringPolicy,
            policyCheckpoint: nil,
            nativeTransition: transition,
            nvramCheckpoint: nil
        )
    }

    func simulateNativePolicyWrite() {
        securityMode = "permissive"
        customBootArguments = true
        policyNonce = String(repeating: "D", count: 96)
        advanceNativeManifestGeneration()
    }

    func driftNativeManifest() {
        advanceNativeManifestGeneration(by: 2)
    }

    /// Mutate only LocalPolicy's anti-replay nonce pair. The manifest hashes
    /// and generation remain unchanged so a no-op receipt must reject it.
    func driftPolicyNoncesOnly() {
        policyNonce = String(repeating: "A", count: 96)
    }

    func failNextNVRAMWrite() {
        failedNVRAMWritesRemaining += 1
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dataRoot)
    }

    func rewriteSnapshotJSON(
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws {
        let existing = try Data(contentsOf: snapshotURL)
        guard var root = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        try mutate(&root)
        let rewritten = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try rewritten.write(to: snapshotURL, options: .atomic)
        guard chmod(snapshotURL.path, 0o600) == 0 else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    private func baselineSnapshot() throws -> PommeAMFISecuritySnapshot {
        try PommeAMFISecuritySnapshot(
            localPolicy: policyCanonicalBytes,
            nvram: try PommeNVRAMDelta.bootArguments(
                present: true,
                bytes: rawBootArgumentBytes
            )
        )
    }

    private func process(
        executable: String,
        arguments: [String]
    ) throws -> PommeGuestProcessCapture {
        switch (executable, arguments) {
        case ("/usr/bin/csrutil", ["status"]):
            return .init(
                status: 0,
                stdout: Data("System Integrity Protection status: disabled.\n".utf8)
            )
        case ("/usr/sbin/diskutil", ["apfs", "listVolumeGroups", "-plist"]):
            return .init(status: 0, stdout: volumeGroupsPropertyList)
        case ("/usr/sbin/diskutil", ["info", "-plist", "/"]):
            let root: [String: Any] = [
                "DeviceIdentifier": normalRootDevice,
                "FilesystemType": "apfs",
                "MountPoint": "/",
                "VolumeName": "Macintosh HD",
                "APFSVolumeGroupID": groupUUID.uuidString,
                "DiskImage": false,
                "RecoveryVolume": false
            ]
            return .init(
                status: 0,
                stdout: try PropertyListSerialization.data(
                    fromPropertyList: root,
                    format: .xml,
                    options: 0
                )
            )
        case ("/usr/bin/bputil", let values)
            where values.count == 4
                && values[0] == "--json"
                && values[1] == "--display-policy"
                && values[2] == "-v":
            return .init(status: 0, stdout: policyJSON)
        case ("/usr/bin/bputil", ["--json", "--display-all-policies"]):
            return .init(status: 0, stdout: policyJSON)
        case ("/usr/sbin/nvram", ["-x", "boot-args"]):
            return .init(
                status: 0,
                stdout: try PropertyListSerialization.data(
                    fromPropertyList: [
                        "boot-args": String(decoding: rawBootArgumentBytes, as: UTF8.self)
                    ],
                    format: .xml,
                    options: 0
                )
            )
        case ("/usr/sbin/sysctl", ["-n", "kern.bootargs"]):
            if normalSysctlFailure {
                return .init(status: 1)
            }
            var output = effectiveBootArgumentOverride ?? rawBootArgumentBytes
            output.append(0x0a)
            return .init(status: 0, stdout: output)
        case ("/usr/sbin/nvram", let values)
            where values.count == 1 && values[0].hasPrefix("boot-args="):
            nvramWriteCount += 1
            if failedNVRAMWritesRemaining > 0 {
                failedNVRAMWritesRemaining -= 1
                return .init(status: 1)
            }
            let value = String(arguments[0].dropFirst("boot-args=".count))
            // The `nvram -x` reader returns a CFString for boot-args.  In that
            // representation a literal `%20` is text, rather than a CFData
            // percent escape, and must survive a write/readback unchanged.
            rawBootArgumentBytes = Data(value.utf8)
            bootArguments = String(decoding: rawBootArgumentBytes, as: UTF8.self)
            return .init(status: 0)
        default:
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
    }

    private func secretProcess(
        executable: String,
        arguments: [String],
        credentials: PommeGuestSecurityCredentials
    ) throws -> PommeGuestProcessCapture {
        guard executable == "/usr/bin/bputil",
            !credentials.password.isEmpty,
            arguments.contains("-v"),
            arguments.contains(groupUUID.uuidString.lowercased())
        else { throw PommeGuestRecoverySecurityError.invalidOperation }
        secretOperationCount += 1
        secretArguments.append(arguments)
        let mode = arguments.first
        if mode == "-a" {
            simulateNativePolicyWrite()
        } else if mode == "-f" {
            securityMode = "full"
            customBootArguments = false
            policyNonce = String(repeating: "E", count: 96)
            advanceNativeManifestGeneration()
        } else if mode == "-n" {
            // A compensating rollback to the disabled baseline uses bputil's
            // permissive restore form, rather than the disable shorthand.
            securityMode = "permissive"
            customBootArguments = arguments.contains("-a")
            policyNonce = String(repeating: "D", count: 96)
            advanceNativeManifestGeneration()
        } else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        if throwAfterPolicyEffect {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
        return .init(status: 0)
    }

    private var volumeGroupsPropertyList: Data {
        let value: [String: Any] = [
            "Containers": [[
                "VolumeGroups": [[
                    "APFSVolumeGroupUUID": groupUUID.uuidString,
                    "Volumes": [
                        ["Role": "System", "DeviceIdentifier": "disk1s1"],
                        ["Role": "Data", "DeviceIdentifier": "disk1s2"]
                    ]
                ]]
            ]]
        ]
        return try! PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }

    private func advanceNativeManifestGeneration(by amount: UInt64 = 1) {
        policyGeneration += amount
        let alphabet = Array("0123456789ABCDEF")
        policySPih = String(
            repeating: alphabet[Int(policyGeneration % UInt64(alphabet.count))],
            count: 96
        )
        policyNSih = String(
            repeating: alphabet[Int((policyGeneration + 1) % UInt64(alphabet.count))],
            count: 96
        )
    }

    private var policyObject: [String: Any] {
        let permissive = securityMode == "permissive"
        let reduced = securityMode != "full"
        let sip0 = customSIPBitsOverride
            ?? (standardSIPDisabledProfile ? UInt64(127) : UInt64(0))
        let sip0Exists = customSIPBitsOverride != nil || standardSIPDisabledProfile
        let policy: [String: Any] = [
            "CSEC": true,
            "CEPO": 1,
            "SDOM": 1,
            "CHIP": 65024,
            "BORD": 32,
            "ECID": UInt64(16_328_928_024_640_429_816),
            "CRPO": true,
            "lobo": true,
            "spih": policySPih,
            "spih_exists": true,
            "nsih": policyNSih,
            "stng": policyGeneration,
            "stng_exists": true,
            "lpnh": policyNonce,
            "rpnh": String(repeating: "D", count: 96),
            "os_lpnh": policyNonce,
            "os_ronh": String(repeating: "E", count: 96),
            "auxp_exists": false,
            "auxi_exists": false,
            "auxr_exists": false,
            "coih_exists": false,
            "vuid": groupUUID.uuidString,
            "kuid": "00000000-0000-0000-0000-000000000000",
            "love": "25.7.83.0.0,0",
            "bputil_version": "0.1.14",
            "security_mode": securityMode,
            "smb0": reduced,
            "smb1": permissive,
            "smb2": preserveNativeFlags,
            "smb3": preserveNativeFlags,
            "smb4": false,
            "sip0": sip0,
            "sip0_exists": sip0Exists,
            "sip1": standardSIPDisabledProfile ? false : preserveNativeFlags,
            "sip2": standardSIPDisabledProfile ? true : preserveNativeFlags,
            "sip3": standardSIPDisabledProfile ? true : customBootArguments,
            "properly_paired": true,
            "os_paired_to_current": true,
            "baa_certified": false,
            "os_type": "macOS",
            "os_type_overriden": true
        ]
        return [groupUUID.uuidString: policy]
    }

    private var policyJSON: Data {
        var output = Data(
            "Operating on Volume Group UUID \(groupUUID.uuidString.uppercased())\n".utf8)
        output.append(policyCanonicalBytes)
        return output
    }
}

private func policyFields(_ data: Data) throws -> [String: JSONValue] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rawPolicy = root.values.first as? [String: Any]
    else { throw PommeGuestRecoverySecurityError.invalidPolicy }
    return try rawPolicy.mapValues { try JSONValue(any: $0) }
}

private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}
