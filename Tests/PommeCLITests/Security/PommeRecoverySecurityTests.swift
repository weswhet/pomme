import Foundation
import Testing

@Suite("Pomme Recovery security")
struct PommeRecoverySecurityTests {
    @Test("AMFI disable preserves unrelated boot arguments")
    func preservesBootArguments() async throws {
        let originalArguments = "debug=1 keeps-me=two"
        let originalDelta = try PommeNVRAMDelta.bootArguments(present: true, value: originalArguments)
        let original = try PommeAMFISecuritySnapshot(
            localPolicy: Data("local-policy-before".utf8),
            nvram: originalDelta,
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let store = AMFIStore(snapshot: original)
        let transaction = PommeAMFITransaction(dependencies: .init(
            capture: { await store.snapshot() },
            applyLocalPolicy: { data in await store.setPolicy(data) },
            applyNVRAM: { delta in await store.setNVRAM(delta) },
            read: { await store.snapshot() }
        ))
        let currentBootArguments = try PommeNVRAMValue(present: true, value: originalArguments)
        let report = try await transaction.disable(
            localPolicy: Data("local-policy-disabled".utf8),
            currentBootArguments: currentBootArguments
        )
        #expect(report.verified)
        let after = await store.snapshot()
        let value = after.nvram.values["boot-args"]?.value
        #expect(value?.contains("debug=1") == true)
        #expect(value?.contains("keeps-me=two") == true)
        #expect(value?.contains(PommeBootArguments.amfiOverride) == true)
    }

    @Test("AMFI disable retains unrelated NVRAM keys in the exact mutation")
    func preservesUnrelatedNVRAM() async throws {
        let originalDelta = try PommeNVRAMDelta(values: [
            "boot-args": try PommeNVRAMValue(present: true, value: "keep=1"),
            "other-setting": try PommeNVRAMValue(present: true, value: "untouched")
        ])
        let original = try PommeAMFISecuritySnapshot(
            localPolicy: Data("before-all-keys".utf8),
            nvram: originalDelta
        )
        let store = AMFIStore(snapshot: original)
        let transaction = PommeAMFITransaction(dependencies: .init(
            capture: { await store.snapshot() },
            applyLocalPolicy: { data in await store.setPolicy(data) },
            applyNVRAM: { delta in await store.setNVRAM(delta) },
            read: { await store.snapshot() }
        ))
        _ = try await transaction.disable(
            localPolicy: Data("after-all-keys".utf8),
            currentNVRAM: originalDelta
        )
        let after = await store.snapshot()
        #expect(after.nvram.value(for: "other-setting")?.value == "untouched")
        #expect(PommeBootArguments.containsOverride(after.nvram.value(for: "boot-args")?.value))
    }

    @Test("A partial LocalPolicy/NVRAM mutation rolls both resources back")
    func atomicRollback() async throws {
        let original = try PommeAMFISecuritySnapshot(
            localPolicy: Data("before".utf8),
            nvram: try PommeNVRAMDelta.bootArguments(present: true, value: "keep=1"),
            capturedAt: Date(timeIntervalSince1970: 20)
        )
        let store = AMFIStore(snapshot: original, failNextNVRAMWrite: true)
        let transaction = PommeAMFITransaction(dependencies: .init(
            capture: { await store.snapshot() },
            applyLocalPolicy: { data in await store.setPolicy(data) },
            applyNVRAM: { delta in try await store.setNVRAMOrFail(delta) },
            read: { await store.snapshot() }
        ))
        let mutation = try PommeAMFIMutation(
            localPolicy: Data("after".utf8),
            nvram: try PommeNVRAMDelta.bootArguments(present: true, value: "keep=1 (PommeBootArguments.amfiOverride)")
        )
        await #expect(throws: PommeRecoverySecurityError.operationRejected) {
            try await transaction.execute(mutation)
        }
        #expect(await store.snapshot() == original)
    }

    @Test("AMFI enable restores an absent boot-args key exactly")
    func restoresAbsentBootArguments() async throws {
        let original = try PommeAMFISecuritySnapshot(
            localPolicy: Data("before".utf8),
            nvram: try PommeNVRAMDelta.bootArguments(present: false, value: nil),
            capturedAt: Date(timeIntervalSince1970: 30)
        )
        let store = AMFIStore(snapshot: original)
        let transaction = PommeAMFITransaction(dependencies: .init(
            capture: { await store.snapshot() },
            applyLocalPolicy: { data in await store.setPolicy(data) },
            applyNVRAM: { delta in await store.setNVRAM(delta) },
            read: { await store.snapshot() }
        ))
        let report = try await transaction.enable(using: original)
        #expect(report.verified)
        #expect(await store.snapshot() == original)
    }

    @Test("SIP and AMFI routing requires an authenticated Recovery session")
    func recoveryOnlyRouting() async throws {
        let now = Date(timeIntervalSince1970: 40)
        let credential = try PommeRecoveryCredential(secret: Data(repeating: 4, count: 32), expiresAt: now.addingTimeInterval(60))
        let request = try PommeRecoverySessionRequest(
            vmUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            operation: .amfi(.status),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            executableSHA256: String(repeating: "b", count: 64),
            credential: credential
        )
        let guest = SecurityGuestMock()
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: SecurityRootMock(),
            vm: SecurityVMMock(),
            guest: guest,
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )
        _ = try await session.prepare()
        let challenge = try await session.challenge()
        let proof = credential.proof(for: request, challenge: challenge)
        _ = try await session.authenticate(challenge: challenge, proof: proof)
        let router = PommeRecoverySecurityRouter(session: session)
        _ = try await router.execute(action: AMFIAction.status)
        #expect(await guest.operations == ["amfi.status"])
    }

    @Test("An unauthenticated security router cannot reach the guest")
    func unauthenticatedRouting() async throws {
        let now = Date(timeIntervalSince1970: 45)
        let credential = try PommeRecoveryCredential(
            secret: Data(repeating: 6, count: 32),
            expiresAt: now.addingTimeInterval(60)
        )
        let request = try PommeRecoverySessionRequest(
            vmUUID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            operation: .sip(.disable),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30),
            executableSHA256: String(repeating: "d", count: 64),
            credential: credential
        )
        let guest = SecurityGuestMock()
        let session = try PommeRecoverySession(
            request: request,
            credential: credential,
            root: SecurityRootMock(),
            vm: SecurityVMMock(),
            guest: guest,
            registry: PommeRecoveryCredentialRegistry(),
            now: { now }
        )
        _ = try await session.prepare()
        let router = PommeRecoverySecurityRouter(session: session)
        await #expect(throws: PommeRecoverySecurityError.operationRejected) {
            try await router.execute(action: SIPAction.disable)
        }
        #expect(await guest.operations.isEmpty)
    }
}

private actor AMFIStore {
    private var value: PommeAMFISecuritySnapshot
    private var failNextNVRAMWrite: Bool

    init(snapshot: PommeAMFISecuritySnapshot, failNextNVRAMWrite: Bool = false) {
        value = snapshot
        self.failNextNVRAMWrite = failNextNVRAMWrite
    }

    func snapshot() -> PommeAMFISecuritySnapshot { value }
    func setPolicy(_ data: Data) {
        value = try! PommeAMFISecuritySnapshot(localPolicy: data, nvram: value.nvram, capturedAt: value.capturedAt)
    }
    func setNVRAM(_ delta: PommeNVRAMDelta) {
        value = try! PommeAMFISecuritySnapshot(localPolicy: value.localPolicy, nvram: delta, capturedAt: value.capturedAt)
    }
    func setNVRAMOrFail(_ delta: PommeNVRAMDelta) throws {
        if failNextNVRAMWrite {
            failNextNVRAMWrite = false
            throw PommeRecoverySecurityError.operationRejected
        }
        setNVRAM(delta)
    }
}

private actor SecurityRootMock: PommeRecoveryRootPort {
    func prepare(request: PommeRecoverySessionRequest) async throws -> PommeRecoveryRootEvidence {
        .init(requestID: request.requestID, vmUUID: request.vmUUID, listenerPort: request.listenerPort,
              shareReadOnly: true, executableSignatureVerified: true, executableDigestVerified: true,
              inodeVerified: true, modeVerified: true, launcherInstalled: true, listenerReady: true)
    }
    func cleanup(request: PommeRecoverySessionRequest) async throws -> PommeRecoveryCleanupEvidence {
        .init(shareRemoved: true, launcherRemoved: true, credentialRemoved: true,
              listenerClosed: true, sensitiveFramesCleared: true, unknownStateRejected: true)
    }
}

private actor SecurityVMMock: PommeRecoveryVMPort {
    func captureState() async throws -> PommeRecoveryRunState { .stopped }
    func requestFinalState(_ state: VMFinalState) async throws {}
    func proveFinalState(_ state: VMFinalState) async throws -> Bool { true }
}

private actor SecurityGuestMock: PommeRecoveryGuestPort {
    private(set) var operations: [String] = []
    func perform(operation: String, requestID: UUID, payload: Data) async throws -> Data {
        operations.append(operation)
        return Data()
    }
    func close() async {}
}
