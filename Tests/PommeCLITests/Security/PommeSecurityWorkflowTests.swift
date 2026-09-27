import Foundation
import Testing
import Synchronization

@Suite("Pomme security workflow engine", .serialized)
struct PommeSecurityWorkflowTests {
    @Test("An explicit fresh-owner retry repeats the ordered sequence after a retained failure")
    func explicitFreshOwnerRetry() async throws {
        let events = Mutex<[String]>([])
        let failPreferences = Mutex(true)
        let record: @Sendable (String) -> Void = { stage in events.withLock { $0.append(stage) } }
        let sequence = PommeSecurityFreshOwnerLoginSequence(
            configureLoginAndMarkers: { record("configure") },
            restartAndAuthenticate: { record("restart") },
            verifyOwnerConsole: { record("console") },
            completeOwnerPreferences: {
                record("preferences")
                if failPreferences.withLock({ $0 }) {
                    throw PommeSecurityOwnerPreparationError.commandFailed(.ownerCompletion, exitCode: 1)
                }
            },
            verifyDesktop: { record("desktop") })
        await #expect(throws: PommeSecurityOwnerPreparationError.commandFailed(.ownerCompletion, exitCode: 1)) {
            try await sequence.run()
        }
        #expect(events.withLock { $0 } == ["configure", "restart", "console", "preferences"])
        failPreferences.withLock { $0 = false }
        try await sequence.run() // A separately requested attempt, never a catch-path retry.
        #expect(events.withLock { $0 } == ["configure", "restart", "console", "preferences", "configure", "restart", "console", "preferences", "desktop"])
    }

    @Test("Failed autologin intent resumes the same transaction and releases security ownership on success")
    func retainedAutologinFailureResumes() async throws {
        let harness = try WorkflowHarness()
        defer { harness.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
        defer { lease.release() }
        let credential = try PommeOwnerCredentialReference(
            identity: harness.identity, account: "pomme", generatedUID: harness.generatedUID)
        let owner = try PommeSecurityWorkflowOwnerRecord(
            accountUsername: "pomme", ownerPreparation: .new, generatedUID: harness.generatedUID)
        let progress = try harness.progress(
            operation: .sipDisable, originalRunState: .stopped,
            requestedFinalState: .stopped, owner: owner, credential: credential, lease: lease)
        for phase: PommeSecurityWorkflowPhase in [
            .credentialStored, .accountCreationIntent, .accountCreationVerified, .autologinIntent
        ] { try progress.advance(phase) }
        let retained = progress.journal
        let state = PommeSecurityWorkflowState(
            disabled: false, baselinePresent: false, reconciliationRequired: false, baselinePhase: nil)
        let failed = WorkflowRecorder()
        do {
            _ = try await PommeSecurityWorkflow.run(
                progress: progress,
                dependencies: harness.dependencies(
                    operation: .sipDisable, state: state, recorder: failed, failure: .prepareOwner))
            Issue.record("Owner failure unexpectedly completed")
        } catch {
            #expect(error as? WorkflowDependencyFailure == .prepareOwner)
        }
        #expect(failed.events == [.observe, .prepareOwner])
        #expect(try harness.store.load(lease: lease) == retained)
        #expect(throws: PommeSecurityWorkflowJournalError.conflictingOperation) {
            _ = try harness.progress(operation: .amfiEnable, originalRunState: .stopped,
                                     requestedFinalState: .stopped, lease: lease)
        }
        #expect(throws: PommeSecurityWorkflowJournalError.immutableRequestMismatch) {
            _ = try harness.progress(operation: .sipDisable, originalRunState: .stopped,
                                     requestedFinalState: .previous, lease: lease)
        }
        // Reconstruct the public command's begin/run sequence from the durable store.
        let resumed = try harness.progress(
            operation: .sipDisable, originalRunState: .running(.normal),
            requestedFinalState: .stopped, lease: lease)
        #expect(resumed.journal == retained)
        let completed = WorkflowRecorder()
        let dependencies = PommeSecurityWorkflowDependencies(
            observe: { completed.record(.observe); return state },
            prepareOwner: { cursor in
                completed.record(.prepareOwner)
                #expect(cursor.journal.phase == .autologinIntent)
                #expect(cursor.journal.owner == owner)
                #expect(cursor.journal.credential == credential)
                // Guest effects are injected; native reconciliation is covered separately.
                try cursor.advance(.autologinVerified)
                return try PommeGuestSecurityCredentials(username: "pomme", password: "offline-test-secret")
            },
            mutate: { _ in
                completed.record(.mutate)
                return .object(["verified": .bool(true), "sipDisabled": .bool(true)])
            },
            verifyNormalBoot: { completed.record(.verifyNormalBoot) },
            restore: { completed.record(.restore($0)) }, log: { _ in })
        _ = try await PommeSecurityWorkflow.run(progress: resumed, dependencies: dependencies)
        #expect(completed.events == [.observe, .prepareOwner, .mutate, .verifyNormalBoot, .restore(.stopped)])
        let receipt = try harness.store.load(lease: lease)
        #expect(receipt.phase == .restorationComplete)
        #expect(receipt.originalRunState == .stopped)
        #expect(receipt.credential == credential)
        #expect(receipt.owner == owner)
        #expect(receipt.normalBootVerified)
        // A later operation can begin only once the retained operation has completed.
        let next = try harness.progress(operation: .amfiEnable, originalRunState: .stopped,
                                        requestedFinalState: .stopped, lease: lease)
        #expect(next.journal.operation == .amfiEnable)
    }

    @Test("Fresh owner retries require current desktop proof before security mutation")
    func freshOwnerDesktopProofRetryPhases() {
        #expect(PommeSecurityWorkflow.freshOwnerDesktopProofRequired(for: .autologinVerified))
        #expect(PommeSecurityWorkflow.freshOwnerDesktopProofRequired(for: .securityMutationIntent))
        #expect(!PommeSecurityWorkflow.freshOwnerDesktopProofRequired(for: .credentialPending))
        #expect(!PommeSecurityWorkflow.freshOwnerDesktopProofRequired(for: .autologinIntent))
        #expect(!PommeSecurityWorkflow.freshOwnerDesktopProofRequired(for: .securityMutationVerified))
    }

    @Test("AMFI verification reboots only a running boot this process did not prove")
    func amfiVerificationRebootDecision() {
        let proven = "01234567-89ab-cdef-0123-456789abcdef"
        let other = "fedcba98-7654-3210-fedc-ba9876543210"
        // A VM the verification itself started from stopped is a fresh boot.
        #expect(!PommeSecurityWorkflow.amfiVerificationRequiresReboot(
            startedFreshBoot: true, currentBootIdentity: other, provenBootIdentity: nil))
        #expect(!PommeSecurityWorkflow.amfiVerificationRequiresReboot(
            startedFreshBoot: true, currentBootIdentity: nil, provenBootIdentity: nil))
        // The boot proven after this process's NVRAM reboot is verified as is.
        #expect(!PommeSecurityWorkflow.amfiVerificationRequiresReboot(
            startedFreshBoot: false, currentBootIdentity: proven, provenBootIdentity: proven))
        // A retry in a new process, or a boot that changed since the proof, reboots.
        #expect(PommeSecurityWorkflow.amfiVerificationRequiresReboot(
            startedFreshBoot: false, currentBootIdentity: other, provenBootIdentity: nil))
        #expect(PommeSecurityWorkflow.amfiVerificationRequiresReboot(
            startedFreshBoot: false, currentBootIdentity: other, provenBootIdentity: proven))
        #expect(PommeSecurityWorkflow.amfiVerificationRequiresReboot(
            startedFreshBoot: false, currentBootIdentity: nil, provenBootIdentity: proven))
    }

    @Test("Fresh-owner ordering stops at the first failure without retry", arguments: ["none", "configure", "restart", "console", "preferences", "desktop"])
    func freshOwnerSequence(failure: String) async throws {
        let events = Mutex<[String]>([])
        let messages = Mutex<[String]>([])
        let record: @Sendable (String) throws -> Void = { stage in
            events.withLock { $0.append(stage) }
            if stage == failure {
                throw PommeSecurityOwnerPreparationError.commandFailed(.ownerCompletion, exitCode: 1)
            }
        }
        let sequence = PommeSecurityFreshOwnerLoginSequence(
            configureLoginAndMarkers: { try record("configure") },
            restartAndAuthenticate: { try record("restart") },
            verifyOwnerConsole: { try record("console") },
            completeOwnerPreferences: { try record("preferences") },
            verifyDesktop: { try record("desktop") },
            log: { line in messages.withLock { $0.append(line) } })
        let order = ["configure", "restart", "console", "preferences", "desktop"]
        if failure == "none" {
            try await sequence.run()
            #expect(events.withLock { $0 } == order)
        } else {
            await #expect(throws: PommeSecurityOwnerPreparationError.commandFailed(.ownerCompletion, exitCode: 1)) {
                try await sequence.run()
            }
            let index = try #require(order.firstIndex(of: failure))
            #expect(events.withLock { $0 } == Array(order.prefix(index + 1)))
            #expect(messages.withLock { $0.last?.contains("no automatic retry") } == true)
        }
    }

    @Test("A matching state completes as a no-op before owner preparation")
    func matchingStateIsNoOpBeforeOwnerPreparation() async throws {
        let harness = try WorkflowHarness()
        defer { harness.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
        defer { lease.release() }

        let progress = try harness.progress(
            operation: .sipDisable,
            originalRunState: .running(.normal),
            requestedFinalState: .previous,
            lease: lease
        )
        let recorder = WorkflowRecorder()
        let dependencies = harness.dependencies(
            operation: .sipDisable,
            state: .init(
                disabled: true,
                baselinePresent: false,
                reconciliationRequired: false,
                baselinePhase: nil
            ),
            recorder: recorder
        )

        // When
        let result = try await PommeSecurityWorkflow.run(
            progress: progress,
            dependencies: dependencies
        )

        // Then
        let payload = try #require(result.objectValue)
        #expect(payload["noOp"] == .bool(true))
        #expect(payload["normalBootVerified"] == .bool(false))
        #expect(payload["runtimeConfigurationVerified"] == .bool(false))
        #expect(payload["enforcementVerified"] == .bool(false))
        #expect(payload["finalState"] == .string("normal"))
        #expect(recorder.events == [.observe, .restore(.running(.normal))])

        let journal = try harness.store.load(lease: lease)
        #expect(journal.phase == .restorationComplete)
        #expect(journal.noMutationNeeded)
        #expect(!journal.normalBootVerified)
    }

    @Test("A retained AMFI baseline prevents an apparent match from becoming a no-op")
    func retainedAMFIBaselineRequiresMutation() async throws {
        let harness = try WorkflowHarness()
        defer { harness.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
        defer { lease.release() }

        let owner = try harness.existingOwner()
        let progress = try harness.progress(
            operation: .amfiEnable,
            originalRunState: .running(.normal),
            requestedFinalState: .stopped,
            owner: owner,
            lease: lease
        )
        let recorder = WorkflowRecorder()
        let dependencies = harness.dependencies(
            operation: .amfiEnable,
            state: .init(
                disabled: false,
                baselinePresent: true,
                reconciliationRequired: true,
                baselinePhase: "baselineCaptured"
            ),
            recorder: recorder,
            advancesOwnerPreparation: true
        )

        // When
        let result = try await PommeSecurityWorkflow.run(
            progress: progress,
            dependencies: dependencies
        )

        // Then
        let payload = try #require(result.objectValue)
        #expect(payload["noOp"] == .bool(false))
        #expect(payload["normalBootVerified"] == .bool(true))
        #expect(payload["runtimeConfigurationVerified"] == .bool(true))
        #expect(payload["enforcementVerified"] == .bool(false))
        #expect(payload["finalState"] == .string("stopped"))
        #expect(recorder.count(.prepareOwner) == 1)
        #expect(recorder.count(.mutate) == 1)
        #expect(recorder.count(.verifyNormalBoot) == 1)
        #expect(recorder.restoreStates == [.stopped])
    }

    @Test("AMFI enable with no retained baseline fails before owner preparation")
    func missingBaselineFailsBeforeOwnerPreparation() async throws {
        let harness = try WorkflowHarness()
        defer { harness.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
        defer { lease.release() }

        let progress = try harness.progress(
            operation: .amfiEnable,
            originalRunState: .running(.normal),
            requestedFinalState: .stopped,
            lease: lease
        )
        let recorder = WorkflowRecorder()
        let dependencies = harness.dependencies(
            operation: .amfiEnable,
            state: .init(
                disabled: true,
                baselinePresent: false,
                reconciliationRequired: false,
                baselinePhase: "none"
            ),
            recorder: recorder
        )

        // When / Then
        do {
            _ = try await PommeSecurityWorkflow.run(
                progress: progress,
                dependencies: dependencies
            )
            Issue.record("AMFI enable without a retained baseline unexpectedly succeeded")
        } catch {
            #expect(error as? PommeSecurityWorkflowError == .missingBaseline)
        }
        #expect(recorder.count(.observe) == 1)
        #expect(recorder.count(.prepareOwner) == 0)
        #expect(recorder.count(.mutate) == 0)
        #expect(recorder.count(.verifyNormalBoot) == 0)
        #expect(recorder.restoreStates == [.running(.normal)])
        #expect(try harness.store.load(lease: lease).phase == .credentialPending)
    }

    @Test("A conflicting journal is rejected before workflow effects begin")
    func conflictingJournalPrecedesEffects() throws {
        let harness = try WorkflowHarness()
        defer { harness.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
        defer { lease.release() }

        let first = try harness.store.begin(
            operation: .sipDisable,
            identity: harness.identity,
            originalRunState: .running(.normal),
            requestedFinalState: .previous,
            lease: lease
        )

        // When / Then
        #expect(throws: PommeSecurityWorkflowJournalError.conflictingOperation) {
            try harness.store.begin(
                operation: .sipEnable,
                identity: harness.identity,
                originalRunState: .running(.normal),
                requestedFinalState: .previous,
                lease: lease
            )
        }
        #expect(try harness.store.load(lease: lease) == first)
    }

    @Test("An interrupted mutation intent with matching read-back skips the owner and verifies normal boot")
    func mutationIntentReadBackResumesWithoutOwnerPreparation() async throws {
        let harness = try WorkflowHarness()
        defer { harness.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
        defer { lease.release() }

        let owner = try harness.existingOwner()
        let progress = try harness.progress(
            operation: .sipDisable,
            originalRunState: .stopped,
            requestedFinalState: .normal,
            owner: owner,
            lease: lease
        )
        try progress.advance(.accountCreationVerified)
        try progress.advance(.securityMutationIntent)

        let recorder = WorkflowRecorder()
        let dependencies = harness.dependencies(
            operation: .sipDisable,
            state: .init(
                disabled: true,
                baselinePresent: false,
                reconciliationRequired: false,
                baselinePhase: nil
            ),
            recorder: recorder
        )

        // When
        let result = try await PommeSecurityWorkflow.run(
            progress: progress,
            dependencies: dependencies
        )

        // Then
        let payload = try #require(result.objectValue)
        #expect(payload["noOp"] == .bool(false))
        #expect(payload["normalBootVerified"] == .bool(true))
        #expect(payload["runtimeConfigurationVerified"] == .bool(true))
        #expect(payload["enforcementVerified"] == .bool(true))
        #expect(payload["finalState"] == .string("normal"))
        #expect(recorder.count(.prepareOwner) == 0)
        #expect(recorder.count(.mutate) == 0)
        #expect(recorder.count(.verifyNormalBoot) == 1)
        #expect(recorder.restoreStates == [.running(.normal)])
        #expect(try harness.store.load(lease: lease).phase == .restorationComplete)
    }

    @Test("An interrupted mutation intent with conflicting read-back reapplies the mutation")
    func mutationIntentConflictRetriesMutation() async throws {
        let cases: [(
            disabled: Bool,
            baselinePresent: Bool,
            reconciliationRequired: Bool,
            baselinePhase: String?
        )] = [
            (false, false, false, nil),
            (true, true, true, "policyApplied"),
        ]

        for state in cases {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            let progress = try harness.progress(
                operation: .sipDisable,
                originalRunState: .stopped,
                requestedFinalState: .normal,
                owner: try harness.existingOwner(),
                lease: lease
            )
            try progress.advance(.accountCreationVerified)
            try progress.advance(.securityMutationIntent)

            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: .sipDisable,
                state: .init(
                    disabled: state.disabled,
                    baselinePresent: state.baselinePresent,
                    reconciliationRequired: state.reconciliationRequired,
                    baselinePhase: state.baselinePhase
                ),
                recorder: recorder
            )

            let result = try await PommeSecurityWorkflow.run(
                progress: progress,
                dependencies: dependencies
            )

            let payload = try #require(result.objectValue)
            #expect(payload["noOp"] == .bool(false))
            #expect(payload["normalBootVerified"] == .bool(true))
            #expect(recorder.count(.prepareOwner) == 1)
            #expect(recorder.count(.mutate) == 1)
            #expect(recorder.count(.verifyNormalBoot) == 1)
            #expect(recorder.restoreStates == [.running(.normal)])
            #expect(try harness.store.load(lease: lease).phase == .restorationComplete)
        }
    }

    @Test("Dependency failures retain progress; owner-preparation failure preserves the current VM state")
    func dependencyFailuresRestoreOriginalState() async throws {
        for failure in WorkflowDependencyFailure.allCases {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            let progress = try harness.progress(
                operation: .sipDisable,
                originalRunState: .running(.normal),
                requestedFinalState: .stopped,
                owner: try harness.existingOwner(),
                lease: lease
            )
            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: .sipDisable,
                state: .init(
                    disabled: false,
                    baselinePresent: false,
                    reconciliationRequired: false,
                    baselinePhase: nil
                ),
                recorder: recorder,
                advancesOwnerPreparation: true,
                failure: failure
            )

            // When / Then
            do {
                _ = try await PommeSecurityWorkflow.run(
                    progress: progress,
                    dependencies: dependencies
                )
                Issue.record("Workflow unexpectedly succeeded for failure \(failure)")
            } catch {
                if failure == .restore {
                    #expect(error as? PommeSecurityWorkflowError == .restorationIncomplete)
                } else {
                    #expect(error as? WorkflowDependencyFailure == failure)
                }
            }
            let expectedRestoreAttempts = failure == .prepareOwner ? 0 : failure == .restore ? 2 : 1
            #expect(recorder.restoreStates.count == expectedRestoreAttempts)
            #expect(recorder.restoreStates == (failure == .prepareOwner ? [] : failure == .restore
                ? [.stopped, .running(.normal)] : [.running(.normal)]))
            #expect(try harness.store.load(lease: lease).phase != .restorationComplete)
        }
    }

    @Test("No-op restoration resolves every explicit final state")
    func explicitFinalStatesAreRestored() async throws {
        let cases: [(VMRunStateSnapshot, VMFinalState, VMRunStateSnapshot, String)] = [
            (.running(.normal), .stopped, .stopped, "stopped"),
            (.running(.normal), .normal, .running(.normal), "normal"),
            (.running(.normal), .recovery, .running(.recovery), "recovery"),
            (.running(.normal), .paused, .paused(previousBootMode: .normal), "paused"),
            (.running(.recovery), .previous, .running(.recovery), "recovery")
        ]

        for (original, requested, expected, expectedName) in cases {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            let progress = try harness.progress(
                operation: .sipDisable,
                originalRunState: original,
                requestedFinalState: requested,
                lease: lease
            )
            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: .sipDisable,
                state: .init(
                    disabled: true,
                    baselinePresent: false,
                    reconciliationRequired: false,
                    baselinePhase: nil
                ),
                recorder: recorder
            )

            // When
            let result = try await PommeSecurityWorkflow.run(
                progress: progress,
                dependencies: dependencies
            )

            // Then
            let payload = try #require(result.objectValue)
            #expect(payload["noOp"] == .bool(true))
            #expect(payload["finalState"] == .string(expectedName))
            #expect(payload["finalStateVerified"] == .bool(true))
            #expect(recorder.restoreStates == [expected])
        }
    }

    @Test("A cleanup failure is terminal and never restores the VM")
    func cleanupFailurePreventsRestoration() async throws {
        for cleanupFailure in CleanupFailure.allCases {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            let progress = try harness.progress(
                operation: .sipDisable,
                originalRunState: .running(.normal),
                requestedFinalState: .stopped,
                lease: lease
            )
            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: .sipDisable,
                state: .init(
                    disabled: false,
                    baselinePresent: false,
                    reconciliationRequired: false,
                    baselinePhase: nil
                ),
                recorder: recorder,
                cleanupFailure: cleanupFailure
            )

            // When / Then
            do {
                _ = try await PommeSecurityWorkflow.run(
                    progress: progress,
                    dependencies: dependencies
                )
                Issue.record("Cleanup failure unexpectedly succeeded for \(cleanupFailure)")
            } catch {
                #expect(error as? PommeSecurityWorkflowError == .restorationIncomplete)
            }
            #expect(recorder.count(.observe) == 1)
            #expect(recorder.restoreStates.isEmpty)
        }
    }

    @Test("A restoration-pending retry derives result booleans from durable receipts")
    func restorationPendingRetryPreservesReceiptBooleans() async throws {
        let cases: [(Bool, Bool)] = [
            (true, false), // normalBootVerified, noMutationNeeded
            (false, true)
        ]

        for (normalBootReceipt, noMutationReceipt) in cases {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            let owner = normalBootReceipt ? try harness.existingOwner() : nil
            let progress = try harness.progress(
                operation: .sipDisable,
                originalRunState: .running(.normal),
                requestedFinalState: .stopped,
                owner: owner,
                lease: lease
            )
            if normalBootReceipt {
                try progress.advance(.accountCreationVerified)
                try progress.advance(.securityMutationIntent)
                try progress.advance(.securityMutationVerified)
                try progress.advance(.normalBootVerified)
            } else {
                try progress.advance(.noMutationVerified)
            }
            try progress.advance(.restorationPending)

            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: .sipDisable,
                state: .init(
                    disabled: true,
                    baselinePresent: false,
                    reconciliationRequired: false,
                    baselinePhase: nil
                ),
                recorder: recorder
            )

            // When
            let result = try await PommeSecurityWorkflow.run(
                progress: progress,
                dependencies: dependencies
            )

            // Then
            let payload = try #require(result.objectValue)
            #expect(payload["noOp"] == .bool(noMutationReceipt))
            #expect(payload["normalBootVerified"] == .bool(normalBootReceipt))
            #expect(payload["runtimeConfigurationVerified"] == .bool(normalBootReceipt))
            #expect(payload["enforcementVerified"] == .bool(normalBootReceipt))
            #expect(payload["finalStateVerified"] == .bool(true))
            #expect(recorder.count(.prepareOwner) == 0)
            #expect(recorder.count(.mutate) == 0)
            #expect(recorder.count(.verifyNormalBoot) == 0)
            #expect(recorder.restoreStates == [.stopped])

            let journal = try harness.store.load(lease: lease)
            #expect(journal.phase == .restorationComplete)
            #expect(journal.normalBootVerified == normalBootReceipt)
            #expect(journal.noMutationNeeded == noMutationReceipt)
        }
    }

    @Test("A restoration-pending state conflict restores the durable original state")
    func restorationPendingConflictRestoresOriginal() async throws {
        let harness = try WorkflowHarness()
        defer { harness.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
        defer { lease.release() }

        let progress = try harness.progress(
            operation: .sipDisable,
            originalRunState: .running(.normal),
            requestedFinalState: .stopped,
            owner: try harness.existingOwner(),
            lease: lease
        )
        try progress.advance(.accountCreationVerified)
        try progress.advance(.securityMutationIntent)
        try progress.advance(.securityMutationVerified)
        try progress.advance(.normalBootVerified)
        try progress.advance(.restorationPending)

        let recorder = WorkflowRecorder()
        let dependencies = harness.dependencies(
            operation: .sipDisable,
            state: .init(
                disabled: false,
                baselinePresent: false,
                reconciliationRequired: false,
                baselinePhase: nil
            ),
            recorder: recorder
        )

        do {
            _ = try await PommeSecurityWorkflow.run(
                progress: progress,
                dependencies: dependencies
            )
            Issue.record("A conflicting restoration state unexpectedly succeeded")
        } catch {
            #expect(error as? PommeSecurityWorkflowError == .incompleteTransaction)
        }
        #expect(recorder.count(.prepareOwner) == 0)
        #expect(recorder.count(.mutate) == 0)
        #expect(recorder.count(.verifyNormalBoot) == 0)
        #expect(recorder.restoreStates == [.running(.normal)])

        let journal = try harness.store.load(lease: lease)
        #expect(journal.phase == .restorationPending)
        #expect(journal.normalBootVerified)
        #expect(!journal.noMutationNeeded)
    }

    @Test("A receipt-backed AMFI retry verifies normal boot without owner preparation")
    func amfiReceiptBackedRetrySkipsOwnerAndMutation() async throws {
        for operation in [PommeSecurityWorkflowOperation.amfiDisable,
                          PommeSecurityWorkflowOperation.amfiEnable] {
            for retryPhase in [PommeSecurityWorkflowPhase.securityMutationIntent,
                               PommeSecurityWorkflowPhase.securityMutationVerified] {
                let harness = try WorkflowHarness()
                defer { harness.cleanup() }
                let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
                defer { lease.release() }

                let progress = try harness.progress(
                    operation: operation,
                    originalRunState: .running(.normal),
                    requestedFinalState: .stopped,
                    owner: try harness.existingOwner(),
                    lease: lease
                )
                try progress.advance(.accountCreationVerified)
                try progress.advance(.securityMutationIntent)
                if retryPhase == .securityMutationVerified {
                    try progress.advance(.securityMutationVerified)
                }

                let recorder = WorkflowRecorder()
                let dependencies = harness.dependencies(
                    operation: operation,
                    state: .init(
                        disabled: operation.requestsDisabled,
                        baselinePresent: true,
                        reconciliationRequired: true,
                        baselinePhase: operation.requestsDisabled
                            ? "disabledConfigured" : "enabledConfigured"
                    ),
                    recorder: recorder
                )

                let result = try await PommeSecurityWorkflow.run(
                    progress: progress,
                    dependencies: dependencies
                )
                let payload = try #require(result.objectValue)
                #expect(payload["noOp"] == .bool(false))
                #expect(payload["normalBootVerified"] == .bool(true))
                #expect(payload["runtimeConfigurationVerified"] == .bool(true))
                #expect(recorder.count(.prepareOwner) == 0)
                #expect(recorder.count(.mutate) == 0)
                #expect(recorder.count(.verifyNormalBoot) == 1)
                #expect(recorder.restoreStates == [.stopped])

                let journal = try harness.store.load(lease: lease)
                #expect(journal.phase == .restorationComplete)
                #expect(journal.normalBootVerified)
                #expect(!journal.noMutationNeeded)
            }
        }
    }

    @Test("A retained AMFI disable re-enters the injected normal stage")
    func retainedConfiguredAMFIDisableReentersNormalStage() async throws {
        let scenarios: [(String, Bool)] = [
            ("disabledConfigured", false),
            ("policyApplied", false),
            ("policyApplied", true),
            ("normalNVRAMApplying", false),
            ("normalNVRAMApplying", true),
            ("normalNVRAMApplied", false),
            ("normalNVRAMApplied", true)
        ]
        for (baselinePhase, disabled) in scenarios {
            for retryPhase in [PommeSecurityWorkflowPhase.securityMutationIntent,
                               PommeSecurityWorkflowPhase.securityMutationVerified] {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            let progress = try harness.progress(
                operation: .amfiDisable,
                originalRunState: .running(.normal),
                requestedFinalState: .stopped,
                owner: try harness.existingOwner(),
                lease: lease
            )
            try progress.advance(.accountCreationVerified)
            try progress.advance(.securityMutationIntent)
            if retryPhase == .securityMutationVerified {
                try progress.advance(.securityMutationVerified)
            }

            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: .amfiDisable,
                state: .init(
                    disabled: disabled,
                    baselinePresent: true,
                    reconciliationRequired: true,
                    baselinePhase: baselinePhase
                ),
                recorder: recorder,
                recoverConfiguredAMFI: { _ in
                    .object(["verified": .bool(true), "amfiDisabled": .bool(true)])
                }
            )

            let result = try await PommeSecurityWorkflow.run(
                progress: progress,
                dependencies: dependencies
            )
            let payload = try #require(result.objectValue)
            #expect(payload["noOp"] == .bool(false))
            #expect(payload["normalBootVerified"] == .bool(true))
            #expect(recorder.count(.prepareOwner) == 1)
            #expect(recorder.count(.recoverConfiguredAMFI) == 1)
            #expect(recorder.count(.mutate) == 0)
            #expect(recorder.count(.verifyNormalBoot) == 1)
            #expect(recorder.restoreStates == [.stopped])

            let journal = try harness.store.load(lease: lease)
            #expect(journal.phase == .restorationComplete)
            #expect(journal.normalBootVerified)
            #expect(!journal.noMutationNeeded)
            }
        }
    }

    @Test("A retained normal AMFI checkpoint resumes without rereading state")
    func retainedAMFINormalCheckpointResumesWithoutObserve() async throws {
        for retryPhase in [PommeSecurityWorkflowPhase.securityMutationIntent,
                           PommeSecurityWorkflowPhase.securityMutationVerified] {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            let progress = try harness.progress(
                operation: .amfiDisable,
                originalRunState: .running(.normal),
                requestedFinalState: .stopped,
                owner: try harness.existingOwner(),
                lease: lease
            )
            try progress.advance(.accountCreationVerified)
            try progress.advance(.securityMutationIntent)
            if retryPhase == .securityMutationVerified {
                try progress.advance(.securityMutationVerified)
            }

            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: .amfiDisable,
                state: .init(
                    disabled: false,
                    baselinePresent: true,
                    reconciliationRequired: true,
                    baselinePhase: "disabledConfigured"
                ),
                recorder: recorder,
                recoverConfiguredAMFI: { _ in
                    .object(["verified": .bool(true), "amfiDisabled": .bool(true)])
                }
            )

            let result = try await PommeSecurityWorkflow.resumeRetainedAMFINormalCheckpoint(
                progress: progress,
                dependencies: dependencies
            )
            let payload = try #require(result.objectValue)
            #expect(payload["noOp"] == .bool(false))
            #expect(payload["normalBootVerified"] == .bool(true))
            #expect(payload["runtimeConfigurationVerified"] == .bool(true))
            #expect(recorder.count(.observe) == 0)
            #expect(recorder.count(.prepareOwner) == 1)
            #expect(recorder.count(.recoverConfiguredAMFI) == 1)
            #expect(recorder.count(.mutate) == 0)
            #expect(recorder.count(.verifyNormalBoot) == 1)
            #expect(recorder.restoreStates == [.stopped])

            let journal = try harness.store.load(lease: lease)
            #expect(journal.phase == .restorationComplete)
            #expect(journal.normalBootVerified)
            #expect(!journal.noMutationNeeded)
        }
    }

    @Test("A retained normal AMFI checkpoint rejects ineligible journals")
    func retainedAMFINormalCheckpointRejectsIneligibleJournals() async throws {
        let cases = ["wrong operation", "wrong phase", "new owner", "missing owner"]
        for invalidCase in cases {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            var operation = PommeSecurityWorkflowOperation.amfiDisable
            var owner: PommeSecurityWorkflowOwnerRecord? = nil
            var credential: PommeOwnerCredentialReference? = nil
            var phase = PommeSecurityWorkflowPhase.credentialPending
            switch invalidCase {
            case "wrong operation":
                operation = .amfiEnable
                owner = try harness.existingOwner()
                phase = .securityMutationVerified
            case "wrong phase":
                owner = try harness.existingOwner()
                phase = .normalBootVerified
            case "new owner":
                owner = try PommeSecurityWorkflowOwnerRecord(
                    accountUsername: "pomme",
                    ownerPreparation: .new,
                    generatedUID: harness.generatedUID
                )
                credential = try PommeOwnerCredentialReference(
                    identity: harness.identity,
                    account: "pomme",
                    generatedUID: harness.generatedUID
                )
                phase = .securityMutationVerified
            case "missing owner":
                owner = nil
            default:
                Issue.record("Unexpected ineligible-journal case \(invalidCase)")
            }

            let progress = try harness.progress(
                operation: operation,
                originalRunState: .running(.normal),
                requestedFinalState: .stopped,
                owner: owner,
                credential: credential,
                lease: lease
            )
            if phase == .securityMutationVerified || phase == .normalBootVerified {
                if invalidCase == "new owner" {
                    try progress.advance(.credentialStored)
                    try progress.advance(.accountCreationIntent)
                }
                try progress.advance(.accountCreationVerified)
                if invalidCase == "new owner" {
                    try progress.advance(.autologinIntent)
                    try progress.advance(.autologinVerified)
                }
                try progress.advance(.securityMutationIntent)
                try progress.advance(.securityMutationVerified)
                if phase == .normalBootVerified {
                    try progress.advance(.normalBootVerified)
                }
            }

            #expect(!PommeSecurityWorkflow.canResumeRetainedAMFINormalCheckpoint(
                progress.journal))
            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: operation,
                state: .init(
                    disabled: false,
                    baselinePresent: true,
                    reconciliationRequired: true,
                    baselinePhase: "disabledConfigured"
                ),
                recorder: recorder,
                recoverConfiguredAMFI: { _ in
                    .object(["verified": .bool(true), "amfiDisabled": .bool(true)])
                }
            )

            do {
                _ = try await PommeSecurityWorkflow.resumeRetainedAMFINormalCheckpoint(
                    progress: progress,
                    dependencies: dependencies
                )
                Issue.record("Ineligible retained AMFI journal unexpectedly resumed")
            } catch {
                #expect(error as? PommeSecurityWorkflowError == .incompleteTransaction)
            }
            #expect(recorder.events.isEmpty)
        }
    }

    @Test("Retained normal AMFI failures preserve owner failures and restore later failures")
    func retainedAMFINormalCheckpointFailuresRestoreOriginalState() async throws {
        let cases: [(String, WorkflowDependencyFailure?, ConfiguredAMFIRecoveryFailure?)] = [
            ("owner", .prepareOwner, nil),
            ("verification", .verifyNormalBoot, nil),
            ("restore", .restore, nil),
            ("callback", nil, .callback)
        ]

        for (name, dependencyFailure, recoveryFailure) in cases {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            let progress = try harness.progress(
                operation: .amfiDisable,
                originalRunState: .running(.normal),
                requestedFinalState: .stopped,
                owner: try harness.existingOwner(),
                lease: lease
            )
            try progress.advance(.accountCreationVerified)
            try progress.advance(.securityMutationIntent)
            try progress.advance(.securityMutationVerified)

            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: .amfiDisable,
                state: .init(
                    disabled: false,
                    baselinePresent: true,
                    reconciliationRequired: true,
                    baselinePhase: "disabledConfigured"
                ),
                recorder: recorder,
                failure: dependencyFailure,
                configuredRecoveryFailure: recoveryFailure,
                recoverConfiguredAMFI: { _ in
                    .object(["verified": .bool(true), "amfiDisabled": .bool(true)])
                }
            )
            let ownerFailure = dependencyFailure == .some(.prepareOwner)
            let verificationFailure = dependencyFailure == .some(.verifyNormalBoot)
            let restoreFailure = dependencyFailure == .some(.restore)

            do {
                _ = try await PommeSecurityWorkflow.resumeRetainedAMFINormalCheckpoint(
                    progress: progress,
                    dependencies: dependencies
                )
                Issue.record("Retained normal AMFI failure case unexpectedly succeeded for \(name)")
            } catch {
                if restoreFailure {
                    #expect(error as? PommeSecurityWorkflowError == .restorationIncomplete)
                } else if let dependencyFailure {
                    #expect(error as? WorkflowDependencyFailure == dependencyFailure)
                } else if let recoveryFailure {
                    #expect(error as? ConfiguredAMFIRecoveryFailure == recoveryFailure)
                }
            }
            #expect(recorder.count(.observe) == 0)
            #expect(recorder.count(.prepareOwner) == 1)
            #expect(recorder.count(.recoverConfiguredAMFI) == (ownerFailure ? 0 : 1))
            #expect(recorder.count(.mutate) == 0)
            #expect(recorder.count(.verifyNormalBoot) == (verificationFailure || restoreFailure ? 1 : 0))
            #expect(recorder.restoreStates == (ownerFailure ? [] : restoreFailure
                ? [.stopped, .running(.normal)] : [.running(.normal)]))

            let journal = try harness.store.load(lease: lease)
            #expect(journal.phase == (restoreFailure
                ? .restorationPending : .securityMutationVerified))
            #expect(journal.normalBootVerified == restoreFailure)
            #expect(!journal.noMutationNeeded)
        }
    }

    @Test("Retained AMFI disable recovery failures retain the host intent")
    func retainedConfiguredAMFIDisableFailuresRetainJournal() async throws {
        let cases: [(String, WorkflowDependencyFailure?, ConfiguredAMFIRecoveryFailure?, Bool)] = [
            ("missing credentials", .prepareOwner, nil, false),
            ("invalid receipt", nil, nil, true),
            ("normal-stage failure", nil, .callback, false)
        ]

        for retryPhase in [PommeSecurityWorkflowPhase.securityMutationIntent,
                           PommeSecurityWorkflowPhase.securityMutationVerified] {
            for (name, dependencyFailure, recoveryFailure, invalidReceipt) in cases {
                let harness = try WorkflowHarness()
                defer { harness.cleanup() }
                let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
                defer { lease.release() }

                let progress = try harness.progress(
                    operation: .amfiDisable,
                    originalRunState: .running(.normal),
                    requestedFinalState: .stopped,
                    owner: try harness.existingOwner(),
                    lease: lease
                )
                try progress.advance(.accountCreationVerified)
                try progress.advance(.securityMutationIntent)
                if retryPhase == .securityMutationVerified {
                    try progress.advance(.securityMutationVerified)
                }

                let recorder = WorkflowRecorder()
                let dependencies = harness.dependencies(
                    operation: .amfiDisable,
                    state: .init(
                        disabled: false,
                        baselinePresent: true,
                        reconciliationRequired: true,
                        baselinePhase: "disabledConfigured"
                    ),
                    recorder: recorder,
                    failure: dependencyFailure,
                    configuredRecoveryFailure: recoveryFailure,
                    recoverConfiguredAMFI: { _ in
                        .object([
                            "verified": .bool(true),
                            "amfiDisabled": .bool(!invalidReceipt)
                        ])
                    }
                )

                do {
                    _ = try await PommeSecurityWorkflow.run(
                        progress: progress,
                        dependencies: dependencies
                    )
                    Issue.record("Retained AMFI recovery unexpectedly succeeded for \(name)")
                } catch {
                    if let dependencyFailure {
                        #expect(error as? WorkflowDependencyFailure == dependencyFailure)
                    } else if let recoveryFailure {
                        #expect(error as? ConfiguredAMFIRecoveryFailure == recoveryFailure)
                    } else {
                        #expect(error as? PommeSecurityWorkflowError == .statusUnverified)
                    }
                }
                #expect(recorder.count(.prepareOwner) == 1)
                #expect(recorder.count(.recoverConfiguredAMFI) == (dependencyFailure == nil ? 1 : 0))
                #expect(recorder.count(.mutate) == 0)
                #expect(recorder.count(.verifyNormalBoot) == 0)
                #expect(recorder.restoreStates == (dependencyFailure == .prepareOwner ? [] : [.running(.normal)]))

                let journal = try harness.store.load(lease: lease)
                #expect(journal.phase == retryPhase)
                #expect(!journal.normalBootVerified)
                #expect(!journal.noMutationNeeded)
            }
        }
    }

    @Test("A valid partial AMFI receipt re-enters the normal stage")
    func amfiPartialReceiptResumesMutation() async throws {
        let harness = try WorkflowHarness()
        defer { harness.cleanup() }
        let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
        defer { lease.release() }

        let progress = try harness.progress(
            operation: .amfiDisable,
            originalRunState: .running(.normal),
            requestedFinalState: .stopped,
            owner: try harness.existingOwner(),
            lease: lease
        )
        try progress.advance(.accountCreationVerified)
        try progress.advance(.securityMutationIntent)

        let recorder = WorkflowRecorder()
        let dependencies = harness.dependencies(
            operation: .amfiDisable,
            state: .init(
                disabled: false,
                baselinePresent: true,
                reconciliationRequired: true,
                baselinePhase: "policyApplied"
            ),
            recorder: recorder,
            recoverConfiguredAMFI: { _ in
                .object(["verified": .bool(true), "amfiDisabled": .bool(true)])
            }
        )

        let result = try await PommeSecurityWorkflow.run(
            progress: progress,
            dependencies: dependencies
        )
        let payload = try #require(result.objectValue)
        #expect(payload["noOp"] == .bool(false))
        #expect(payload["normalBootVerified"] == .bool(true))
        #expect(recorder.count(.prepareOwner) == 1)
        #expect(recorder.count(.recoverConfiguredAMFI) == 1)
        #expect(recorder.count(.mutate) == 0)
        #expect(recorder.count(.verifyNormalBoot) == 1)
        #expect(recorder.restoreStates == [.stopped])
    }

    @Test("A mismatched or unknown AMFI receipt fails closed before owner preparation")
    func amfiReceiptBackedRetryRejectsMismatchedOrUnknownReceipt() async throws {
        let cases: [(
            PommeSecurityWorkflowOperation,
            Bool,
            String
        )] = [
            (.amfiDisable, false, "disabledConfigured"),
            (.amfiEnable, false, "disabledConfigured"),
            (.amfiDisable, true, "unrecognizedPhase"),
        ]

        for (operation, disabled, baselinePhase) in cases {
            let harness = try WorkflowHarness()
            defer { harness.cleanup() }
            let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
            defer { lease.release() }

            let progress = try harness.progress(
                operation: operation,
                originalRunState: .running(.normal),
                requestedFinalState: .stopped,
                owner: try harness.existingOwner(),
                lease: lease
            )
            try progress.advance(.accountCreationVerified)
            try progress.advance(.securityMutationIntent)

            let recorder = WorkflowRecorder()
            let dependencies = harness.dependencies(
                operation: operation,
                state: .init(
                    disabled: disabled,
                    baselinePresent: true,
                    reconciliationRequired: true,
                    baselinePhase: baselinePhase
                ),
                recorder: recorder
            )

            do {
                _ = try await PommeSecurityWorkflow.run(
                    progress: progress,
                    dependencies: dependencies
                )
                Issue.record("An invalid AMFI receipt unexpectedly resumed")
            } catch {
                #expect(error as? PommeSecurityWorkflowError == .incompleteTransaction)
            }
            #expect(recorder.count(.prepareOwner) == 0)
            #expect(recorder.count(.mutate) == 0)
            #expect(recorder.count(.verifyNormalBoot) == 0)
            #expect(recorder.restoreStates == [.running(.normal)])

            let journal = try harness.store.load(lease: lease)
            #expect(journal.phase == .securityMutationIntent)
            #expect(!journal.normalBootVerified)
            #expect(!journal.noMutationNeeded)
        }
    }

    @Test("Receipt-backed normal proof failure retains the journal and restores the original state")
    func amfiReceiptBackedRetryRetainsJournalWhenNormalProofFails() async throws {
        for operation in [PommeSecurityWorkflowOperation.amfiDisable,
                          PommeSecurityWorkflowOperation.amfiEnable] {
            for retryPhase in [PommeSecurityWorkflowPhase.securityMutationIntent,
                               PommeSecurityWorkflowPhase.securityMutationVerified] {
                let harness = try WorkflowHarness()
                defer { harness.cleanup() }
                let lease = try VMBundleMutationLease.acquire(name: harness.vmName)
                defer { lease.release() }

                let progress = try harness.progress(
                    operation: operation,
                    originalRunState: .running(.normal),
                    requestedFinalState: .stopped,
                    owner: try harness.existingOwner(),
                    lease: lease
                )
                try progress.advance(.accountCreationVerified)
                try progress.advance(.securityMutationIntent)
                if retryPhase == .securityMutationVerified {
                    try progress.advance(.securityMutationVerified)
                }

                let recorder = WorkflowRecorder()
                let dependencies = harness.dependencies(
                    operation: operation,
                    state: .init(
                        disabled: operation.requestsDisabled,
                        baselinePresent: true,
                        reconciliationRequired: true,
                        baselinePhase: operation.requestsDisabled
                            ? "disabledConfigured" : "enabledConfigured"
                    ),
                    recorder: recorder,
                    failure: .verifyNormalBoot
                )

                do {
                    _ = try await PommeSecurityWorkflow.run(
                        progress: progress,
                        dependencies: dependencies
                    )
                    Issue.record("AMFI retry unexpectedly passed failed normal proof")
                } catch {
                    #expect(error as? WorkflowDependencyFailure == .verifyNormalBoot)
                }
                #expect(recorder.count(.prepareOwner) == 0)
                #expect(recorder.count(.mutate) == 0)
                #expect(recorder.count(.verifyNormalBoot) == 1)
                #expect(recorder.restoreStates == [.running(.normal)])

                let journal = try harness.store.load(lease: lease)
                #expect(journal.phase == .securityMutationVerified)
                #expect(!journal.normalBootVerified)
                #expect(!journal.noMutationNeeded)
            }
        }
    }
}

private enum WorkflowDependencyFailure: Error, CaseIterable, Equatable, Sendable {
    case observe
    case prepareOwner
    case mutate
    case verifyNormalBoot
    case restore
}

private enum CleanupFailure: CaseIterable, Sendable {
    case session
    case integration
}

private enum ConfiguredAMFIRecoveryFailure: Error, Equatable, Sendable {
    case callback
}

private final class WorkflowRecorder: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case observe
        case prepareOwner
        case mutate
        case recoverConfiguredAMFI
        case verifyNormalBoot
        case restore(VMRunStateSnapshot)
    }

    private let lock = NSLock()
    private var values: [Event] = []

    var events: [Event] {
        lock.withLock { values }
    }

    var restoreStates: [VMRunStateSnapshot] {
        events.compactMap { event in
            guard case .restore(let state) = event else { return nil }
            return state
        }
    }

    func record(_ event: Event) {
        lock.withLock { values.append(event) }
    }

    func count(_ event: Event) -> Int {
        events.filter { $0 == event }.count
    }
}

private struct WorkflowHarness: Sendable {
    let bundleURL: URL
    let vmName: String
    let identity: PommeSecurityWorkflowIdentity
    let store: PommeSecurityWorkflowJournalStore
    let generatedUID: UUID

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-security-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard chmod(root.path, 0o700) == 0 else { throw WorkflowHarnessError.fileSystem }

        let vmName = "workflow-\(UUID().uuidString.lowercased())"
        self.bundleURL = root
        self.vmName = vmName
        self.identity = try PommeSecurityWorkflowIdentity(
            vmName: vmName,
            vmUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            machineIdentifierSHA256: String(repeating: "a", count: 64),
            diskImageFileResourceID: "1:2",
            startupVolumeGroupUUID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            volumeVUID: "vuid-1",
            immutableProvisioningPlanDigest: String(repeating: "b", count: 64)
        )
        self.store = PommeSecurityWorkflowJournalStore(bundleURL: root)
        self.generatedUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    }

    func existingOwner() throws -> PommeSecurityWorkflowOwnerRecord {
        try PommeSecurityWorkflowOwnerRecord(
            accountUsername: "pomme",
            ownerPreparation: .existing,
            generatedUID: generatedUID
        )
    }

    func progress(
        operation: PommeSecurityWorkflowOperation,
        originalRunState: VMRunStateSnapshot,
        requestedFinalState: VMFinalState,
        owner: PommeSecurityWorkflowOwnerRecord? = nil,
        credential: PommeOwnerCredentialReference? = nil,
        lease: VMBundleMutationLease
    ) throws -> PommeSecurityWorkflowProgress {
        let journal = try store.begin(
            operation: operation,
            identity: identity,
            originalRunState: originalRunState,
            requestedFinalState: requestedFinalState,
            credential: credential,
            lease: lease,
            owner: owner
        )
        return PommeSecurityWorkflowProgress(journal, store: store, lease: lease)
    }

    func dependencies(
        operation: PommeSecurityWorkflowOperation,
        state: PommeSecurityWorkflowState,
        recorder: WorkflowRecorder,
        advancesOwnerPreparation: Bool = false,
        failure: WorkflowDependencyFailure? = nil,
        cleanupFailure: CleanupFailure? = nil,
        configuredRecoveryFailure: ConfiguredAMFIRecoveryFailure? = nil,
        recoverConfiguredAMFI: (@Sendable (PommeGuestSecurityCredentials) async throws -> JSONValue)? = nil
    ) -> PommeSecurityWorkflowDependencies {
        let recovered: (@Sendable (PommeGuestSecurityCredentials) async throws -> JSONValue)?
        if let callback = recoverConfiguredAMFI {
            recovered = { credentials in
                recorder.record(.recoverConfiguredAMFI)
                if let configuredRecoveryFailure {
                    throw configuredRecoveryFailure
                }
                return try await callback(credentials)
            }
        } else {
            recovered = nil
        }
        return PommeSecurityWorkflowDependencies(
            observe: {
                recorder.record(.observe)
                if let cleanupFailure {
                    switch cleanupFailure {
                    case .session:
                        throw PommeRecoverySessionError.cleanupFailed
                    case .integration:
                        throw PommeLiveRecoveryIntegration.Error.cleanupFailed
                    }
                }
                if failure == .observe { throw WorkflowDependencyFailure.observe }
                return state
            },
            prepareOwner: { progress in
                recorder.record(.prepareOwner)
                if failure == .prepareOwner { throw WorkflowDependencyFailure.prepareOwner }
                if advancesOwnerPreparation {
                    try progress.advance(.accountCreationVerified)
                }
                return try PommeGuestSecurityCredentials(
                    username: "pomme",
                    password: "offline-test-secret"
                )
            },
            mutate: { _ in
                recorder.record(.mutate)
                if failure == .mutate { throw WorkflowDependencyFailure.mutate }
                var output: [String: JSONValue] = ["verified": .bool(true)]
                output[operation.isSIP ? "sipDisabled" : "amfiDisabled"] =
                    .bool(operation.requestsDisabled)
                return .object(output)
            },
            verifyNormalBoot: {
                recorder.record(.verifyNormalBoot)
                if failure == .verifyNormalBoot {
                    throw WorkflowDependencyFailure.verifyNormalBoot
                }
            },
            restore: { state in
                recorder.record(.restore(state))
                if failure == .restore { throw WorkflowDependencyFailure.restore }
            },
            log: { _ in },
            recoverConfiguredAMFI: recovered
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: bundleURL)
    }
}

private enum WorkflowHarnessError: Error {
    case fileSystem
}
