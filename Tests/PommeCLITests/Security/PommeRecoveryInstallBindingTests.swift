import Foundation
import Testing

@Suite("Pomme Recovery install payload binding")
struct PommeRecoveryInstallBindingTests {
    private static let bundlePath = "/tmp/pomme-recovery-install-binding-vm.bundle"
    private static let alternateBundlePath = "/tmp/pomme-recovery-install-binding-other.bundle"
    private static let executablePath = "/tmp/pomme-recovery-install-binding-vm.bundle/pomme-agent"
    private static let vmUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private static let alternateVMUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let targetVolumeGroupUUID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    private static let requestID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
    private static let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let executableDigest = String(repeating: "a", count: 64)
    private static let alternateExecutableDigest = String(repeating: "b", count: 64)
    private static let restoreImageDigest = String(repeating: "c", count: 64)
    private static let vmName = "binding-vm"
    private static let normalAgentIdentifier = "com.github.weswhet.pomme.binding.normal"
    private static let recoveryAgentIdentifier = "com.github.weswhet.pomme.binding.recovery"

    @Test(
        "Initial install accepts every durable plan final state with a stopped temporary session",
        arguments: [PommeProvisioningFinalState.stopped, .normalRunning, .recoveryRunning]
    )
    func initialInstallAcceptsEveryPlanFinalState(
        planFinalState: PommeProvisioningFinalState
    ) throws {
        // Given: the install transaction always requests the temporary stopped
        // state, while the durable plan records the caller's eventual state.
        let fixture = try makeFixture(planFinalState: planFinalState)

        // When: the exact payload is checked before the credential is read.
        try validate(fixture)

        // Then: all three durable create outcomes are admitted.
    }

    @Test(
        "Initial install rejects every non-stopped temporary final state",
        arguments: [VMFinalState.normal, .recovery, .previous, .paused]
    )
    func initialInstallRejectsNonStoppedTemporaryFinalState(
        finalState: VMFinalState
    ) throws {
        // Given: the request and caller argument agree on a non-stopped state.
        let planFinalState: PommeProvisioningFinalState = switch finalState {
        case .normal: .normalRunning
        case .recovery: .recoveryRunning
        default: .stopped
        }
        let fixture = try makeFixture(
            planFinalState: planFinalState,
            requestFinalState: finalState
        )

        // When/Then: initial installation is bounded to a stopped session.
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, finalState: finalState)
        }
    }

    @Test(
        "Repair retains every request-bound final state",
        arguments: VMFinalState.allCases
    )
    func repairRetainsRequestBoundFinalStates(finalState: VMFinalState) throws {
        // Given: repair has an existing APFS volume-group identity and the
        // request is bound to the final state it asks the session to restore.
        let fixture = try makeFixture(
            planFinalState: .recoveryRunning,
            requestFinalState: finalState,
            targetVolumeGroupUUID: Self.targetVolumeGroupUUID
        )

        // When/Then: repair keeps its existing request-bound state vocabulary.
        try validate(fixture, finalState: finalState, installMode: .repair)
    }

    @Test("Initial install requires the absence of an existing volume group")
    func initialInstallRejectsExistingVolumeGroup() throws {
        // Given: an otherwise valid initial-install request with repair-only
        // APFS identity present.
        let fixture = try makeFixture(targetVolumeGroupUUID: Self.targetVolumeGroupUUID)

        // When/Then: initial mode cannot be used against an existing volume.
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture)
        }
    }

    @Test("Repair requires the existing volume-group identity")
    func repairRejectsMissingVolumeGroup() throws {
        // Given: a repair request without the immutable target volume identity.
        let fixture = try makeFixture()

        // When/Then: repair fails closed before any credential or guest access.
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, installMode: .repair)
        }
    }

    @Test("Malformed and noncanonical install payloads remain rejected")
    func malformedAndNoncanonicalPayloadsReject() throws {
        // Given: a valid canonical payload and a semantically equivalent JSON
        // spelling whose bytes no longer match the plan digest.
        let fixture = try makeFixture()
        var noncanonical = fixture.payload
        noncanonical.insert(0x0a, at: 1)

        // When/Then: decoding or digest mismatch is rejected before mutation.
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, payload: Data("not-json".utf8))
        }
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, payload: noncanonical)
        }
    }

    @Test("VM, path, name, executable, role, request, and mode bindings stay closed")
    func identityAndRequestBindingsRejectDrift() throws {
        // Given: one canonical initial-install fixture and independently
        // mutated values for each immutable binding guard.
        let fixture = try makeFixture()
        let wrongUUID = try makeFixture(ownershipUUID: Self.alternateVMUUID)
        let wrongPath = VMReference(
            name: Self.vmName,
            bundle: BundleLayout(rootURL: URL(fileURLWithPath: Self.alternateBundlePath))
        )
        let wrongName = VMReference(
            name: "other-vm",
            bundle: fixture.reference.bundle
        )
        let wrongExecutable = try makeFixture(
            executableDigest: Self.alternateExecutableDigest
        )
        let wrongRequest = try makeFixture(requestFinalState: .normal)
        let wrongRecoveryRolePayload = try payloadReplacingRole(
            in: fixture.payload,
            identifier: Self.recoveryAgentIdentifier,
            from: .recovery,
            to: .normal
        )
        let wrongNormalRolePayload = try payloadReplacingRole(
            in: fixture.payload,
            identifier: Self.normalAgentIdentifier,
            from: .normal,
            to: .recovery
        )

        // When/Then: every independent binding mismatch fails closed.
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, identity: wrongUUID.identity)
        }
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, reference: wrongPath)
        }
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, reference: wrongName)
        }
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, executable: wrongExecutable.executable)
        }
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, request: wrongRequest.request)
        }
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, installMode: nil)
        }
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, payload: wrongRecoveryRolePayload)
        }
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try validate(fixture, payload: wrongNormalRolePayload)
        }
    }

    private struct Fixture {
        let payload: Data
        let reference: VMReference
        let identity: PommeLiveRecoveryIntegration.VMIdentity
        let executable: PommeLiveRecoveryIntegration.ExecutableIdentity
        let request: PommeRecoverySessionRequest
    }

    private enum FixtureError: Error {
        case roleNotFound
    }

    private func makeFixture(
        planFinalState: PommeProvisioningFinalState = .stopped,
        requestFinalState: VMFinalState = .stopped,
        targetVolumeGroupUUID: UUID? = nil,
        ownershipUUID: UUID = Self.vmUUID,
        referenceName: String? = Self.vmName,
        executableDigest: String = Self.executableDigest
    ) throws -> Fixture {
        let ownership = try PommeVMOwnership(
            name: Self.vmName,
            uuid: Self.vmUUID,
            bundlePath: Self.bundlePath
        )
        let identityOwnership = try PommeVMOwnership(
            name: Self.vmName,
            uuid: ownershipUUID,
            bundlePath: Self.bundlePath
        )
        let identity = try PommeLiveRecoveryIntegration.VMIdentity(
            ownership: identityOwnership,
            targetVolumeGroupUUID: targetVolumeGroupUUID
        )
        let reference = VMReference(
            name: referenceName,
            bundle: BundleLayout(rootURL: URL(fileURLWithPath: Self.bundlePath))
        )
        let executable = try PommeLiveRecoveryIntegration.ExecutableIdentity(
            url: URL(fileURLWithPath: Self.executablePath),
            sha256: executableDigest
        )
        let normalAgent = try PommeAgentIdentity(
            identifier: Self.normalAgentIdentifier,
            executableDigest: Self.executableDigest,
            role: .normal
        )
        let recoveryAgent = try PommeAgentIdentity(
            identifier: Self.recoveryAgentIdentifier,
            executableDigest: Self.executableDigest,
            role: .recovery
        )
        let plan = try PommeProvisioningPlan(
            vm: ownership,
            restore: .init(
                version: "26.6.0",
                build: "25G72",
                restoreImageDigest: Self.restoreImageDigest
            ),
            display: .required,
            profile: .tahoe,
            normalAgent: normalAgent,
            recoveryAgent: recoveryAgent,
            finalState: planFinalState
        )
        let payload = try PommeProvisioningCoding.encode(plan)
        let credential = try PommeRecoveryCredential(
            id: UUID(uuidString: "fedcba98-7654-3210-fedc-ba9876543210")!,
            secret: Data(repeating: 0x42, count: 32),
            expiresAt: Self.issuedAt.addingTimeInterval(120)
        )
        let request = try PommeRecoverySessionRequest(
            requestID: Self.requestID,
            vmUUID: Self.vmUUID,
            operation: .installAgent,
            issuedAt: Self.issuedAt,
            expiresAt: credential.expiresAt,
            executableSHA256: executableDigest,
            payloadSHA256: PommeRecoveryCrypto.sha256(payload),
            requestedFinalState: requestFinalState,
            credential: credential
        )
        return .init(
            payload: payload,
            reference: reference,
            identity: identity,
            executable: executable,
            request: request
        )
    }

    private func validate(
        _ fixture: Fixture,
        payload: Data? = nil,
        reference: VMReference? = nil,
        identity: PommeLiveRecoveryIntegration.VMIdentity? = nil,
        executable: PommeLiveRecoveryIntegration.ExecutableIdentity? = nil,
        request: PommeRecoverySessionRequest? = nil,
        finalState: VMFinalState = .stopped,
        installMode: PommeLiveRecoveryIntegration.InstallMode? = .initial
    ) throws {
        try PommeLiveRecoveryIntegration.validateInstallPayload(
            payload ?? fixture.payload,
            reference: reference ?? fixture.reference,
            identity: identity ?? fixture.identity,
            executable: executable ?? fixture.executable,
            request: request ?? fixture.request,
            finalState: finalState,
            installMode: installMode
        )
    }

    private func payloadReplacingRole(
        in payload: Data,
        identifier: String,
        from oldRole: PommeProvisioningAgentRole,
        to newRole: PommeProvisioningAgentRole
    ) throws -> Data {
        let source = String(decoding: payload, as: UTF8.self)
        let needle = "\"identifier\":\"\(identifier)\",\"protocolVersion\":1,\"role\":\"\(oldRole.rawValue)\""
        let replacement = "\"identifier\":\"\(identifier)\",\"protocolVersion\":1,\"role\":\"\(newRole.rawValue)\""
        guard let range = source.range(of: needle) else {
            throw FixtureError.roleNotFound
        }
        var mutated = source
        mutated.replaceSubrange(range, with: replacement)
        return Data(mutated.utf8)
    }
}
