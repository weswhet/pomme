import Foundation
import Testing

@Suite("MDM readiness planning")
struct PommeMDMReadinessTests {
    private typealias R = PommeMDMReadiness

    private func ready(_ change: (inout R.Facts) -> Void = { _ in }) -> R.Facts {
        var facts = R.Facts(provisioning: .complete(schema: 2), runState: .stopped)
        change(&facts)
        return facts
    }

    private func plan(_ facts: R.Facts, _ change: (inout R.Request) -> Void = { _ in }) -> R.Plan {
        var request = R.Request()
        change(&request)
        return R.plan(facts, request: request)
    }

    @Test("A ready VM plans only enrollment")
    func readyVMEnrolls() {
        let result = plan(ready())
        #expect(result.steps == [.enroll])
        #expect(result.blockers.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.nextPreparation == nil)
    }

    @Test("A missing VM is created only when a source is supplied")
    func missingVM() {
        let missing = ready { $0.vmExists = false; $0.provisioning = nil; $0.runState = .unknown }
        #expect(plan(missing).blockers == [.vmMissing])
        let created = plan(missing) { $0.creationSourceSupplied = true; $0.creationOptionsSupplied = true }
        #expect(created.steps == [.create, .enroll])
        #expect(created.blockers.isEmpty)
        #expect(created.nextPreparation == .create)
        #expect(!created.warnings.contains(.creationOptionsIgnored))
        var unusable = missing
        unusable.creationProblem = "No template named base."
        #expect(plan(unusable) { $0.creationSourceSupplied = true }.blockers
            == [.creationUnavailable("No template named base.")])
    }

    @Test("Creation options on an existing VM are ignored with a warning")
    func existingVMIgnoresCreation() {
        let result = plan(ready()) { $0.creationSourceSupplied = true; $0.creationOptionsSupplied = true }
        #expect(result.steps == [.enroll])
        #expect(result.warnings == [.creationOptionsIgnored])
    }

    @Test("Incomplete creation resumes first, and an unresumable one blocks")
    func provisioning() {
        let resumable = plan(ready { $0.provisioning = .resumable(schema: 1, phase: "installRecoveryAgent") })
        #expect(resumable.steps == [.resumeProvisioning(schema: 1, phase: "installRecoveryAgent"), .enroll])
        #expect(resumable.nextPreparation == .resumeProvisioning(schema: 1, phase: "installRecoveryAgent"))
        for reason in [PommeProvisioningReadiness.Blocked.unmanaged, .invalidJournal, .ambiguousFirstBoot,
                       .interruptedPhase("install")] {
            let blocked = plan(ready { $0.provisioning = .blocked(schema: 2, reason: reason) })
            #expect(blocked.blockers == [.provisioning(reason)])
            #expect(blocked.nextPreparation == nil)
        }
    }

    @Test("Run-state hazards block or warn")
    func runStateHazards() {
        #expect(plan(ready { $0.pendingSnapshotRestore = true }).blockers == [.pendingSnapshotRestore])
        #expect(plan(ready { $0.runState = .unknown }).blockers == [.runStateUnknown])
        #expect(plan(ready { $0.runState = .paused(.normal) }).warnings == [.pausedMemoryDiscarded])
        #expect(plan(ready { $0.runState = .running(.recovery) }).blockers.isEmpty)
    }

    @Test("A retained standalone security workflow is finished before enrollment")
    func finishesRetainedSecurityWorkflow() {
        let retained = R.RetainedSecurityWorkflow(operation: .sipDisable, phase: .autologinIntent,
                                                  requestedFinalState: .normal)
        let result = plan(ready { $0.retainedSecurity = retained })
        #expect(result.steps == [.finishSecurityWorkflow(.sipDisable, .normal), .enroll])
        for phase in [PommeSecurityWorkflowPhase.restorationComplete, .preflightRejected] {
            var finished = retained
            finished.phase = phase
            #expect(plan(ready { $0.retainedSecurity = finished }).steps == [.enroll])
        }
    }

    @Test("An unfinished enrollment resumes its own child and rejects another")
    func unfinishedEnrollmentOwnsSecurity() {
        let child = R.RetainedSecurityWorkflow(operation: .amfiDisable, phase: .securityMutationIntent,
                                               requestedFinalState: .normal)
        let enrollment = R.RetainedEnrollment(phase: .securityPreparationIntent, pendingChild: .amfiDisable)
        let own = plan(ready { $0.retainedEnrollment = enrollment; $0.retainedSecurity = child })
        #expect(own.steps == [.enroll])
        #expect(own.blockers.isEmpty)
        var other = child
        other.operation = .sipEnable
        let competing = plan(ready { $0.retainedEnrollment = enrollment; $0.retainedSecurity = other })
        #expect(competing.blockers == [.competingSecurityOperation(.sipEnable)])
    }

    @Test("An unfinished enrollment for a different request blocks",
          arguments: [(false, true, true), (true, false, true), (true, true, false)])
    func retainedConflict(profile: Bool, mode: Bool, finalSecurity: Bool) {
        let enrollment = R.RetainedEnrollment(phase: .securityPrepared, matchesProfile: profile,
                                              matchesMode: mode, matchesFinalSecurity: finalSecurity)
        #expect(plan(ready { $0.retainedEnrollment = enrollment }).blockers == [.retainedEnrollmentConflict])
        var finished = enrollment
        finished.phase = .restorationComplete
        #expect(plan(ready { $0.retainedEnrollment = finished }).blockers.isEmpty)
    }

    @Test("An unknown enrollment outcome is resumed by the engine with a warning")
    func outcomeUnknownWarns() {
        let enrollment = R.RetainedEnrollment(phase: .restorationComplete, failure: .outcomeUnknown,
                                              enrollmentDispatched: true)
        let result = plan(ready { $0.retainedEnrollment = enrollment })
        #expect(result.steps == [.enroll])
        #expect(result.warnings == [.enrollmentOutcomeUnknown])
    }

    @Test("A pinned agent that fails the gate blocks unless creation will reinstall it")
    func agentGate() {
        for readiness in [MDMAgentReadiness.unattested, .digestMismatch, .missingCapabilities(["mdm.enrollment"])] {
            #expect(plan(ready { $0.agent = readiness }).blockers == [.agent(readiness)])
            let resuming = plan(ready {
                $0.agent = readiness
                $0.provisioning = .resumable(schema: 1, phase: "installRecoveryAgent")
            })
            #expect(resuming.blockers.isEmpty)
        }
        #expect(plan(ready { $0.agent = .ready }).blockers.isEmpty)
    }

    @Test("Observed guest conflicts block")
    func observedConflicts() {
        #expect(plan(ready { $0.securityBaselineSupported = false }).blockers == [.securityBaselineUnsupported])
        #expect(plan(ready { $0.enrollment = .conflicting }).blockers == [.conflictingEnrollment])
        #expect(plan(ready { $0.enrollment = .downgrade }).blockers == [.downgradeUnsupported])
    }

    @Test("An untrusted server blocks a new install unless skipped, satisfied, or already dispatched")
    func serverTrustGate() {
        let untrusted = ready { $0.serverTrust = .untrusted }
        #expect(plan(untrusted).blockers == [.untrustedServer])
        #expect(plan(untrusted) { $0.skipServerPreflight = true }.blockers.isEmpty)
        #expect(plan(ready { $0.serverTrust = .untrusted; $0.enrollment = .satisfied }).blockers.isEmpty)
        let restoring = R.RetainedEnrollment(phase: .securityRestorationIntent, enrollmentDispatched: true,
                                             enrollmentVerified: true)
        #expect(plan(ready { $0.serverTrust = .untrusted; $0.retainedEnrollment = restoring }).blockers.isEmpty)
        let retry = R.RetainedEnrollment(phase: .enrollmentIntent, failure: .beforeIdentityImport,
                                         enrollmentDispatched: true, canRetryEnrollment: true)
        #expect(plan(ready { $0.serverTrust = .untrusted; $0.retainedEnrollment = retry }).blockers == [.untrustedServer])
        #expect(plan(ready { $0.serverTrust = .unreachable }).warnings == [.serverUnreachableFromHost])
        for decision in [MDMServerTrustDecision.publicTrust, .profileRootTrust, .notApplicable] {
            let result = plan(ready { $0.serverTrust = decision })
            #expect(result.blockers.isEmpty && result.warnings.isEmpty)
        }
    }

    @Test("Disabled final security and possible owner creation are surfaced")
    func warnings() {
        #expect(plan(ready()) { $0.finalSecurity = .disabled }.warnings == [.finalSecurityDisabled])
        let v1 = ready { $0.provisioning = .complete(schema: 1) }
        #expect(plan(v1).warnings == [.ownerConsentMayBeRequired])
        #expect(plan(v1) { $0.force = true }.warnings.isEmpty)
        #expect(plan(v1) { $0.interactive = true }.warnings.isEmpty)
        #expect(plan(ready { $0.provisioning = .complete(schema: 1); $0.sipDisabled = true; $0.amfiDisabled = true })
            .warnings.isEmpty)
    }

    @Test("Mutation in progress blocks every plan")
    func mutationInProgress() {
        #expect(plan(ready { $0.mutationInProgress = true }).blockers == [.mutationInProgress])
    }

    @Test("The public projection names steps, blockers, and unobserved facts")
    func publicValue() {
        let facts = ready { $0.serverTrust = .untrusted }
        let value = R.publicValue(facts, plan: plan(facts))
        #expect((value["steps"] as? [[String: String]])?.map { $0["name"] } == ["enroll"])
        #expect((value["blockers"] as? [[String: String]])?.first?["code"] == "untrustedServer")
        #expect(value["sipDisabled"] as? String == "notObserved")
        #expect(value["runState"] as? String == "stopped")
        #expect(value["serverTrust"] as? String == "untrusted")
        #expect(JSONSerialization.isValidJSONObject(value))
    }
}

@Suite("Read-only provisioning readiness")
struct PommeProvisioningReadinessTests {
    private let digest = String(repeating: "a", count: 64)

    @Test("V1 journals classify like the orchestrator resumes them")
    func v1() throws {
        let signer = try PommeProvisioningJournalSigner(key: Data(repeating: 21, count: 32))
        func classify(_ events: [PommeProvisioningEvent]) throws -> PommeProvisioningReadiness {
            PommeProvisioningReadinessClassifier.classify(v1: try signer.make(generation: 1, plan: v1Plan(), events: events))
        }
        #expect(try classify(v1Events(through: .restoreFinalState)) == .complete(schema: 1))
        #expect(try classify([]) == .resumable(schema: 1, phase: "install"))
        var failed = try v1Events(through: .install)
        failed += [try .init(kind: .intent, phase: .installRecoveryAgent, attempt: 1),
                   try .init(kind: .failure, phase: .installRecoveryAgent, attempt: 1, digest: digest)]
        #expect(try classify(failed) == .resumable(schema: 1, phase: "installRecoveryAgent"))
        let interrupted: [(PommeProvisioningPhase?, PommeProvisioningPhase, PommeProvisioningReadiness)] = [
            (nil, .install, .blocked(schema: 1, reason: .interruptedPhase("install"))),
            (.install, .installRecoveryAgent, .resumable(schema: 1, phase: "installRecoveryAgent")),
            (.installRecoveryAgent, .verifyNormalAgent,
             .blocked(schema: 1, reason: .interruptedPhase("verifyNormalAgent"))),
            (.verifyNormalAgent, .restoreFinalState, .resumable(schema: 1, phase: "restoreFinalState")),
        ]
        for (receipt, pending, expected) in interrupted {
            let events = try (receipt.map { try v1Events(through: $0) } ?? [])
                + [try .init(kind: .intent, phase: pending, attempt: 1)]
            #expect(try classify(events) == expected)
        }
    }

    @Test("V2 journals never plan a replay of a dispatched first boot")
    func v2() throws {
        let signer = try PommeProvisioningV2Signer(key: Data(repeating: 22, count: 32))
        let plan = try v2Plan()
        let reference = try v2Reference(plan)
        func classify(_ events: [PommeProvisioningV2Event], dispatched: Bool = false,
                      volume: UUID? = nil) throws -> PommeProvisioningReadiness {
            let journal = try signer.make(generation: 1, plan: plan, ownerReference: reference,
                                          startupVolumeGroupUUID: volume, events: events)
            return PommeProvisioningReadinessClassifier.classify(v2: journal) { dispatched }
        }
        let pendingGuest = v2History(pending: .provisionGuest)
        #expect(try classify(pendingGuest) == .resumable(schema: 2, phase: "provisionGuest"))
        #expect(try classify(pendingGuest, dispatched: true) == .blocked(schema: 2, reason: .ambiguousFirstBoot))
        let failedGuest = pendingGuest + [.init(kind: .failure, phase: .provisionGuest, attempt: 1, digest: digest)]
        #expect(try classify(failedGuest, dispatched: true) == .blocked(schema: 2, reason: .ambiguousFirstBoot))
        #expect(try classify(v2History(pending: .bootstrapNormalAgent))
            == .resumable(schema: 2, phase: "bootstrapNormalAgent"))
        #expect(try classify(v2History(pending: .install)) == .blocked(schema: 2, reason: .interruptedPhase("install")))
        #expect(try classify(v2History(pending: nil), volume: UUID()) == .complete(schema: 2))
        let unreadable = try signer.make(generation: 1, plan: plan, ownerReference: reference, events: pendingGuest)
        #expect(PommeProvisioningReadinessClassifier.classify(v2: unreadable) {
            throw PommeProvisioningV2Error.ambiguousProvisionGuest
        } == .blocked(schema: 2, reason: .ambiguousFirstBoot))
    }

    @Test("V2 inspection reports a pending high-water advance without writing it")
    func v2InspectDoesNotAdvance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-readiness-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("provisioning-v2.json")
        let signer = try PommeProvisioningV2Signer(key: Data(repeating: 23, count: 32))
        let highWater = HighWater()
        let repository = PommeFileProvisioningV2JournalRepository(journalURL: url, signer: signer,
            loadHighWater: { highWater.value }, advanceHighWater: { highWater.advance($0, $1) })
        let initial = try signer.make(generation: 1, plan: v2Plan(), events: [])
        try repository.create(initial)
        let next = try signer.make(generation: 2, plan: initial.plan,
                                   events: [.init(kind: .intent, phase: .install, attempt: 1)])
        try PommeProvisioningCoding.encode(next).write(to: url)
        #expect(try repository.inspect() == next)
        #expect(highWater.value == 1)
        #expect(highWater.writes == 1)
        _ = try repository.load()
        #expect(highWater.value == 2)
    }

    private func v1Plan() throws -> PommeProvisioningPlan {
        try .init(
            vm: .init(name: "readiness-v1", uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
                      bundlePath: "/tmp/readiness-v1.macvm"),
            restore: .init(version: "26.6.0", build: "25G72", restoreImageDigest: digest),
            display: .required, profile: .tahoe,
            normalAgent: try .init(identifier: "com.github.weswhet.pomme.agent", executableDigest: digest, role: .normal),
            recoveryAgent: try .init(identifier: "com.github.weswhet.pomme.recovery", executableDigest: digest, role: .recovery),
            finalState: .normalRunning)
    }

    private func v1Events(through last: PommeProvisioningPhase) throws -> [PommeProvisioningEvent] {
        var events: [PommeProvisioningEvent] = []
        for phase in PommeProvisioningPhase.allCases {
            events.append(try .init(kind: .intent, phase: phase, attempt: 1))
            events.append(try .init(kind: .receipt, phase: phase, attempt: 1, digest: digest))
            if phase == last { break }
        }
        return events
    }

    private func v2Plan() throws -> PommeProvisioningPlan {
        try .init(vm: .init(name: "readiness-v2", uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
                            bundlePath: "/tmp/readiness-v2.macvm"),
            restore: .init(version: "27.0.0", build: "26A1", restoreImageDigest: digest), display: .required,
            profile: .init(descriptor: PommeRecoveryProfileSelector.descriptor(version: "27.0", build: "26A1")),
            normalAgent: .init(identifier: "normal", executableDigest: digest, role: .normal),
            recoveryAgent: .init(identifier: "recovery", executableDigest: digest, role: .recovery),
            finalState: .normalRunning)
    }

    private func v2Reference(_ plan: PommeProvisioningPlan) throws -> PommeOwnerCredentialReference {
        try .init(identity: .init(vmName: plan.vm.name, vmUUID: plan.vm.uuid,
            machineIdentifierSHA256: digest, diskImageFileResourceID: "disk-1", startupVolumeGroupUUID: UUID(),
            immutableProvisioningPlanDigest: plan.digest), account: "pomme")
    }

    /// Every phase before `pending` completes; `pending` is left as an intent.
    /// A nil `pending` completes every phase.
    private func v2History(pending: PommeProvisioningV2Phase?) -> [PommeProvisioningV2Event] {
        var events: [PommeProvisioningV2Event] = []
        for phase in PommeProvisioningV2Phase.allCases {
            events.append(.init(kind: .intent, phase: phase, attempt: 1))
            if phase == pending { break }
            events.append(.init(kind: .receipt, phase: phase, attempt: 1, digest: digest))
        }
        return events
    }
}

private final class HighWater: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0
    private var count = 0
    var value: UInt64 { lock.withLock { current } }
    var writes: Int { lock.withLock { count } }
    func advance(_ previous: UInt64, _ next: UInt64) {
        lock.withLock {
            precondition(current == previous)
            current = next
            count += 1
        }
    }
}
