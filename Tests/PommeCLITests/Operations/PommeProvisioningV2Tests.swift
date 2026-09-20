import Foundation
import Testing

struct PommeProvisioningV2Tests {
    private let digest = String(repeating: "a", count: 64)
    private let volumeGroup = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test(arguments: ["27", "27.0", "27.1.2"])
    func supportedRoute(version: String) {
        #expect(PommeProvisioningV2RouteSelector.select(hostSupportsProvisioning: true, guestVersion: version) == .virtualization)
        #expect(PommeProvisioningV2RouteSelector.select(hostSupportsProvisioning: false, guestVersion: version) == nil)
    }

    @Test(arguments: ["26.6", "28", "270", "27beta", "27.", "27..0", " 27", "", "27.0 beta"])
    func unsupportedRoute(version: String) {
        #expect(PommeProvisioningV2RouteSelector.select(hostSupportsProvisioning: true, guestVersion: version) == nil)
    }

    @Test func integrityAndSecretOmission() throws {
        let signer = try signer()
        let plan = try plan()
        let journal = try signer.make(generation: 1, plan: plan, ownerReference: reference(plan), events: [])
        let data = try PommeProvisioningCoding.encode(journal)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("password") == false)
        #expect(text.contains("agentToken") == false)
        #expect(text.contains("privateKey") == false)
        #expect(try PommeProvisioningCoding.encode(JSONDecoder().decode(PommeProvisioningV2Journal.self, from: data)) == data)
        let altered = Data(text.replacingOccurrences(of: "\"generation\":1", with: "\"generation\":2").utf8)
        let decoded = try JSONDecoder().decode(PommeProvisioningV2Journal.self, from: altered)
        #expect(throws: PommeProvisioningV2Error.integrityFailure) { try signer.verify(decoded) }
        let otherSigner = try PommeProvisioningV2Signer(key: Data(repeating: 9, count: 32))
        #expect(throws: PommeProvisioningV2Error.integrityFailure) { try otherSigner.verify(journal) }
    }

    @Test func referenceRequiredBeforeProvisionIntent() throws {
        let signer = try signer()
        let plan = try plan()
        let events = history(pending: .provisionGuest)
        #expect(throws: PommeProvisioningV2Error.ownerReferenceRequired) {
            try signer.make(generation: 1, plan: plan, events: events)
        }
        let journal = try signer.make(generation: 1, plan: plan, ownerReference: reference(plan), events: events)
        try signer.verify(journal)
    }

    @Test func phaseOrderRejectsSkippingRepeatingAndInvalidAttempts() throws {
        let invalid: [[PommeProvisioningV2Event]] = [
            [.init(kind: .intent, phase: .provisionGuest, attempt: 1)],
            [.init(kind: .receipt, phase: .install, attempt: 1, digest: digest)],
            [.init(kind: .intent, phase: .install, attempt: 2)],
            [.init(kind: .intent, phase: .install, attempt: 1), .init(kind: .receipt, phase: .install, attempt: 2, digest: digest)],
            history(pending: .provisionGuest) + [.init(kind: .intent, phase: .provisionGuest, attempt: 2)],
        ]
        for events in invalid {
            #expect(throws: PommeProvisioningV2Error.unexpectedEvent) {
                try PommeProvisioningV2Coordinator.validate(events: events)
            }
        }
    }

    @Test func normalSequencePersistsIntentBeforeEffects() async throws {
        let repo = V2MemoryRepository()
        let calls = V2Calls()
        let plan = try plan()
        let orchestrator = PommeProvisioningV2Orchestrator(signer: try signer(), repository: repo,
            effects: try effects(repo: repo, calls: calls, plan: plan))
        try await orchestrator.start(plan)
        let result = try repo.load()
        #expect(result.startupVolumeGroupUUID == volumeGroup)
        #expect(result.events.filter { $0.kind == .receipt }.map(\.phase) == PommeProvisioningV2Phase.allCases)
        #expect(await calls.phases == PommeProvisioningV2Phase.allCases)
        #expect(await calls.prepares == 1)
        try await orchestrator.resume(expectedPlan: plan)
        #expect(await calls.prepares == 1)
        #expect(try repo.load() == result)
    }

    @Test(arguments: [PommeProvisioningV2Phase.bootstrapNormalAgent, .verifyNormalAgent, .restoreFinalState])
    func pendingSafePhasesResume(phase: PommeProvisioningV2Phase) async throws {
        let repo = V2MemoryRepository()
        let calls = V2Calls()
        let plan = try plan()
        let signer = try signer()
        let retained = try signer.make(generation: 1, plan: plan, ownerReference: reference(plan),
            startupVolumeGroupUUID: phase == .restoreFinalState ? volumeGroup : nil, events: history(pending: phase))
        try repo.create(retained)
        let orchestrator = PommeProvisioningV2Orchestrator(signer: signer, repository: repo,
            effects: try effects(repo: repo, calls: calls, plan: plan))
        try await orchestrator.resume(expectedPlan: plan)
        let completed = try repo.load()
        #expect(completed.startupVolumeGroupUUID == volumeGroup)
        #expect(completed.events.filter { $0.phase == phase && $0.kind == .intent }.count == 1)
        #expect(completed.ownerReference == retained.ownerReference)
        #expect(await calls.prepares == 0)
        #expect(await calls.phases.first == phase)
    }

    @Test(arguments: [false, true])
    func ambiguousProvisionFailsWithoutEffects(recordFailure: Bool) async throws {
        let repo = V2MemoryRepository()
        let calls = V2Calls()
        let plan = try plan()
        let signer = try signer()
        var events = history(pending: .provisionGuest)
        if recordFailure { events.append(.init(kind: .failure, phase: .provisionGuest, attempt: 1, digest: digest)) }
        let retained = try signer.make(generation: 1, plan: plan, ownerReference: reference(plan), events: events)
        try repo.create(retained)
        let orchestrator = PommeProvisioningV2Orchestrator(signer: signer, repository: repo,
            effects: try effects(repo: repo, calls: calls, plan: plan))
        await #expect(throws: PommeProvisioningV2Error.ambiguousProvisionGuest) {
            try await orchestrator.resume(expectedPlan: plan)
        }
        #expect(await calls.phases.isEmpty)
        #expect(await calls.prepares == 0)
        #expect(try repo.load() == retained)
    }

    @Test func interruptedInstallHasNoEffects() async throws {
        let phase = PommeProvisioningV2Phase.install
        let repo = V2MemoryRepository()
        let calls = V2Calls()
        let plan = try plan()
        let signer = try signer()
        let retained = try signer.make(generation: 1, plan: plan,
            ownerReference: reference(plan), events: history(pending: phase))
        try repo.create(retained)
        let orchestrator = PommeProvisioningV2Orchestrator(signer: signer, repository: repo,
            effects: try effects(repo: repo, calls: calls, plan: plan))
        await #expect(throws: PommeProvisioningV2Error.interruptedPhase(phase)) {
            try await orchestrator.resume(expectedPlan: plan)
        }
        #expect(await calls.phases.isEmpty)
        #expect(try repo.load() == retained)
    }

    @Test(arguments: [false, true])
    func provisionRetriesOnlyBeforeDispatchAndReusesOwner(recordFailure: Bool) async throws {
        let repo = V2MemoryRepository()
        let calls = V2Calls()
        let plan = try plan()
        let signer = try signer()
        var events = history(pending: .provisionGuest)
        if recordFailure { events.append(.init(kind: .failure, phase: .provisionGuest, attempt: 1, digest: digest)) }
        let retained = try signer.make(generation: 1, plan: plan, ownerReference: reference(plan), events: events)
        try repo.create(retained)
        var injected = try effects(repo: repo, calls: calls, plan: plan)
        injected.provisionGuestWasDispatched = { _ in false }
        let orchestrator = PommeProvisioningV2Orchestrator(signer: signer, repository: repo, effects: injected)
        try await orchestrator.resume(expectedPlan: plan)
        let completed = try repo.load()
        #expect(await calls.phases.first == .provisionGuest)
        #expect(await calls.prepares == 0)
        #expect(completed.ownerReference == retained.ownerReference)
        #expect(completed.events.first(where: { $0.phase == .provisionGuest && $0.kind == .receipt })?.attempt == (recordFailure ? 2 : 1))
        #expect(completed.events.last?.phase == .restoreFinalState)
        #expect(completed.events.last?.kind == .receipt)
    }

    @Test func uncertainDispatchReadFailsBeforeAnyProvisionEffect() async throws {
        let repo = V2MemoryRepository()
        let calls = V2Calls()
        let plan = try plan()
        let signer = try signer()
        let retained = try signer.make(generation: 1, plan: plan,
            ownerReference: reference(plan), events: history(pending: .provisionGuest))
        try repo.create(retained)
        var injected = try effects(repo: repo, calls: calls, plan: plan)
        injected.provisionGuestWasDispatched = { _ in throw PommeProvisioningV2Error.ambiguousProvisionGuest }
        let orchestrator = PommeProvisioningV2Orchestrator(signer: signer, repository: repo, effects: injected)
        await #expect(throws: PommeProvisioningV2Error.ambiguousProvisionGuest) { try await orchestrator.resume() }
        #expect(await calls.phases.isEmpty)
        #expect(await calls.prepares == 0)
        #expect(try repo.load() == retained)
    }

    @Test func failedBootstrapResumesNextAttempt() async throws {
        let repo = V2MemoryRepository()
        let calls = V2Calls()
        let plan = try plan()
        let signer = try signer()
        var events = history(pending: .bootstrapNormalAgent)
        events.append(.init(kind: .failure, phase: .bootstrapNormalAgent, attempt: 1, digest: digest))
        try repo.create(signer.make(generation: 1, plan: plan, ownerReference: reference(plan), events: events))
        let orchestrator = PommeProvisioningV2Orchestrator(signer: signer, repository: repo,
            effects: try effects(repo: repo, calls: calls, plan: plan))
        try await orchestrator.resume(expectedPlan: plan)
        #expect(try repo.load().events.filter { $0.phase == .bootstrapNormalAgent && $0.kind == .intent }.map(\.attempt) == [1, 2])
        #expect(await calls.prepares == 0)
    }

    @Test func privatePersistenceAndRollbackRejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-v2-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("provisioning-v2.json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: directory) }
        let highWater = V2HighWater()
        let signer = try signer()
        let repository = PommeFileProvisioningV2JournalRepository(journalURL: url, signer: signer,
            loadHighWater: { highWater.load() }, advanceHighWater: { try highWater.advance($0, $1) })
        let initial = try signer.make(generation: 1, plan: plan(), events: [])
        try repository.create(initial)
        #expect(try repository.load() == initial)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let next = try signer.make(generation: 2, plan: initial.plan, events: [.init(kind: .intent, phase: .install, attempt: 1)])
        try repository.commit(next, replacing: 1)
        #expect(highWater.load() == 2)
        #expect(throws: PommeProvisioningV2Error.generationFailure) { try repository.commit(next, replacing: 1) }
        // Simulate rollback of disk bytes while retaining the independently stored high-water mark.
        try PommeProvisioningCoding.encode(initial).write(to: url)
        #expect(throws: PommeProvisioningV2Error.generationFailure) { try repository.load() }
    }

    @Test func schemaOneEncodingRemainsSeparate() throws {
        let original = try PommeProvisioningJournalSigner(key: Data(repeating: 3, count: 32))
            .make(generation: 1, plan: plan(), events: [])
        let bytes = try PommeProvisioningCoding.encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "generation", "plan", "planDigest", "events", "integrity"])
        #expect(object["schema"] as? Int == 1)
        #expect(PommeProvisioningPhase.allCases.map(\.rawValue) == ["install", "installRecoveryAgent", "verifyNormalAgent", "restoreFinalState"])
        #expect(try PommeProvisioningCoding.encode(JSONDecoder().decode(PommeProvisioningJournal.self, from: bytes)) == bytes)
    }

    @Test(arguments: [false, true])
    func verifiedOwnerEnrichmentRejectsChangedBinding(changeBinding: Bool) async throws {
        let repo = V2MemoryRepository()
        let calls = V2Calls()
        let plan = try plan()
        let signer = try signer()
        let old = try reference(plan)
        let enriched = try PommeOwnerCredentialReference(identity: .init(
            vmName: plan.vm.name, vmUUID: plan.vm.uuid,
            machineIdentifierSHA256: changeBinding ? String(repeating: "b", count: 64) : old.machineIdentifierSHA256,
            diskImageFileResourceID: old.diskImageFileResourceID, startupVolumeGroupUUID: UUID(),
            immutableProvisioningPlanDigest: plan.digest), account: "pomme", generatedUID: UUID())
        var events = history(pending: .bootstrapNormalAgent)
        events.append(.init(kind: .receipt, phase: .bootstrapNormalAgent, attempt: 1, digest: digest))
        let retained = try signer.make(generation: 1, plan: plan, ownerReference: old, events: events)
        try repo.create(retained)
        let orchestrator = PommeProvisioningV2Orchestrator(signer: signer, repository: repo,
            effects: try effects(repo: repo, calls: calls, plan: plan, verifiedOwner: enriched))
        if changeBinding {
            await #expect(throws: PommeProvisioningV2Error.phaseFailed(.verifyNormalAgent)) {
                try await orchestrator.resume(expectedPlan: plan)
            }
            #expect(try repo.load().ownerReference == old)
        } else {
            try await orchestrator.resume(expectedPlan: plan)
            #expect(try repo.load().ownerReference == enriched)
        }
        let intent = try signer.make(generation: 2, plan: plan, ownerReference: old,
            events: events + [.init(kind: .intent, phase: .verifyNormalAgent, attempt: 1)])
        let receipt = try signer.make(generation: 3, plan: plan, ownerReference: enriched,
            startupVolumeGroupUUID: volumeGroup,
            events: intent.events + [.init(kind: .receipt, phase: .verifyNormalAgent, attempt: 1, digest: digest)])
        #expect(PommeFileProvisioningV2JournalRepository.allowsReferenceTransition(from: intent, to: receipt) == !changeBinding)
    }

    @Test func volumeGroupIsSignedAndEnrichedOnlyAtVerification() throws {
        let signer = try signer()
        let plan = try plan()
        let owner = try reference(plan)
        let intent = try signer.make(generation: 1, plan: plan, ownerReference: owner,
                                     events: history(pending: .verifyNormalAgent))
        let verifiedEvents = intent.events + [PommeProvisioningV2Event(kind: .receipt,
            phase: .verifyNormalAgent, attempt: 1, digest: digest)]
        #expect(throws: PommeProvisioningV2Error.startupVolumeGroupRequired) {
            try signer.make(generation: 2, plan: plan, ownerReference: owner, events: verifiedEvents)
        }
        #expect(throws: PommeProvisioningV2Error.startupVolumeGroupRequired) {
            try signer.make(generation: 1, plan: plan, ownerReference: owner,
                startupVolumeGroupUUID: volumeGroup, events: intent.events)
        }
        let receipt = try signer.make(generation: 2, plan: plan, ownerReference: owner,
            startupVolumeGroupUUID: volumeGroup, events: verifiedEvents)
        #expect(PommeFileProvisioningV2JournalRepository.allowsVolumeGroupTransition(from: intent, to: receipt))
        let changed = try signer.make(generation: 3, plan: plan, ownerReference: owner,
            startupVolumeGroupUUID: UUID(), events: verifiedEvents)
        #expect(PommeFileProvisioningV2JournalRepository.allowsVolumeGroupTransition(from: receipt, to: changed) == false)
        let encoded = String(decoding: try PommeProvisioningCoding.encode(receipt), as: UTF8.self)
        let altered = Data(encoded.replacingOccurrences(of: volumeGroup.uuidString,
            with: UUID().uuidString).utf8)
        let tampered = try JSONDecoder().decode(PommeProvisioningV2Journal.self, from: altered)
        #expect(throws: PommeProvisioningV2Error.integrityFailure) { try signer.verify(tampered) }
    }

    @Test func interruptedHighWaterUpdateReconcilesAndResumes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-v2-crash-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: directory) }
        let water = V2HighWater()
        let signer = try signer()
        let plan = try plan()
        let repository = PommeFileProvisioningV2JournalRepository(journalURL: url, signer: signer,
            loadHighWater: { water.load() }, advanceHighWater: { try water.advance($0, $1) })
        let events = Array(history(pending: .bootstrapNormalAgent).dropLast())
        let initial = try signer.make(generation: 1, plan: plan, ownerReference: reference(plan), events: events)
        try repository.create(initial)
        let intent = try signer.make(generation: 2, plan: plan, ownerReference: initial.ownerReference,
            events: history(pending: .bootstrapNormalAgent))
        water.failNextAdvance()
        #expect(throws: PommeProvisioningV2Error.generationFailure) { try repository.commit(intent, replacing: 1) }
        #expect(water.load() == 1)
        #expect(try JSONDecoder().decode(PommeProvisioningV2Journal.self, from: Data(contentsOf: url)) == intent)
        // Reconciliation itself must also fail closed if durable storage is unavailable.
        water.failNextAdvance()
        #expect(throws: PommeProvisioningV2Error.generationFailure) { try repository.load() }
        #expect(water.load() == 1)
        let calls = V2Calls()
        let orchestrator = PommeProvisioningV2Orchestrator(signer: signer, repository: repository,
            effects: try effects(repo: repository, calls: calls, plan: plan))
        try await orchestrator.resume(expectedPlan: plan)
        let completed = try repository.load()
        #expect(water.load() == completed.generation)
        #expect(await calls.phases == [.bootstrapNormalAgent, .verifyNormalAgent, .restoreFinalState])
        #expect(completed.events.filter { $0.phase == .bootstrapNormalAgent && $0.kind == .intent }.count == 1)
    }

    @Test(arguments: [UInt64(0), UInt64(3)])
    func highWaterRejectsGapsAndRollback(highWater: UInt64) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-v2-gap-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: directory) }
        let signer = try signer()
        let journal = try signer.make(generation: 2, plan: plan(), events: [])
        try PommeProvisioningCoding.encode(journal).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let repository = PommeFileProvisioningV2JournalRepository(journalURL: url, signer: signer,
            loadHighWater: { highWater }, advanceHighWater: { _, _ in Issue.record("Invalid gap must never advance high-water") })
        #expect(throws: PommeProvisioningV2Error.generationFailure) { try repository.load() }
    }

    private func signer() throws -> PommeProvisioningV2Signer { try .init(key: Data(repeating: 3, count: 32)) }

    private func plan() throws -> PommeProvisioningPlan {
        try .init(vm: .init(name: "pomme-v2-test", uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!, bundlePath: "/tmp/pomme-v2-test.macvm"),
            restore: .init(version: "27.0.0", build: "26A1", restoreImageDigest: digest), display: .required,
            profile: .init(descriptor: PommeRecoveryProfileSelector.descriptor(version: "27.0", build: "26A1")),
            normalAgent: .init(identifier: "normal", executableDigest: digest, role: .normal),
            recoveryAgent: .init(identifier: "recovery", executableDigest: digest, role: .recovery), finalState: .normalRunning)
    }

    private func reference(_ plan: PommeProvisioningPlan) throws -> PommeOwnerCredentialReference {
        try .init(identity: .init(vmName: plan.vm.name, vmUUID: plan.vm.uuid,
            machineIdentifierSHA256: digest, diskImageFileResourceID: "disk-1", startupVolumeGroupUUID: UUID(),
            immutableProvisioningPlanDigest: plan.digest), account: "pomme")
    }

    private func history(pending: PommeProvisioningV2Phase) -> [PommeProvisioningV2Event] {
        var events: [PommeProvisioningV2Event] = []
        for phase in PommeProvisioningV2Phase.allCases {
            events.append(.init(kind: .intent, phase: phase, attempt: 1))
            if phase == pending { break }
            events.append(.init(kind: .receipt, phase: phase, attempt: 1, digest: digest))
        }
        return events
    }

    private func effects(repo: any PommeProvisioningV2JournalRepository, calls: V2Calls, plan: PommeProvisioningPlan,
                         verifiedOwner: PommeOwnerCredentialReference? = nil) throws -> PommeProvisioningV2Effects {
        let owner = try reference(plan)
        let action: @Sendable (PommeProvisioningV2Phase) async throws -> String = { phase in
            let journal = try repo.load()
            #expect(journal.events.last?.kind == .intent)
            #expect(journal.events.last?.phase == phase)
            if phase != .install { #expect(journal.ownerReference != nil) }
            await calls.record(phase)
            return self.digest
        }
        return .init(verifyOwnership: { $0 }, prepareOwnerReference: { _ in await calls.prepare(); return owner },
            install: { _ in try await action(.install) }, provisionGuest: { _ in try await action(.provisionGuest) },
            bootstrapNormalAgent: { _ in try await action(.bootstrapNormalAgent) },
            verifyNormalAgent: { _ in .init(receiptDigest: try await action(.verifyNormalAgent), ownerReference: verifiedOwner, startupVolumeGroupUUID: self.volumeGroup) }, restoreFinalState: { _ in try await action(.restoreFinalState) })
    }
}

private final class V2MemoryRepository: PommeProvisioningV2JournalRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var journal: PommeProvisioningV2Journal?
    func create(_ journal: PommeProvisioningV2Journal) throws {
        try lock.withLock {
            guard self.journal == nil else { throw PommeProvisioningV2Error.generationFailure }
            self.journal = journal
        }
    }
    func load() throws -> PommeProvisioningV2Journal {
        try lock.withLock {
            guard let journal else { throw PommeProvisioningV2Error.invalidJournal }
            return journal
        }
    }
    func commit(_ journal: PommeProvisioningV2Journal, replacing generation: UInt64) throws {
        try lock.withLock {
            guard self.journal?.generation == generation else { throw PommeProvisioningV2Error.generationFailure }
            self.journal = journal
        }
    }
}

private final class V2HighWater: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var shouldFail = false
    func failNextAdvance() { lock.withLock { shouldFail = true } }
    func load() -> UInt64 { lock.withLock { value } }
    func advance(_ expected: UInt64, _ next: UInt64) throws {
        try lock.withLock {
            if shouldFail { shouldFail = false; throw PommeProvisioningV2Error.generationFailure }
            guard value == expected, next > value else { throw PommeProvisioningV2Error.generationFailure }
            value = next
        }
    }
}

private actor V2Calls {
    var phases: [PommeProvisioningV2Phase] = []
    var prepares = 0
    func record(_ phase: PommeProvisioningV2Phase) { phases.append(phase) }
    func prepare() { prepares += 1 }
}
