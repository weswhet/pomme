import Foundation
import Testing

@Suite("Pomme MDM workflow execution")
struct PommeMDMWorkflowExecutionTests {
    @Test("Only absent, completed, or no-effect rejected children permit restoration reconciliation")
    func restorationChildBarrier() {
        #expect(PommeMDMWorkflowSecurityBaseline.childAllowsRestorationReconciliation(nil))
        for phase in PommeSecurityWorkflowPhase.allCases {
            #expect(PommeMDMWorkflowSecurityBaseline.childAllowsRestorationReconciliation(phase)
                == (phase == .restorationComplete || phase == .preflightRejected))
        }
    }

    @Test("Verified restored state clears stale pending restoration without repeating security changes")
    func completedRestorationReconciliation() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .running(.normal),
            sipWasDisabled: false, amfiWasDisabled: false, phase: .enrollmentIntent,
            sipChangeRequested: true, amfiChangeRequested: true, enrollmentDispatched: true)
        try progress.record(phase: .securityRestorationIntent, pendingChild: .some(.amfiEnable), enrollmentVerified: true)
        let events = EventRecorder()
        let verified = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(fixture: fixture, progress: progress, events: events,
            restoredStates: RunStateRecorder(), observations: [verified], awaited: [verified],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 1),
            restorationAlreadyVerified: true)
        #expect(try await execution.run() == verified)
        #expect(securityOperations(await events.values()).isEmpty)
        #expect(progress.journal.pendingChild == nil)
        #expect(progress.journal.phase == .restorationComplete)
    }

    @Test("Only an enabled AMFI completion record can defer its proof until SIP preparation")
    func enabledReceiptAfterSIPRestoration() throws {
        let completed = PommeSecurityWorkflowState(disabled: false, baselinePresent: true,
            reconciliationRequired: true, baselinePhase: "enabledVerified")
        try PommeMDMWorkflowSecurityBaseline.validateOriginalAMFI(sipDisabled: false,
            activeBootArguments: Data(), state: completed)
        #expect(throws: PommeMDMWorkflowFailure.securityBaselineUnsupported) {
            try PommeMDMWorkflowSecurityBaseline.validateOriginalAMFI(sipDisabled: true,
                activeBootArguments: Data(), state: completed)
        }
        #expect(throws: PommeMDMWorkflowFailure.securityBaselineUnsupported) {
            try PommeMDMWorkflowSecurityBaseline.validateOriginalAMFI(sipDisabled: false,
                activeBootArguments: Data(), state: .init(disabled: false, baselinePresent: true,
                    reconciliationRequired: true, baselinePhase: "policyApplied"))
        }
        #expect(throws: PommeMDMWorkflowFailure.securityBaselineUnsupported) {
            try PommeMDMWorkflowSecurityBaseline.validateOriginalAMFI(sipDisabled: false,
                activeBootArguments: Data(PommeBootArguments.amfiOverride.utf8), state: completed)
        }
    }

    @Test("A baseline-only Recovery cleanup barrier prevents compensation boots")
    func baselineCleanupBarrierPreventsBoot() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .stopped,
            sipWasDisabled: nil, amfiWasDisabled: nil)
        let events = EventRecorder()
        let restored = RunStateRecorder()
        let execution = makeExecution(fixture: fixture, progress: progress, events: events,
            restoredStates: restored, observations: [], awaited: [],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 1))
        await #expect(throws: PommeSecurityWorkflowError.restorationIncomplete) {
            _ = try await execution.run(preflightError: PommeSecurityWorkflowError.restorationIncomplete)
        }
        #expect(await events.values().isEmpty)
        #expect(await restored.values().isEmpty)
        #expect(progress.journal.phase == .captured)
    }

    @Test("A wrapped Recovery cleanup barrier prevents another run-state transition")
    func recoveryCleanupBarrierPreventsBoot() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .stopped,
            sipWasDisabled: false, amfiWasDisabled: false, phase: .enrollmentIntent,
            sipChangeRequested: true, amfiChangeRequested: true, enrollmentDispatched: true)
        let events = EventRecorder()
        let restored = RunStateRecorder()
        let verified = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(fixture: fixture, progress: progress, events: events,
            restoredStates: restored, observations: [verified], awaited: [],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 1),
            failingSecurityOperation: .amfiEnable,
            securityFailure: PommeSecurityWorkflowError.restorationIncomplete)
        await #expect(throws: PommeSecurityWorkflowError.restorationIncomplete) { _ = try await execution.run() }
        #expect(await restored.values().isEmpty)
        #expect(!securityOperations(await events.values()).contains(.sipEnable))
        #expect(progress.journal.pendingChild == .amfiEnable)
    }

    @Test("A missing source profile preserves retained security work without guest effects")
    func missingSourcePreservesState() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .stopped,
            sipWasDisabled: false, amfiWasDisabled: false, phase: .enrollmentIntent,
            sipChangeRequested: true, amfiChangeRequested: true)
        let events = EventRecorder()
        let restored = RunStateRecorder()
        let execution = makeExecution(fixture: fixture, progress: progress, events: events,
            restoredStates: restored, observations: [], awaited: [],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 1))
        await #expect(throws: PommeMDMEnrollmentError.invalidProfile) {
            _ = try await execution.run(preflightError: PommeMDMEnrollmentError.invalidProfile)
        }
        #expect(await events.values().isEmpty)
        #expect(await restored.values().isEmpty)
        #expect(progress.journal.phase == .enrollmentIntent)
        #expect(progress.journal.failure == .beforeDispatch)
    }

    @Test("A completed unknown dispatch resumes approval only after exact installed evidence")
    func completedUnknownDispatchResumesUpgrade() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .running(.normal),
            sipWasDisabled: false, amfiWasDisabled: false, phase: .enrollmentIntent,
            sipChangeRequested: true, amfiChangeRequested: true, enrollmentDispatched: true)
        for phase in [PommeMDMEnrollmentPhase.securityRestorationIntent, .securityRestored,
                      .runStateRestorationIntent, .restorationComplete] {
            try progress.record(phase: phase)
        }
        let events = EventRecorder()
        let restored = RunStateRecorder()
        let existing = fixture.observed(enrolled: true, userApproved: false, supervised: false)
        let final = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(fixture: fixture, progress: progress, events: events,
            restoredStates: restored, observations: [existing, existing], awaited: [final, final],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 1))
        #expect(try await execution.run() == final)
        #expect(securityOperations(await events.values()) == [.sipDisable, .amfiDisable, .amfiEnable, .sipEnable])
        #expect(progress.journal.phase == .restorationComplete)
    }

    @Test("A fresh enrollment executes safely in both modes", arguments: MDMEnrollmentMode.allCases)
    func freshEnrollment(mode: MDMEnrollmentMode) async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: mode, originalRunState: .stopped,
                                            sipWasDisabled: nil, amfiWasDisabled: nil)
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let final = fixture.observed(enrolled: true, userApproved: mode == .supervised, supervised: mode == .supervised)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false),
                           fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false)],
            awaited: [final, final],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 1)
        )

        let result = try await execution.run()

        #expect(result == final)
        #expect(securityOperations(await events.values()) == [.sipDisable, .amfiDisable, .amfiEnable, .sipEnable])
        #expect(await restoredStates.values() == [.stopped])
    }

    @Test("An existing exact unapproved enrollment upgrades to supervised without replaying source identity")
    func existingEnrollmentUpgrades() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .running(.normal),
                                            sipWasDisabled: nil, amfiWasDisabled: nil)
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let existing = fixture.observed(enrolled: true, userApproved: false, supervised: false)
        let final = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [existing, existing], awaited: [final, final],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 2)
        )

        let result = try await execution.run()

        #expect(result == final)
        #expect(await events.values().contains("enroll"))
        #expect(securityOperations(await events.values()) == [.sipDisable, .amfiDisable, .amfiEnable, .sipEnable])
        #expect(await restoredStates.values() == [.running(.normal)])
    }

    @Test("A satisfied enrollment is a no-op and never invokes security dependencies")
    func satisfiedEnrollmentAvoidsSecurity() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .paused(previousBootMode: .recovery),
                                            sipWasDisabled: nil, amfiWasDisabled: nil)
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let satisfied = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [satisfied], awaited: [satisfied],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 3)
        )

        let result = try await execution.run()

        #expect(result == satisfied)
        let recorded = await events.values()
        #expect(securityOperations(recorded).isEmpty)
        #expect(!recorded.contains("captureSecurity"))
        #expect(!recorded.contains("enroll"))
        #expect(await restoredStates.values() == [.paused(previousBootMode: .recovery)])
    }

    @Test("A requested downgrade is rejected before any security effect")
    func downgradeNeverRunsSecurity() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .unapproved, originalRunState: .stopped,
                                            sipWasDisabled: nil, amfiWasDisabled: nil)
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let approved = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [approved], awaited: [],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 4)
        )

        await expectWorkflowFailure(execution, expected: .downgradeUnsupported)

        let recorded = await events.values()
        #expect(securityOperations(recorded).isEmpty)
        #expect(!recorded.contains("captureSecurity"))
        #expect(!recorded.contains("enroll"))
        #expect(await restoredStates.values().isEmpty)
    }

    @Test("A conflicting installed profile is rejected before any security effect")
    func conflictingProfileNeverRunsSecurity() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .running(.recovery),
                                            sipWasDisabled: nil, amfiWasDisabled: nil)
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let conflicting = MDMInstalledProfileIdentity(
            identifier: "org.example.other", uuid: UUID(), serverURL: fixture.profile.serverURL
        )
        let observed = PommeMDMObservedEnrollment(
            installed: conflicting,
            status: .init(enrolled: true, userApproved: false, serverURL: fixture.profile.serverURL, enrolledViaDEP: nil),
            supervised: false
        )
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [observed], awaited: [],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 5)
        )

        await expectWorkflowFailure(execution, expected: .conflictingEnrollment)

        let recorded = await events.values()
        #expect(securityOperations(recorded).isEmpty)
        #expect(!recorded.contains("captureSecurity"))
        #expect(!recorded.contains("enroll"))
        #expect(await restoredStates.values().isEmpty)
    }

    @Test("A failed helper exits immediately without checking evidence or restoring state")
    func failedHelperPreservesState() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(
            mode: .supervised, originalRunState: .stopped,
            sipWasDisabled: false, amfiWasDisabled: false,
            phase: .enrollmentIntent, sipChangeRequested: true,
            amfiChangeRequested: true, enrollmentDispatched: true
        )
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let existing = fixture.observed(enrolled: true, userApproved: false, supervised: false)
        let verified = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [existing, existing], awaited: [verified, verified, verified],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 6),
            enrollError: WorkflowTestError.injected, dispatchOnEnroll: false
        )

        await #expect(throws: WorkflowTestError.injected) { _ = try await execution.run() }
        let recorded = await events.values()
        #expect(recorded.last == "enroll")
        #expect(!recorded.contains("awaitEnrollment"))
        #expect(!recorded.contains("cleanup"))
        #expect(securityOperations(recorded).isEmpty)
        #expect(await restoredStates.values().isEmpty)
        #expect(progress.journal.failure == .outcomeUnknown)
        #expect(progress.journal.enrollmentDispatched)
        #expect(!progress.journal.enrollmentVerified)
        #expect(try fixture.store.loadIfPresent(lease: fixture.lease) == progress.journal)
    }

    @Test("A proven failure before identity import permits one explicit retry")
    func cleanFailurePermitsExplicitRetry() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .stopped,
            sipWasDisabled: false, amfiWasDisabled: false, phase: .enrollmentIntent,
            sipChangeRequested: true, amfiChangeRequested: true)
        let absent = fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false)
        let events = EventRecorder()
        let restored = RunStateRecorder()
        let failure = PommeMDMHelperFailure(error: .enrollmentFailed,
            failureStage: .profileRead, beforeIdentityImport: true)
        let failed = makeExecution(fixture: fixture, progress: progress, events: events,
            restoredStates: restored, observations: [absent, absent], awaited: [],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 1),
            enrollError: failure)
        await #expect(throws: PommeMDMHelperFailure.self) { _ = try await failed.run() }
        #expect((await events.values()).last == "enroll")
        #expect(progress.journal.canRetryEnrollment)
        #expect(try fixture.store.loadIfPresent(lease: fixture.lease)?.canRetryEnrollment == true)

        // Preparation can fail before the next launch without consuming proof.
        let preparationEvents = EventRecorder()
        let preparation = makeExecution(fixture: fixture, progress: progress, events: preparationEvents,
            restoredStates: restored, observations: [absent, absent], awaited: [],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 1),
            enrollError: WorkflowTestError.injected, dispatchOnEnroll: false)
        await #expect(throws: WorkflowTestError.injected) { _ = try await preparation.run() }
        #expect(progress.journal.canRetryEnrollment)
        #expect((await preparationEvents.values()).last == "enroll")

        // A lost reply on that explicit retry must consume the old proof.
        let retryEvents = EventRecorder()
        let retry = makeExecution(fixture: fixture, progress: progress, events: retryEvents,
            restoredStates: restored, observations: [absent, absent], awaited: [],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 1),
            enrollError: WorkflowTestError.injected)
        await #expect(throws: WorkflowTestError.injected) { _ = try await retry.run() }
        #expect((await retryEvents.values()).last == "enroll")
        #expect(!progress.journal.canRetryEnrollment)
        #expect(progress.journal.failure == .outcomeUnknown)
        #expect(await restored.values().isEmpty)
        #expect(securityOperations(await retryEvents.values()).isEmpty)
    }

    @Test("An absent state after dispatch is unknown and never reinstalls")
    func unknownAbsentStateDoesNotReinstall() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(
            mode: .supervised, originalRunState: .stopped,
            sipWasDisabled: false, amfiWasDisabled: false,
            phase: .enrollmentIntent, sipChangeRequested: true,
            amfiChangeRequested: true, enrollmentDispatched: true
        )
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false)],
            awaited: [],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 7)
        )

        await expectWorkflowFailure(execution, expected: .outcomeUnknown)

        let recorded = await events.values()
        #expect(!recorded.contains("enroll"))
        #expect(securityOperations(recorded).isEmpty)
        #expect(await restoredStates.values().isEmpty)
    }

    @Test("Cancellation preserves guest state without compensation")
    func cancellationPreservesState() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .running(.normal),
                                            sipWasDisabled: nil, amfiWasDisabled: nil)
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let final = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false),
                           fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false)],
            awaited: [final, final],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 8),
            dispatchOnEnroll: false, enrollSuspends: true
        )
        let task = Task { try await execution.run() }

        for _ in 0..<100 {
            if await events.contains("enroll") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await events.contains("enroll"))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation unexpectedly completed the enrollment workflow.")
        } catch {
            // The original cancellation is preserved.
        }

        let recorded = await events.values()
        #expect(recorded.last == "enroll")
        #expect(!recorded.contains("cleanup"))
        #expect(securityOperations(recorded) == [.sipDisable, .amfiDisable])
        #expect(await restoredStates.values().isEmpty)
    }

    @Test("Cleanup failure stops before security or run state restoration")
    func cleanupFailureStopsImmediately() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .paused(previousBootMode: .normal),
                                            sipWasDisabled: nil, amfiWasDisabled: nil)
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let final = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false),
                           fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false)],
            awaited: [final, final],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 9),
            cleanupFailures: 1
        )

        do {
            _ = try await execution.run()
            Issue.record("Expected cleanup failure.")
        } catch let error as PommeMDMEnrollmentError {
            #expect(error == .cleanupFailed)
        } catch {
            Issue.record("Unexpected workflow error: \(error)")
        }

        #expect(await events.count("cleanup") == 1)
        #expect((await events.values()).last == "cleanup")
        #expect(await restoredStates.values().isEmpty)
    }

    @Test("AMFI restoration failure is a barrier to SIP enable")
    func amfiRestoreFailurePreventsSIPEnable() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(mode: .supervised, originalRunState: .stopped,
                                            sipWasDisabled: nil, amfiWasDisabled: nil)
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let final = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false),
                           fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false)],
            awaited: [final, final],
            baseline: makeBaseline(sipDisabled: false, amfiDisabled: false, activeByte: 10),
            failingSecurityOperation: .amfiEnable
        )

        await #expect(throws: WorkflowTestError.injected) { _ = try await execution.run() }

        let operations = securityOperations(await events.values())
        #expect(operations.contains(.amfiEnable))
        #expect(!operations.contains(.sipEnable))
        #expect(await restoredStates.values().isEmpty)
    }

    @Test("A retained pending child is resumed before enrollment")
    func resumesPendingChild() async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(
            mode: .supervised, originalRunState: .stopped,
            sipWasDisabled: true, amfiWasDisabled: false,
            phase: .securityPrepared, pendingChild: .amfiDisable,
            amfiChangeRequested: true
        )
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let final = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false),
                           fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false)],
            awaited: [final, final],
            baseline: makeBaseline(sipDisabled: true, amfiDisabled: false, activeByte: 11)
        )

        _ = try await execution.run()

        let operations = securityOperations(await events.values())
        #expect(operations == [.amfiDisable, .amfiEnable])
        #expect(await restoredStates.values() == [.stopped])
    }

    @Test("Fresh enrollment restores every original run/security combination", arguments: OriginalWorkflowScenario.allCases)
    fileprivate func originalRunAndSecurityCombination(scenario: OriginalWorkflowScenario) async throws {
        let fixture = try WorkflowFixture.make()
        defer { fixture.remove() }
        let progress = try fixture.progress(
            mode: .supervised, originalRunState: scenario.runState,
            sipWasDisabled: scenario.sipWasDisabled, amfiWasDisabled: scenario.amfiWasDisabled
        )
        let events = EventRecorder()
        let restoredStates = RunStateRecorder()
        let final = fixture.observed(enrolled: true, userApproved: true, supervised: true)
        let execution = makeExecution(
            fixture: fixture, progress: progress, events: events, restoredStates: restoredStates,
            observations: [fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false),
                           fixture.observed(enrolled: false, userApproved: false, supervised: false, installed: false)],
            awaited: [final, final],
            baseline: makeBaseline(sipDisabled: scenario.sipWasDisabled,
                                   amfiDisabled: scenario.amfiWasDisabled, activeByte: 12)
        )

        _ = try await execution.run()

        var expected: [PommeSecurityWorkflowOperation] = []
        if !scenario.sipWasDisabled { expected.append(.sipDisable) }
        if !scenario.amfiWasDisabled { expected.append(.amfiDisable) }
        if !scenario.amfiWasDisabled { expected.append(.amfiEnable) }
        if !scenario.sipWasDisabled { expected.append(.sipEnable) }
        #expect(securityOperations(await events.values()) == expected)
        #expect(await restoredStates.values() == [scenario.runState])
    }

    private func makeExecution(
        fixture: WorkflowFixture,
        progress: PommeMDMWorkflowProgress,
        events: EventRecorder,
        restoredStates: RunStateRecorder,
        observations: [PommeMDMObservedEnrollment],
        awaited: [PommeMDMObservedEnrollment],
        baseline: PommeMDMWorkflowSecurityBaseline,
        failingSecurityOperation: PommeSecurityWorkflowOperation? = nil,
        securityFailure: (any Error)? = nil,
        enrollError: (any Error)? = nil,
        dispatchOnEnroll: Bool = true,
        enrollSuspends: Bool = false,
        cleanupFailures: Int = 0,
        restorationAlreadyVerified: Bool = false
    ) -> PommeMDMWorkflowExecution {
        let observationQueue = ObservationQueue(observations)
        let awaitQueue = ObservationQueue(awaited)
        let cleanupFailurePlan = FailureCounter(remaining: cleanupFailures)
        return PommeMDMWorkflowExecution(
            progress: progress,
            dependencies: .init(
                ensureNormal: {
                    await events.append("ensureNormal")
                },
                observe: {
                    await events.append("observe")
                    return try await observationQueue.next()
                },
                captureSecurity: {
                    await events.append("captureSecurity")
                    return baseline
                },
                runSecurity: { operation in
                    await events.append("security:\(operation.rawValue)")
                    if operation == failingSecurityOperation { throw securityFailure ?? WorkflowTestError.injected }
                },
                enroll: {
                    await events.append("enroll")
                    if dispatchOnEnroll { try progress.record(enrollmentDispatched: true, failure: .outcomeUnknown) }
                    if enrollSuspends {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                    if let enrollError { throw enrollError }
                },
                cleanup: {
                    await events.append("cleanup")
                    if await cleanupFailurePlan.takeFailure() { throw WorkflowTestError.injected }
                },
                requireHelperStopped: {
                    await events.append("requireHelperStopped")
                },
                verifySecurity: { _ in
                    await events.append("verifySecurity")
                },
                restoreRunState: { state in
                    await events.append("restoreRunState")
                    await restoredStates.append(state)
                },
                awaitEnrollment: {
                    await events.append("awaitEnrollment")
                    return try await awaitQueue.next()
                },
                restorationAlreadyVerified: { _ in restorationAlreadyVerified }
            )
        )
    }

    private func expectWorkflowFailure(
        _ execution: PommeMDMWorkflowExecution,
        expected: PommeMDMWorkflowFailure
    ) async {
        do {
            _ = try await execution.run()
            Issue.record("Expected workflow failure \(expected).")
        } catch let error as PommeMDMWorkflowFailure {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected workflow error: \(error)")
        }
    }
}

private enum WorkflowTestError: Error, Equatable, Sendable {
    case injected
    case observationQueueExhausted
}

private func makeBaseline(sipDisabled: Bool, amfiDisabled: Bool, activeByte: UInt8) -> PommeMDMWorkflowSecurityBaseline {
    let arguments = Data([activeByte])
    return .init(sipDisabled: sipDisabled, amfiDisabled: amfiDisabled,
        activeBootArguments: arguments,
        configuredBootArguments: try! PommeProvisioningCoding.encode(JSONValue.string(arguments.base64EncodedString())))
}

private actor EventRecorder {
    private var events: [String] = []

    func append(_ event: String) { events.append(event) }
    func values() -> [String] { events }
    func contains(_ event: String) -> Bool { events.contains(event) }
    func count(_ event: String) -> Int { events.filter { $0 == event }.count }
}

private actor ObservationQueue {
    private var values: [PommeMDMObservedEnrollment]

    init(_ values: [PommeMDMObservedEnrollment]) { self.values = values }

    func next() throws -> PommeMDMObservedEnrollment {
        guard !values.isEmpty else { throw WorkflowTestError.observationQueueExhausted }
        return values.removeFirst()
    }
}

private actor FailureCounter {
    private var remaining: Int

    init(remaining: Int) { self.remaining = remaining }

    func takeFailure() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

private actor RunStateRecorder {
    private var states: [VMRunStateSnapshot] = []

    func append(_ state: VMRunStateSnapshot) { states.append(state) }
    func values() -> [VMRunStateSnapshot] { states }
}

private struct WorkflowFixture {
    let directory: URL
    let store: PommeMDMEnrollmentJournalStore
    let lease: VMBundleMutationLease
    let identity: PommeSecurityWorkflowIdentity
    let profile: MDMEnrollmentProfileIdentity
    let date = Date(timeIntervalSince1970: 1_700_000_000.123)
    let agentDigest = String(repeating: "a", count: 64)

    static func make() throws -> Self {
        let vmName = "mdm-execution-\(UUID().uuidString.lowercased())"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-mdm-execution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        do {
            let lease = try VMBundleMutationLease.acquire(name: vmName)
            let identity = try PommeSecurityWorkflowIdentity(
                vmName: vmName,
                vmUUID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                machineIdentifierSHA256: String(repeating: "b", count: 64),
                diskImageFileResourceID: "1:2",
                startupVolumeGroupUUID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                immutableProvisioningPlanDigest: String(repeating: "c", count: 64)
            )
            let profile = MDMEnrollmentProfileIdentity(
                identifier: "com.example.mdm",
                uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                serverURL: "https://mdm.example.test/server",
                digest: String(repeating: "d", count: 64)
            )
            return .init(directory: directory, store: .init(bundleURL: directory), lease: lease,
                         identity: identity, profile: profile)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func progress(
        mode: MDMEnrollmentMode,
        originalRunState: VMRunStateSnapshot,
        sipWasDisabled: Bool?,
        amfiWasDisabled: Bool?,
        phase: PommeMDMEnrollmentPhase = .captured,
        pendingChild: PommeSecurityWorkflowOperation? = nil,
        sipChangeRequested: Bool? = nil,
        amfiChangeRequested: Bool? = nil,
        enrollmentDispatched: Bool = false
    ) throws -> PommeMDMWorkflowProgress {
        var journal = try store.begin(
            identity: identity, profile: profile, agentSHA256: agentDigest,
            enrollmentMode: mode, originalRunState: originalRunState,
            sipWasDisabled: sipWasDisabled, amfiWasDisabled: amfiWasDisabled,
            ownedArtifacts: [], lease: lease, now: date
        )
        let phases: [PommeMDMEnrollmentPhase] = [
            .existingEnrollmentChecked, .securityPreparationIntent, .securityPrepared, .enrollmentIntent,
        ]
        if let target = phases.firstIndex(of: phase) {
            for (offset, next) in phases[...target].enumerated() {
                journal = try store.advance(journal, to: next, lease: lease,
                                            now: date.addingTimeInterval(TimeInterval(offset + 1)))
            }
        } else if phase != .captured {
            throw WorkflowTestError.injected
        }
        if pendingChild != nil || sipChangeRequested != nil || amfiChangeRequested != nil || enrollmentDispatched {
            let pending: PommeSecurityWorkflowOperation?? = pendingChild.map { .some($0) }
            journal = try store.update(
                journal,
                pendingChild: pending,
                sipChangeRequested: sipChangeRequested,
                amfiChangeRequested: amfiChangeRequested,
                enrollmentDispatched: enrollmentDispatched ? true : nil,
                lease: lease,
                now: date.addingTimeInterval(20)
            )
        }
        return PommeMDMWorkflowProgress(journal, store: store, lease: lease)
    }

    func observed(
        enrolled: Bool,
        userApproved: Bool,
        supervised: Bool,
        installed: Bool = true
    ) -> PommeMDMObservedEnrollment {
        .init(
            installed: installed ? .init(identifier: profile.identifier, uuid: profile.uuid, serverURL: profile.serverURL) : nil,
            status: .init(enrolled: enrolled, userApproved: userApproved,
                          serverURL: installed ? profile.serverURL : nil, enrolledViaDEP: nil),
            supervised: supervised
        )
    }

    func remove() {
        lease.release()
        try? FileManager.default.removeItem(at: directory)
    }
}

fileprivate struct OriginalWorkflowScenario: Sendable {
    let runState: VMRunStateSnapshot
    let sipWasDisabled: Bool
    let amfiWasDisabled: Bool

    static let allCases: [Self] = [VMRunStateSnapshot.stopped, .running(.normal), .running(.recovery),
        .paused(previousBootMode: .normal), .paused(previousBootMode: .recovery)].flatMap { runState in
            [false, true].flatMap { sip in
                [false, true].map { amfi in
                    Self(runState: runState, sipWasDisabled: sip, amfiWasDisabled: amfi)
                }
            }
        }
}

private func securityOperations(_ events: [String]) -> [PommeSecurityWorkflowOperation] {
    events.compactMap { event in
        guard event.hasPrefix("security:") else { return nil }
        return PommeSecurityWorkflowOperation(rawValue: String(event.dropFirst("security:".count)))
    }
}
