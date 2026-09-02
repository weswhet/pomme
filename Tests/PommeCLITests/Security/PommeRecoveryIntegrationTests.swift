import Foundation
import Testing

@Suite("Pomme Recovery integration facade")
struct PommeRecoveryIntegrationTests {
    @Test("Typed roles share the Recovery session and restore final state after cleanup")
    func typedRolesAndFinalState() async throws {
        let now = Date(timeIntervalSince1970: 60)
        let credential = try PommeRecoveryCredential(
            secret: Data(repeating: 0x5a, count: 32),
            expiresAt: now.addingTimeInterval(60)
        )
        let request = try PommeRecoverySessionRequest(
            vmUUID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            operation: .sip(.status),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            executableSHA256: String(repeating: "c", count: 64),
            payloadSHA256: PommeRecoveryCrypto.sha256(Data("status".utf8)),
            requestedFinalState: .previous,
            credential: credential
        )
        let vm = IntegrationVMMock()
        let guest = IntegrationGuestMock()
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: IntegrationRootMock(),
            vm: vm,
            guest: guest,
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )
        let recovery = PommeRecoveryIntegration(
            adapter: PommeRecoverySessionAdapter(session: session, credential: credential)
        )

        let result = try await recovery.sip(
            action: .status,
            payload: Data("status".utf8),
            finalState: .previous
        )
        #expect(result.output == Data("reply".utf8))
        #expect(result.cleanup.isComplete)
        #expect(result.evidence.lifecycle == .finalized)
        #expect(await vm.finalStates == [.normal])
        #expect(await guest.operations == ["sip.status"])

        // A typed AMFI call cannot repurpose a SIP-bound request, and the
        // rejected call cannot reach the guest or alter final-state history.
        await #expect(throws: PommeRecoverySecurityError.operationRejected) {
            try await recovery.amfi(action: .status, finalState: .normal)
        }
        #expect(await guest.operations == ["sip.status"])
        #expect(await vm.finalStates == [.normal])
    }
}

private actor IntegrationRootMock: PommeRecoveryRootPort {
    func prepare(request: PommeRecoverySessionRequest) async throws -> PommeRecoveryRootEvidence {
        .init(
            requestID: request.requestID,
            vmUUID: request.vmUUID,
            listenerPort: request.listenerPort,
            shareReadOnly: true,
            executableSignatureVerified: true,
            executableDigestVerified: true,
            inodeVerified: true,
            modeVerified: true,
            launcherInstalled: true,
            listenerReady: true
        )
    }

    func cleanup(request: PommeRecoverySessionRequest) async throws -> PommeRecoveryCleanupEvidence {
        .init(
            shareRemoved: true,
            launcherRemoved: true,
            credentialRemoved: true,
            listenerClosed: true,
            sensitiveFramesCleared: true,
            unknownStateRejected: true
        )
    }
}

private actor IntegrationVMMock: PommeRecoveryVMPort {
    private(set) var finalStates: [VMFinalState] = []

    func captureState() async throws -> PommeRecoveryRunState { .running(.normal) }

    func requestFinalState(_ state: VMFinalState) async throws {
        finalStates.append(state)
    }

    func proveFinalState(_ state: VMFinalState) async throws -> Bool {
        finalStates.last == state
    }
}

private actor IntegrationGuestMock: PommeRecoveryGuestPort {
    private(set) var operations: [String] = []

    func perform(operation: String, requestID: UUID, payload: Data) async throws -> Data {
        operations.append(operation)
        return Data("reply".utf8)
    }

    func close() async {}
}
