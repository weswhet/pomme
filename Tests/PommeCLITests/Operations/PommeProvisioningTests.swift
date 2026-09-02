import Foundation
import Testing

@Suite("Pomme durable provisioning")
struct PommeProvisioningTests {
    private let digest = String(repeating: "a", count: 64)

    @Test("closed plan accepts only the reviewed Tahoe profile")
    func closedProfile() throws {
        _ = try plan()
        #expect(throws: PommeProvisioningError.self) {
            _ = try plan(profile: .sequoia)
        }
    }

    @Test("HMAC covers schema, immutable plan, journal history, and generation")
    func journalIntegrity() throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 7, count: 32))
        let journal = try signer.make(generation: 1, plan: plan(), events: [])
        try signer.verify(journal)
        let replacement = try PommeProvisioningJournal(
            generation: journal.generation,
            plan: journal.plan,
            events: journal.events,
            integrity: Data(repeating: 1, count: 32).base64EncodedString()
        )
        #expect(throws: PommeProvisioningError.self) { try signer.verify(replacement) }
    }

    @Test("intent commits before every effect and failed partial effects retain the VM and journal")
    func intentBeforeEffectAndFailureRetention() async throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 1, count: 32))
        let repository = MemoryRepository()
        let calls = CallLog()
        let orchestrator = PommeProvisioningOrchestrator(
            signer: signer,
            repository: repository,
            effects: effects(calls: calls, fail: .installRecoveryAgent)
        )
        await #expect(throws: PommeProvisioningError.self) { try await orchestrator.start(plan()) }
        let journal = try repository.load()
        #expect(journal.events.map(\.kind) == [.intent, .receipt, .intent, .receipt, .intent, .failure])
        #expect(await calls.phases == [.install, .displayOnlyFirstNormalBoot, .installRecoveryAgent])
    }

    @Test("resume revalidates exact ownership, retries a failed phase, and is idempotent after completion")
    func resumeIdempotenceAndOwnership() async throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 2, count: 32))
        let repository = MemoryRepository()
        let calls = CallLog()
        let good = effects(calls: calls)
        let orchestrator = PommeProvisioningOrchestrator(signer: signer, repository: repository, effects: good)
        try await orchestrator.start(plan())
        let count = await calls.phases.count
        try await orchestrator.resume(expectedPlan: plan())
        #expect(await calls.phases.count == count)

        let rejected = PommeProvisioningOrchestrator(
            signer: signer,
            repository: repository,
            effects: .init(
                verifyOwnership: { expected in try PommeVMOwnership(name: expected.name, uuid: UUID(), bundlePath: expected.bundlePath) },
                install: { _ in self.digest }, displayOnlyFirstNormalBoot: { _ in self.digest },
                installRecoveryAgent: { _ in self.digest }, verifyNormalAgent: { _ in self.digest },
                restoreFinalState: { _ in self.digest }, recoveryRepair: { _, _ in self.digest }
            )
        )
        await #expect(throws: PommeProvisioningError.self) { try await rejected.resume(expectedPlan: self.plan()) }
    }

    @Test("repair is Recovery-only through the dedicated effect and restores only the requested final state")
    func recoveryOnlyRepair() async throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 3, count: 32))
        let repository = MemoryRepository()
        let calls = CallLog()
        let orchestrator = PommeProvisioningOrchestrator(signer: signer, repository: repository, effects: effects(calls: calls))
        try await orchestrator.start(plan())
        try await orchestrator.repair(finalState: .normalRunning)
        #expect(await calls.repairStates == [.normalRunning])
    }

    private func plan(profile: PommeRecoveryProfileContract = .tahoe) throws -> PommeProvisioningPlan {
        try .init(
            vm: .init(name: "pomme-test", uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!, bundlePath: "/tmp/pomme-test.macvm"),
            restore: .init(version: "26.6.0", build: "25G72", restoreImageDigest: digest),
            display: .required,
            profile: profile,
            normalAgent: try .init(identifier: "com.github.weswhet.pomme.agent", executableDigest: digest, role: .normal),
            recoveryAgent: try .init(identifier: "com.github.weswhet.pomme.recovery", executableDigest: digest, role: .recovery),
            finalState: .normalRunning
        )
    }

    private func effects(calls: CallLog, fail: PommeProvisioningPhase? = nil) -> PommeProvisioningEffects {
        .init(
            verifyOwnership: { $0 },
            install: { _ in try await calls.record(.install, digest: self.digest, fail: fail) },
            displayOnlyFirstNormalBoot: { _ in try await calls.record(.displayOnlyFirstNormalBoot, digest: self.digest, fail: fail) },
            installRecoveryAgent: { _ in try await calls.record(.installRecoveryAgent, digest: self.digest, fail: fail) },
            verifyNormalAgent: { _ in try await calls.record(.verifyNormalAgent, digest: self.digest, fail: fail) },
            restoreFinalState: { _ in try await calls.record(.restoreFinalState, digest: self.digest, fail: fail) },
            recoveryRepair: { _, state in await calls.recordRepair(state, digest: self.digest) }
        )
    }
}

private final class MemoryRepository: PommeProvisioningJournalRepository, @unchecked Sendable {
    private var journal: PommeProvisioningJournal?

    func create(_ journal: PommeProvisioningJournal) throws {
        guard self.journal == nil else { throw PommeProvisioningError.generationFailure }
        self.journal = journal
    }

    func load() throws -> PommeProvisioningJournal {
        guard let journal else { throw PommeProvisioningError.invalidJournal }
        return journal
    }

    func commit(_ journal: PommeProvisioningJournal, replacing generation: UInt64) throws {
        guard self.journal?.generation == generation else { throw PommeProvisioningError.generationFailure }
        self.journal = journal
    }
}

private actor CallLog {
    var phases: [PommeProvisioningPhase] = []
    var repairStates: [PommeProvisioningFinalState] = []

    func record(_ phase: PommeProvisioningPhase, digest: String, fail: PommeProvisioningPhase?) throws -> String {
        phases.append(phase)
        if fail == phase { throw PommeProvisioningError.phaseFailed(phase) }
        return digest
    }

    func recordRepair(_ state: PommeProvisioningFinalState, digest: String) -> String {
        repairStates.append(state)
        return digest
    }
}
