import Foundation
import Testing

@Suite("Pomme durable provisioning")
struct PommeProvisioningTests {
    private let digest = String(repeating: "a", count: 64)

    @Test("plans retain reviewed Tahoe and explicit experimental qualifications")
    func closedProfile() throws {
        _ = try plan()
        #expect(throws: PommeProvisioningError.self) {
            _ = try plan(profile: .sequoia)
        }
    }

    @Test("new Tahoe builds produce deterministic experimental contracts")
    func experimentalProfileContract() throws {
        let descriptor = try PommeRecoveryProfileSelector.descriptor(
            version: "26.6.2",
            build: "25G83"
        )
        let normalizedDescriptor = try PommeRecoveryProfileSelector.descriptor(
            version: "026.06.002",
            build: "25g83"
        )
        let distinctPatchDescriptor = try PommeRecoveryProfileSelector.descriptor(
            version: "26.6.3",
            build: "25G83"
        )
        let contract = try PommeRecoveryProfileContract(descriptor: descriptor)

        #expect(descriptor.qualification == .experimental)
        #expect(descriptor == normalizedDescriptor)
        #expect(descriptor.digest == normalizedDescriptor.digest)
        #expect(descriptor != distinctPatchDescriptor)
        #expect(descriptor.digest != distinctPatchDescriptor.digest)
        #expect(contract.identifier == descriptor.id)
        #expect(contract.version == "26.6.2")
        #expect(contract.build == "25G83")
        #expect(contract.qualification == .experimental)
        #expect(contract.reviewDigest.isEmpty)
        #expect(contract.isUsable(
            for: .init(version: "26.6.2", build: "25G83", restoreImageDigest: digest),
            display: .required
        ))
        #expect(!contract.isAccepted(
            for: .init(version: "26.6.2", build: "25G83", restoreImageDigest: digest),
            display: .required
        ))
        _ = try plan(profile: contract, version: "26.6.2", build: "25G83")

        let pendingContract = try PommeRecoveryProfileContract(
            descriptor: PommeRecoveryProfileSelector.sequoia1561Build24G90
        )
        #expect(pendingContract.qualification == .experimental)
        #expect(pendingContract.reviewDigest.isEmpty)
        _ = try plan(profile: pendingContract, version: "15.6.1", build: "24G90")
    }

    @Test("experimental contracts reject immutable mismatches and forged review claims")
    func experimentalProfileValidation() throws {
        let descriptor = try PommeRecoveryProfileSelector.descriptor(
            version: "26.6.2",
            build: "25G83"
        )
        let contract = try PommeRecoveryProfileContract(descriptor: descriptor)

        #expect(throws: PommeProvisioningError.self) {
            _ = try plan(profile: contract, version: "26.6.2", build: "25G84")
        }

        let forgedAccepted = PommeRecoveryProfileContract(
            identifier: descriptor.id,
            version: descriptor.version,
            build: descriptor.build,
            qualification: .accepted,
            reviewDigest: digest
        )
        #expect(throws: PommeProvisioningError.self) {
            _ = try plan(profile: forgedAccepted, version: "26.6.2", build: "25G83")
        }

        let forgedReviewedExperimental = PommeRecoveryProfileContract(
            identifier: descriptor.id,
            version: descriptor.version,
            build: descriptor.build,
            qualification: .experimental,
            reviewDigest: digest
        )
        #expect(throws: PommeProvisioningError.self) {
            _ = try plan(profile: forgedReviewedExperimental, version: "26.6.2", build: "25G83")
        }

        let forgedAcceptedDescriptor = PommeCreateRecoveryProfileDescriptor(
            id: descriptor.id,
            version: descriptor.version,
            build: descriptor.build,
            locale: descriptor.locale,
            displayWidth: descriptor.displayWidth,
            displayHeight: descriptor.displayHeight,
            qualification: .accepted
        )
        #expect(throws: PommeProvisioningError.self) {
            _ = try PommeRecoveryProfileContract(descriptor: forgedAcceptedDescriptor)
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

    @Test("completed provisioning journals report that agent repair has nothing to do")
    func completedJournalHasNothingToRepair() throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 8, count: 32))
        let journal = try signer.make(
            generation: 1,
            plan: plan(),
            events: try completedEvents()
        )

        #expect(throws: PommeProvisioningError.nothingToRepair(vmName: "pomme-test")) {
            try PommeProvisioningCoordinator.repairPhase(in: journal)
        }
        #expect(PommeProvisioningError.nothingToRepair(vmName: "pomme-test").localizedDescription.contains("SIP or AMFI"))
    }

    @Test("matching connected normal agent repair reports healthy success", arguments: [false, true])
    func matchingAgentRepairIsHealthy(controlInteger: Bool) throws {
        var agent = healthyAgentPayload()
        if controlInteger {
            agent["protocolVersion"] = JSONValue.integer(Int64(PommeAgentProtocol.version)).publicValue
        }
        let result = try #require(PommeCore.alreadyHealthyAgentRepairResult(
            name: "pomme-test",
            status: ["guestAgent": agent],
            hostExecutableDigest: digest
        ))

        #expect(result.ok)
        #expect(result.hostExitCode == 0)
        #expect(result.text == "Pomme agent is already healthy for pomme-test.")
        #expect(result.payload["operation"] as? String == "agent-repair")
        #expect(result.payload["alreadyHealthy"] as? Bool == true)
        #expect(result.payload["hostExitCode"] as? Int64 == 0)
        #expect(result.payload["journalReconciled"] == nil)
    }

    @Test("agent repair does not report healthy for unverified or incompatible agents", arguments: [
        "digestMismatch", "disconnected", "connecting", "recoveryRole", "unknownRole",
        "wrongProtocol", "wrongControlProtocol", "booleanProtocol", "fractionalProtocol",
        "missingProtocol", "missingCapabilities", "missingDigest",
        "missingAgent", "malformedHostDigest",
    ])
    func incompatibleAgentRepairIsNotHealthy(condition: String) {
        var agent = healthyAgentPayload()
        var hostDigest = digest
        switch condition {
        case "digestMismatch": agent["executableDigest"] = String(repeating: "b", count: 64)
        case "disconnected": agent["connection"] = "disconnected"
        case "connecting": agent["connection"] = "connecting"
        case "recoveryRole": agent["role"] = "recovery"
        case "unknownRole": agent["role"] = "unknown"
        case "wrongProtocol": agent["protocolVersion"] = PommeAgentProtocol.version + 1
        case "wrongControlProtocol": agent["protocolVersion"] = Int64(PommeAgentProtocol.version + 1)
        case "booleanProtocol": agent["protocolVersion"] = true
        case "fractionalProtocol": agent["protocolVersion"] = Double(PommeAgentProtocol.version) + 0.5
        case "missingProtocol": agent.removeValue(forKey: "protocolVersion")
        case "missingCapabilities": agent["capabilities"] = ["process.start", "file.open"]
        case "missingDigest": agent.removeValue(forKey: "executableDigest")
        case "malformedHostDigest":
            hostDigest = "not-a-sha256"
            agent["executableDigest"] = hostDigest
        default: break
        }
        let status: [String: Any] = condition == "missingAgent" ? [:] : ["guestAgent": agent]

        #expect(PommeCore.alreadyHealthyAgentRepairResult(
            name: "pomme-test", status: status, hostExecutableDigest: hostDigest
        ) == nil)
    }

    private func healthyAgentPayload() -> [String: Any] {
        [
            "connection": "connected",
            "role": "normal",
            "protocolVersion": PommeAgentProtocol.version,
            "executableDigest": digest,
            "capabilities": ["process.start", "file.open", "mdm.enrollment", "maintenance"],
        ]
    }

    @Test("agent repair gives resume guidance for unsupported provisioning phases")
    func unsupportedRepairPhaseProvidesResumeGuidance() throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 9, count: 32))
        let journal = try signer.make(
            generation: 1,
            plan: plan(),
            events: try eventsThrough(.installRecoveryAgent)
        )

        #expect(throws: PommeProvisioningError.repairUnavailable(
            phase: .verifyNormalAgent,
            vmName: "pomme-test"
        )) {
            try PommeProvisioningCoordinator.repairPhase(in: journal)
        }
        #expect(PommeProvisioningError.repairUnavailable(
            phase: .verifyNormalAgent,
            vmName: "pomme-test"
        ).localizedDescription.contains("--resume"))
    }

    @Test("an unfinished intent is reported as interrupted before phase support is checked")
    func interruptedRepairIntentIsActionable() throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 10, count: 32))
        let journal = try signer.make(
            generation: 1,
            plan: plan(),
            events: try eventsLeavingIntentFor(.install)
        )

        #expect(throws: PommeProvisioningError.repairInterrupted(
            phase: .install,
            vmName: "pomme-test"
        )) {
            try PommeProvisioningCoordinator.repairPhase(in: journal)
        }
        #expect(PommeProvisioningError.repairInterrupted(
            phase: .install,
            vmName: "pomme-test"
        ).localizedDescription.contains("retained"))
    }

    @Test("resume retries an interrupted Recovery agent installation intent")
    func resumeRetriesInterruptedRecoveryAgentInstallation() async throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 13, count: 32))
        let repository = MemoryRepository()
        let calls = CallLog()
        let vmPlan = try plan()
        let retained = try signer.make(
            generation: 1,
            plan: vmPlan,
            events: try eventsThrough(
                .install,
                leavingIntentFor: .installRecoveryAgent
            )
        )
        try repository.create(retained)

        let orchestrator = PommeProvisioningOrchestrator(
            signer: signer,
            repository: repository,
            effects: effects(calls: calls)
        )
        try await orchestrator.resume(expectedPlan: vmPlan)

        let completed = try repository.load()
        try signer.verify(completed)
        #expect(await calls.phases == [
            .installRecoveryAgent,
            .verifyNormalAgent, .restoreFinalState,
        ])
        #expect(completed.events.filter {
            $0.kind == .intent && $0.phase == .installRecoveryAgent
        }.map(\.attempt) == [1])
        #expect(completed.events.filter {
            $0.kind == .receipt && $0.phase == .installRecoveryAgent
        }.map(\.attempt) == [1])
        #expect(completed.events.filter { $0.kind == .receipt }.map(\.phase) == PommeProvisioningPhase.allCases)
    }

    @Test("resume retries an interrupted final-state restoration intent")
    func resumeRetriesInterruptedFinalStateRestoration() async throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 15, count: 32))
        let repository = MemoryRepository()
        let calls = CallLog()
        let vmPlan = try plan(finalState: .normalRunning)
        let retained = try signer.make(
            generation: 1,
            plan: vmPlan,
            events: try eventsThrough(
                .verifyNormalAgent,
                leavingIntentFor: .restoreFinalState
            )
        )
        try repository.create(retained)

        let orchestrator = PommeProvisioningOrchestrator(
            signer: signer,
            repository: repository,
            effects: effects(calls: calls)
        )
        try await orchestrator.resume(expectedPlan: vmPlan)

        let completed = try repository.load()
        try signer.verify(completed)
        #expect(await calls.phases == [.restoreFinalState])
        #expect(completed.events.filter {
            $0.kind == .intent && $0.phase == .restoreFinalState
        }.map(\.attempt) == [1])
        #expect(completed.events.filter {
            $0.kind == .receipt && $0.phase == .restoreFinalState
        }.map(\.attempt) == [1])
        #expect(completed.events.filter { $0.kind == .receipt }.map(\.phase) == PommeProvisioningPhase.allCases)
    }

    @Test("resume rejects every other interrupted phase without mutation", arguments: PommeProvisioningPhase.allCases.filter {
        $0 != .installRecoveryAgent && $0 != .restoreFinalState
    })
    func resumeRejectsUnsupportedInterruptedPhase(phase: PommeProvisioningPhase) async throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 14, count: 32))
        let repository = MemoryRepository()
        let calls = CallLog()
        let vmPlan = try plan()
        let retained = try signer.make(
            generation: 1,
            plan: vmPlan,
            events: try eventsLeavingIntentFor(phase)
        )
        try repository.create(retained)

        let orchestrator = PommeProvisioningOrchestrator(
            signer: signer,
            repository: repository,
            effects: effects(calls: calls)
        )
        await #expect(throws: PommeProvisioningError.unexpectedEvent) {
            try await orchestrator.resume(expectedPlan: vmPlan)
        }

        #expect(await calls.phases.isEmpty)
        #expect(try repository.load() == retained)
    }

    @Test("resume validates malformed pending history before effects")
    func resumeRejectsMalformedPendingHistory() async throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 16, count: 32))
        let repository = MemoryRepository()
        let calls = CallLog()
        let vmPlan = try plan()
        let malformed = try signer.make(
            generation: 1,
            plan: vmPlan,
            events: [try event(kind: .intent, phase: .installRecoveryAgent)]
        )
        try repository.create(malformed)

        let orchestrator = PommeProvisioningOrchestrator(
            signer: signer,
            repository: repository,
            effects: effects(calls: calls)
        )
        await #expect(throws: PommeProvisioningError.unexpectedEvent) {
            try await orchestrator.resume(expectedPlan: vmPlan)
        }

        #expect(await calls.phases.isEmpty)
        #expect(try repository.load() == malformed)
    }

    @Test("failed and not-yet-started Recovery agent phases remain repairable")
    func recoveryAgentRepairPhase() throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 11, count: 32))
        let notStarted = try signer.make(
            generation: 1,
            plan: plan(),
            events: try eventsThrough(.install)
        )
        let first = try PommeProvisioningCoordinator.repairPhase(in: notStarted)
        #expect(first.phase == .installRecoveryAgent)
        #expect(first.attempt == 1)

        let failed = try signer.make(
            generation: 1,
            plan: plan(),
            events: try eventsThrough(.install)
                + [
                    try event(kind: .intent, phase: .installRecoveryAgent),
                    try event(kind: .failure, phase: .installRecoveryAgent),
                ]
        )
        let retry = try PommeProvisioningCoordinator.repairPhase(in: failed)
        #expect(retry.phase == .installRecoveryAgent)
        #expect(retry.attempt == 2)
    }

    @Test("repair phase preserves invalid journal events")
    func invalidRepairJournalRemainsInvalid() throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 12, count: 32))
        let journal = try signer.make(
            generation: 1,
            plan: plan(),
            events: [try event(kind: .receipt, phase: .install)]
        )

        #expect(throws: PommeProvisioningError.unexpectedEvent) {
            try PommeProvisioningCoordinator.repairPhase(in: journal)
        }
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
        let vmPlan = try plan()
        let logs = PommeVMLogCapture()
        await #expect(throws: PommeProvisioningError.self) {
            try await PommeCore.withLogSink(logs.append) {
                try await orchestrator.start(vmPlan)
            }
        }
        let journal = try repository.load()
        #expect(journal.events.map(\.kind) == [.intent, .receipt, .intent, .failure])
        #expect(await calls.phases == [.install, .installRecoveryAgent])
        #expect(logs.values == [
            "pomme-test provisioning phase installRecoveryAgent failed [code=internal.unknown]."
        ])
    }

    @Test("resume retries only the failed bootstrap before verification and final-state restoration", arguments: [
        PommeProvisioningFinalState.stopped, .normalRunning, .recoveryRunning,
    ])
    func resumeIdempotenceAndOwnership(finalState: PommeProvisioningFinalState) async throws {
        // Arrange: retain an interrupted creation at the Recovery install phase.
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 2, count: 32))
        let repository = MemoryRepository()
        let calls = CallLog()
        let vmPlan = try plan(finalState: finalState)
        let failing = PommeProvisioningOrchestrator(
            signer: signer, repository: repository,
            effects: effects(calls: calls, fail: .installRecoveryAgent)
        )
        await #expect(throws: PommeProvisioningError.phaseFailed(.installRecoveryAgent, vmName: vmPlan.vm.name)) {
            try await failing.start(vmPlan)
        }
        let retained = try repository.load()

        // Act: resume the exact journal without reinstalling macOS or repeating
        // the display-only first boot, regardless of the eventual --boot state.
        let good = effects(calls: calls)
        let orchestrator = PommeProvisioningOrchestrator(signer: signer, repository: repository, effects: good)
        try await orchestrator.resume(expectedPlan: vmPlan)

        // Assert: installation, normal-agent verification, and final-state
        // restoration remain separate ordered phases with the plan unchanged.
        let completed = try repository.load()
        try signer.verify(completed)
        #expect(completed.plan == vmPlan)
        #expect(Array(completed.events.prefix(retained.events.count)) == retained.events)
        #expect(completed.events.filter { $0.kind == .receipt }.map(\.phase) == PommeProvisioningPhase.allCases)
        #expect(completed.events.filter { $0.kind == .intent && $0.phase == .installRecoveryAgent }.map(\.attempt) == [1, 2])
        #expect(await calls.phases == [
            .install, .installRecoveryAgent,
            .installRecoveryAgent, .verifyNormalAgent, .restoreFinalState,
        ])
        let count = await calls.phases.count
        try await orchestrator.resume(expectedPlan: vmPlan)
        #expect(await calls.phases.count == count)

        let rejected = PommeProvisioningOrchestrator(
            signer: signer,
            repository: repository,
            effects: .init(
                verifyOwnership: { expected in try PommeVMOwnership(name: expected.name, uuid: UUID(), bundlePath: expected.bundlePath) },
                install: { _ in self.digest },
                installRecoveryAgent: { _ in self.digest }, verifyNormalAgent: { _ in self.digest },
                restoreFinalState: { _ in self.digest }, recoveryRepair: { _, _ in self.digest }
            )
        )
        await #expect(throws: PommeProvisioningError.self) { try await rejected.resume(expectedPlan: vmPlan) }
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

    private func plan(
        profile: PommeRecoveryProfileContract = .tahoe,
        version: String = "26.6.0",
        build: String = "25G72",
        display: PommeDisplayContract = .required,
        finalState: PommeProvisioningFinalState = .normalRunning
    ) throws -> PommeProvisioningPlan {
        try .init(
            vm: .init(name: "pomme-test", uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!, bundlePath: "/tmp/pomme-test.macvm"),
            restore: .init(version: version, build: build, restoreImageDigest: digest),
            display: display,
            profile: profile,
            normalAgent: try .init(identifier: "com.github.weswhet.pomme.agent", executableDigest: digest, role: .normal),
            recoveryAgent: try .init(identifier: "com.github.weswhet.pomme.recovery", executableDigest: digest, role: .recovery),
            finalState: finalState
        )
    }

    private func effects(calls: CallLog, fail: PommeProvisioningPhase? = nil) -> PommeProvisioningEffects {
        .init(
            verifyOwnership: { $0 },
            install: { _ in try await calls.record(.install, digest: self.digest, fail: fail) },
            installRecoveryAgent: { _ in try await calls.record(.installRecoveryAgent, digest: self.digest, fail: fail) },
            verifyNormalAgent: { _ in try await calls.record(.verifyNormalAgent, digest: self.digest, fail: fail) },
            restoreFinalState: { _ in try await calls.record(.restoreFinalState, digest: self.digest, fail: fail) },
            recoveryRepair: { _, state in await calls.recordRepair(state, digest: self.digest) }
        )
    }

    private func event(
        kind: PommeProvisioningEvent.Kind,
        phase: PommeProvisioningPhase,
        attempt: UInt64 = 1
    ) throws -> PommeProvisioningEvent {
        try .init(kind: kind, phase: phase, attempt: attempt, digest: kind == .intent ? nil : digest)
    }

    private func eventsThrough(
        _ lastReceipt: PommeProvisioningPhase,
        failedPhase: PommeProvisioningPhase? = nil
    ) throws -> [PommeProvisioningEvent] {
        var events: [PommeProvisioningEvent] = []
        for phase in PommeProvisioningPhase.allCases {
            guard PommeProvisioningPhase.allCases.firstIndex(of: phase)! <=
                    PommeProvisioningPhase.allCases.firstIndex(of: lastReceipt)! else { break }
            events.append(try event(kind: .intent, phase: phase))
            if phase == failedPhase {
                events.append(try event(kind: .failure, phase: phase))
            } else {
                events.append(try event(kind: .receipt, phase: phase))
            }
        }
        return events
    }

    private func eventsThrough(
        _ lastReceipt: PommeProvisioningPhase,
        leavingIntentFor pendingPhase: PommeProvisioningPhase
    ) throws -> [PommeProvisioningEvent] {
        var events = try eventsThrough(lastReceipt)
        events.append(try event(kind: .intent, phase: pendingPhase))
        return events
    }

    private func eventsLeavingIntentFor(_ phase: PommeProvisioningPhase) throws -> [PommeProvisioningEvent] {
        guard let index = PommeProvisioningPhase.allCases.firstIndex(of: phase) else {
            throw PommeProvisioningError.unexpectedEvent
        }
        var events: [PommeProvisioningEvent] = []
        if index > 0 {
            events = try eventsThrough(PommeProvisioningPhase.allCases[index - 1])
        }
        events.append(try event(kind: .intent, phase: phase))
        return events
    }

    private func completedEvents() throws -> [PommeProvisioningEvent] {
        try eventsThrough(.restoreFinalState)
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
