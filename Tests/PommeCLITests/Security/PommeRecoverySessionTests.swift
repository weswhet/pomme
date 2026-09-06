import Foundation
import Testing

@Suite("Pomme Recovery session")
struct PommeRecoverySessionTests {
    @Test("The listener set is closed over the two Recovery ports")
    func listenerPorts() {
        #expect(PommeRecoveryListenerPort.allCases.map(\.rawValue) == [505_052, 505_053])
    }

    @Test("HMAC admission consumes a credential once and rejects replay")
    func oneShotCredential() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try request(credential: credential, issuedAt: now, expiresAt: now.addingTimeInterval(30))
        let root = RootMock(request: request)
        let vm = VMMock()
        let guest = GuestMock()
        let registry = PommeRecoveryCredentialRegistry()
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: root,
            vm: vm,
            guest: guest,
            registry: registry,
            now: { now }
        )
        _ = try await session.prepare()
        let challenge = try await session.challenge()
        let proof = credential.proof(for: request, challenge: challenge)
        let admitted = try await session.authenticate(challenge: challenge, proof: proof)
        #expect(admitted.authenticated)
        #expect(admitted.credentialConsumed)
        await #expect(throws: PommeRecoverySessionError.replayedCredential) {
            try await session.authenticate(challenge: challenge, proof: proof)
        }
    }

    @Test("Expired credentials are rejected before the guest operation")
    func expiry() async throws {
        let issued = Date(timeIntervalSince1970: 2_000)
        let credential = try credential(expiresAt: issued.addingTimeInterval(10))
        let request = try request(credential: credential, issuedAt: issued, expiresAt: issued.addingTimeInterval(5))
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: RootMock(request: request),
            vm: VMMock(),
            guest: GuestMock(),
            registry: PommeRecoveryCredentialRegistry(),
            now: { issued.addingTimeInterval(6) }
        )
        await #expect(throws: PommeRecoverySessionError.expiredCredential) {
            try await session.prepare()
        }
    }

    @Test("The request binds VM identity, operation, payload, final state, port, and credential digest")
    func requestBinding() async throws {
        let now = Date(timeIntervalSince1970: 3_000)
        let first = try credential(expiresAt: now.addingTimeInterval(60))
        let second = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try request(credential: first, issuedAt: now, expiresAt: now.addingTimeInterval(30))
        #expect(throws: PommeRecoverySessionError.requestMismatch) {
            try PommeRecoverySession(
                request: request,
                credential: second,
                root: RootMock(request: request),
                vm: VMMock(),
                guest: GuestMock(),
                registry: PommeRecoveryCredentialRegistry(),
                now: { now }
            )
        }
        #expect(throws: PommeRecoverySessionError.invalidRequest) {
            try PommeRecoverySessionRequest(
                requestID: request.requestID,
                vmUUID: request.vmUUID,
                operation: request.operation,
                listenerPort: PommeRecoveryListenerPort.bootstrap.rawValue,
                issuedAt: request.issuedAt,
                expiresAt: request.expiresAt,
                executableSHA256: request.executableSHA256,
                payloadSHA256: request.payloadSHA256,
                requestedFinalState: request.requestedFinalState,
                credentialID: request.credentialID,
                credentialSHA256: request.credentialSHA256
            )
        }
    }

    @Test("Payload drift is rejected and a Recovery operation cannot be replayed")
    func payloadAndOperationAreOneShot() async throws {
        let now = Date(timeIntervalSince1970: 3_500)
        let payload = Data("bound".utf8)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try PommeRecoverySessionRequest(
            vmUUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            operation: .sip(.status),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            executableSHA256: String(repeating: "a", count: 64),
            payloadSHA256: PommeRecoveryCrypto.sha256(payload),
            requestedFinalState: .stopped,
            credential: credential
        )
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: RootMock(request: request),
            vm: VMMock(),
            guest: GuestMock(),
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )
        _ = try await session.prepare()
        let challenge = try await session.challenge()
        _ = try await session.authenticate(
            challenge: challenge,
            proof: credential.proof(for: request, challenge: challenge)
        )

        await #expect(throws: PommeRecoverySessionError.unauthenticated) {
            try await session.perform(payload: Data("drifted".utf8))
        }

        // A payload rejection happens before the attempt is committed. The
        // exact bound payload may execute once, but never twice.
        _ = try await session.perform(payload: payload)
        await #expect(throws: PommeRecoverySessionError.unauthenticated) {
            try await session.perform(payload: payload)
        }
    }

    @Test("Cleanup is required before a final-state request on operation failure")
    func cleanupAuthoritative() async throws {
        let now = Date(timeIntervalSince1970: 4_000)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try request(credential: credential, issuedAt: now, expiresAt: now.addingTimeInterval(30))
        let root = RootMock(request: request)
        let vm = VMMock()
        let guest = GuestMock(failure: true)
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: root,
            vm: vm,
            guest: guest,
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )
        _ = try await session.prepare()
        let challenge = try await session.challenge()
        let proof = credential.proof(for: request, challenge: challenge)
        await #expect(throws: PommeRecoverySessionError.guestOperationFailed) {
            try await session.execute(
                challenge: challenge,
                proof: proof,
                finalState: .stopped
            )
        }
        #expect(await root.cleanupCount == 1)
        #expect(await vm.finalStateRequests == [.stopped])
    }

    @Test("Cleanup failure prevents the requested final state")
    func cleanupFailureBlocksFinalState() async throws {
        let now = Date(timeIntervalSince1970: 5_000)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try request(credential: credential, issuedAt: now, expiresAt: now.addingTimeInterval(30))
        let root = RootMock(request: request, cleanupComplete: false)
        let vm = VMMock()
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: root,
            vm: vm,
            guest: GuestMock(),
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )
        _ = try await session.prepare()
        let challenge = try await session.challenge()
        let proof = credential.proof(for: request, challenge: challenge)
        await #expect(throws: PommeRecoverySessionError.cleanupFailed) {
            try await session.execute(challenge: challenge, proof: proof, finalState: .normal)
        }
        #expect(await vm.finalStateRequests.isEmpty)
    }

    @Test("A preparation failure still restores the captured previous state")
    func preparationFailureRestoresPrevious() async throws {
        let now = Date(timeIntervalSince1970: 5_500)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try PommeRecoverySessionRequest(
            vmUUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            operation: .sip(.status),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            executableSHA256: String(repeating: "a", count: 64),
            requestedFinalState: .previous,
            credential: credential
        )
        let root = RootMock(request: request, prepareFailure: true)
        let vm = VMMock()
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: root,
            vm: vm,
            guest: GuestMock(),
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )

        await #expect(throws: PommeRecoverySessionError.rootEvidenceRejected) {
            _ = try await session.run(finalState: .previous)
        }
        #expect(await root.cleanupCount == 1)
        #expect(await vm.finalStateRequests == [.stopped])
    }

    @Test("An unknown preparation error is closed without being called root evidence rejection")
    func unknownPreparationFailureIsClosed() async throws {
        let now = Date(timeIntervalSince1970: 5_600)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try request(
            credential: credential,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            requestedFinalState: .previous
        )
        let root = RootMock(request: request, unexpectedPrepareFailure: true)
        let vm = VMMock()
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: root,
            vm: vm,
            guest: GuestMock(),
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )

        await #expect(throws: PommeRecoverySessionError.preparationFailed) {
            _ = try await session.run(finalState: .previous)
        }
        #expect(await root.cleanupCount == 1)
        #expect(await vm.finalStateRequests == [.stopped])
    }

    @Test("A known runtime preparation error retains its closed type through cleanup")
    func knownRuntimePreparationFailureIsPreserved() async throws {
        let now = Date(timeIntervalSince1970: 5_625)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try request(
            credential: credential,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            requestedFinalState: .previous
        )
        let root = RootMock(
            request: request,
            runtimePrepareFailure: .listenerAuthenticationTimedOut
        )
        let vm = VMMock()
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: root,
            vm: vm,
            guest: GuestMock(),
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )

        await #expect(throws: PommeRecoveryRuntimeError.listenerAuthenticationTimedOut) {
            _ = try await session.run(finalState: .previous)
        }
        #expect(await root.cleanupCount == 1)
        #expect(await vm.finalStateRequests == [.stopped])
    }

    @Test("Cancellation during preparation remains cancellation")
    func preparationCancellationIsPreserved() async throws {
        let now = Date(timeIntervalSince1970: 5_650)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try request(
            credential: credential,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: RootMock(request: request, cancelledPrepare: true),
            vm: VMMock(),
            guest: GuestMock(),
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await session.prepare()
        }
    }

    @Test("A failed final-state proof attempts to restore the captured state")
    func finalStateProofFailureRestoresCapture() async throws {
        let now = Date(timeIntervalSince1970: 5_750)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try PommeRecoverySessionRequest(
            vmUUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            operation: .sip(.status),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            executableSHA256: String(repeating: "a", count: 64),
            requestedFinalState: .normal,
            credential: credential
        )
        let vm = VMMock(proofResults: [false, true])
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: RootMock(request: request),
            vm: vm,
            guest: GuestMock(),
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )

        await #expect(throws: PommeRecoverySessionError.finalStateUnverified) {
            _ = try await session.run(finalState: .normal)
        }
        #expect(await vm.finalStateRequests == [.normal, .stopped])
        #expect(await vm.provenFinalStates == [.normal, .stopped])
    }

    @Test("A closed guest failure survives session cleanup and final-state restoration")
    func typedGuestFailureSurvivesCleanup() async throws {
        let now = Date(timeIntervalSince1970: 5_800)
        let credential = try credential(expiresAt: now.addingTimeInterval(60))
        let request = try request(credential: credential, issuedAt: now, expiresAt: now.addingTimeInterval(30))
        let root = RootMock(request: request)
        let vm = VMMock()
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: root,
            vm: vm,
            guest: GuestMock(failureCode: .rollbackFailed),
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )

        do {
            _ = try await session.run(finalState: .stopped)
            Issue.record("The typed guest failure was reported as success.")
        } catch let error as PommeRecoveryGuestOperationFailure {
            #expect(error.code == .rollbackFailed)
            #expect(error.phase == .rollbackFailed)
            #expect(error.localizedDescription.contains("retained transaction"))
        }
        #expect(await root.cleanupCount == 1)
        #expect(await vm.finalStateRequests == [.stopped])
    }

    private func credential(expiresAt: Date) throws -> PommeRecoveryCredential {
        try .init(secret: Data(repeating: 0x2a, count: 32), expiresAt: expiresAt)
    }

    private func request(
        credential: PommeRecoveryCredential,
        issuedAt: Date,
        expiresAt: Date,
        requestedFinalState: VMFinalState = .stopped
    ) throws -> PommeRecoverySessionRequest {
        try .init(
            vmUUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            operation: .sip(.status),
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            executableSHA256: String(repeating: "a", count: 64),
            requestedFinalState: requestedFinalState,
            credential: credential
        )
    }
}

private actor RootMock: PommeRecoveryRootPort {
    let request: PommeRecoverySessionRequest
    let cleanupComplete: Bool
    let prepareFailure: Bool
    let runtimePrepareFailure: PommeRecoveryRuntimeError?
    let unexpectedPrepareFailure: Bool
    let cancelledPrepare: Bool
    private(set) var cleanupCount = 0

    init(
        request: PommeRecoverySessionRequest,
        cleanupComplete: Bool = true,
        prepareFailure: Bool = false,
        runtimePrepareFailure: PommeRecoveryRuntimeError? = nil,
        unexpectedPrepareFailure: Bool = false,
        cancelledPrepare: Bool = false
    ) {
        self.request = request
        self.cleanupComplete = cleanupComplete
        self.prepareFailure = prepareFailure
        self.runtimePrepareFailure = runtimePrepareFailure
        self.unexpectedPrepareFailure = unexpectedPrepareFailure
        self.cancelledPrepare = cancelledPrepare
    }

    func prepare(request: PommeRecoverySessionRequest) async throws -> PommeRecoveryRootEvidence {
        if prepareFailure { throw PommeRecoverySessionError.rootEvidenceRejected }
        if let runtimePrepareFailure { throw runtimePrepareFailure }
        if unexpectedPrepareFailure { throw UnexpectedPreparationFailure.failed }
        if cancelledPrepare { throw CancellationError() }
        return .init(
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
        cleanupCount += 1
        return .init(
            shareRemoved: cleanupComplete,
            launcherRemoved: cleanupComplete,
            credentialRemoved: cleanupComplete,
            listenerClosed: cleanupComplete,
            sensitiveFramesCleared: cleanupComplete,
            unknownStateRejected: cleanupComplete
        )
    }
}

private enum UnexpectedPreparationFailure: Error {
    case failed
}

private actor VMMock: PommeRecoveryVMPort {
    private(set) var finalStateRequests: [VMFinalState] = []
    private(set) var provenFinalStates: [VMFinalState] = []
    private var proofResults: [Bool]

    init(proofResults: [Bool] = []) {
        self.proofResults = proofResults
    }

    func captureState() async throws -> PommeRecoveryRunState { .stopped }

    func requestFinalState(_ state: VMFinalState) async throws {
        finalStateRequests.append(state)
    }

    func proveFinalState(_ state: VMFinalState) async throws -> Bool {
        provenFinalStates.append(state)
        if !proofResults.isEmpty { return proofResults.removeFirst() }
        return finalStateRequests.last == state
    }
}

private actor GuestMock: PommeRecoveryGuestPort {
    let failure: Bool
    let failureCode: PommeRecoveryGuestFailureCode?

    init(failure: Bool = false, failureCode: PommeRecoveryGuestFailureCode? = nil) {
        self.failure = failure
        self.failureCode = failureCode
    }

    func perform(operation: String, requestID: UUID, payload: Data) async throws -> Data {
        if let failureCode { throw PommeRecoveryGuestOperationFailure(code: failureCode) }
        if failure { throw PommeRecoverySessionError.guestOperationFailed }
        return Data("ok".utf8)
    }

    func close() async {}
}
