import Foundation
import Testing

@Suite("AMFI security preflight")
struct PommeSecurityAMFIPreflightTests {
  @Test("AMFI preflight observes state before applying the SIP prerequisite")
  func stateFirstSIPRequirementMatrix() async throws {
    let cases: [Case] = [
      // An already-disabled AMFI request is safe to inspect without a SIP boot.
      .init(
        operation: .amfiDisable,
        state: state(disabled: true, baselinePresent: false),
        events: [.observe]),
      .init(
        operation: .amfiDisable,
        state: state(disabled: true, baselinePresent: true),
        events: [.observe]),
      // AMFI disable still needs the SIP gate when the state or reconciliation
      // cursor says that a mutation remains unresolved.
      .init(
        operation: .amfiDisable,
        state: state(disabled: true, reconciliationRequired: true),
        events: [.observe, .require]),
      .init(
        operation: .amfiDisable,
        state: state(disabled: false),
        events: [.observe, .require]),
      // AMFI enable can skip the gate only for a clean, already-enabled state
      // with no retained baseline that must be reconciled.
      .init(
        operation: .amfiEnable,
        state: state(disabled: false),
        events: [.observe]),
      .init(
        operation: .amfiEnable,
        state: state(disabled: false, baselinePresent: true),
        events: [.observe, .require]),
      .init(
        operation: .amfiEnable,
        state: state(disabled: false, reconciliationRequired: true),
        events: [.observe, .require]),
      .init(
        operation: .amfiEnable,
        state: state(disabled: true),
        events: [.observe, .require]),
    ]

    for fixture in cases {
      let trace = PreflightTrace()

      let observed = try await PommeSecurityAMFIPreflight.inspect(
        operation: fixture.operation,
        observeAMFI: {
          await trace.record(.observe)
          return fixture.state
        },
        requireSIPDisabled: {
          await trace.record(.require)
        })

      #expect(observed == fixture.state)
      #expect(await trace.events == fixture.events)
    }
  }

  @Test("AMFI state observation errors prevent the SIP prerequisite")
  func observationErrorPropagatesBeforePrerequisite() async {
    let trace = PreflightTrace()
    let expected = PreflightTestError.observation

    do {
      _ = try await PommeSecurityAMFIPreflight.inspect(
        operation: .amfiDisable,
        observeAMFI: {
          await trace.record(.observe)
          throw expected
        },
        requireSIPDisabled: {
          await trace.record(.require)
        })
      Issue.record("AMFI preflight unexpectedly succeeded after observation failure")
    } catch {
      #expect(error as? PreflightTestError == expected)
    }

    #expect(await trace.events == [.observe])
  }

  @Test("The SIP prerequisite error is returned without adding workflow effects")
  func SIPPrerequisiteErrorPropagates() async {
    let trace = PreflightTrace()
    let expected = PreflightTestError.sipPrerequisite

    do {
      _ = try await PommeSecurityAMFIPreflight.inspect(
        operation: .amfiEnable,
        observeAMFI: {
          await trace.record(.observe)
          return state(disabled: true)
        },
        requireSIPDisabled: {
          await trace.record(.require)
          throw expected
        })
      Issue.record("AMFI preflight unexpectedly succeeded after SIP prerequisite failure")
    } catch {
      #expect(error as? PreflightTestError == expected)
    }

    #expect(await trace.events == [.observe, .require])
  }

  @Test("SIP operations are rejected before state observation")
  func SIPOperationsAreInvalid() async {
    for operation in [PommeSecurityWorkflowOperation.sipDisable,
                      PommeSecurityWorkflowOperation.sipEnable] {
      let trace = PreflightTrace()

      do {
        _ = try await PommeSecurityAMFIPreflight.inspect(
          operation: operation,
          observeAMFI: {
            await trace.record(.observe)
            return state(disabled: false)
          },
          requireSIPDisabled: {
            await trace.record(.require)
          })
        Issue.record("SIP operation unexpectedly passed AMFI preflight")
      } catch {
        #expect(error as? PommeSecurityAMFIPreflightError == .invalidOperation)
      }

      #expect(await trace.events.isEmpty)
    }
  }

  @Test("Retained preflight recognizes only the eligible typed snapshot-pending checkpoint")
  func retainedCheckpointObservation() async throws {
    let trace = PreflightTrace()
    let journal = try retainedJournal()

    let observation = try await PommeSecurityAMFIPreflight.inspectRetained(
      journal: journal,
      observeAMFI: {
        await trace.record(.observe)
        throw PommeRecoveryGuestOperationFailure(code: .snapshotPending)
      },
      requireSIPDisabled: {
        await trace.record(.require)
      })

    #expect(observation == .retainedNormalCheckpoint)
    #expect(await trace.events == [.observe, .require])
  }

  @Test("Retained preflight does not match message-lookalike or other typed failures")
  func retainedCheckpointFailureMatchingIsClosed() async throws {
    let journal = try retainedJournal()
    let cases: [RetainedFailureFixture] = [.messageLookalike, .otherTypedCode]

    for fixture in cases {
      let trace = PreflightTrace()
      do {
        _ = try await PommeSecurityAMFIPreflight.inspectRetained(
          journal: journal,
          observeAMFI: {
            await trace.record(.observe)
            switch fixture {
            case .messageLookalike:
              throw PreflightTestError.snapshotPendingMessage
            case .otherTypedCode:
              throw PommeRecoveryGuestOperationFailure(code: .rollbackFailed)
            }
          },
          requireSIPDisabled: {
            await trace.record(.require)
          })
        Issue.record("Retained preflight unexpectedly accepted a non-pending failure")
      } catch {
        switch fixture {
        case .messageLookalike:
          #expect(error as? PreflightTestError == .snapshotPendingMessage)
        case .otherTypedCode:
          #expect(error as? PommeRecoveryGuestOperationFailure
            == PommeRecoveryGuestOperationFailure(code: .rollbackFailed))
        }
      }
      #expect(await trace.events == [.observe])
    }
  }

  @Test("Retained preflight rejects an ineligible journal without applying the SIP prerequisite")
  func retainedCheckpointRequiresEligibleJournal() async throws {
    let journal = try retainedJournal(
      operation: .amfiEnable,
      phase: .securityMutationVerified)
    let trace = PreflightTrace()

    do {
      _ = try await PommeSecurityAMFIPreflight.inspectRetained(
        journal: journal,
        observeAMFI: {
          await trace.record(.observe)
          throw PommeRecoveryGuestOperationFailure(code: .snapshotPending)
        },
        requireSIPDisabled: {
          await trace.record(.require)
        })
      Issue.record("Ineligible retained journal unexpectedly succeeded")
    } catch {
      #expect(error as? PommeRecoveryGuestOperationFailure
        == PommeRecoveryGuestOperationFailure(code: .snapshotPending))
    }
    #expect(await trace.events == [.observe])
  }

  @Test("Retained checkpoint still requires and propagates the SIP prerequisite")
  func retainedCheckpointSIPFailurePropagates() async throws {
    let journal = try retainedJournal()
    let trace = PreflightTrace()
    let expected = PreflightTestError.sipPrerequisite

    do {
      _ = try await PommeSecurityAMFIPreflight.inspectRetained(
        journal: journal,
        observeAMFI: {
          await trace.record(.observe)
          throw PommeRecoveryGuestOperationFailure(code: .snapshotPending)
        },
        requireSIPDisabled: {
          await trace.record(.require)
          throw expected
        })
      Issue.record("Retained preflight unexpectedly ignored the SIP prerequisite")
    } catch {
      #expect(error as? PreflightTestError == expected)
    }
    #expect(await trace.events == [.observe, .require])
  }

  @Test("Retained preflight preserves ordinary state observation and SIP behavior")
  func retainedCheckpointOrdinaryStateUsesExistingRules() async throws {
    let journal = try retainedJournal()
    let trace = PreflightTrace()
    let state = state(disabled: false, baselinePresent: true)

    let observation = try await PommeSecurityAMFIPreflight.inspectRetained(
      journal: journal,
      observeAMFI: {
        await trace.record(.observe)
        return state
      },
      requireSIPDisabled: {
        await trace.record(.require)
      })

    #expect(observation == .state(state))
    #expect(await trace.events == [.observe, .require])
  }
}

private struct Case: Sendable {
  let operation: PommeSecurityWorkflowOperation
  let state: PommeSecurityWorkflowState
  let events: [PreflightTrace.Event]
}

private actor PreflightTrace {
  enum Event: Equatable, Sendable {
    case observe
    case require
  }

  private(set) var events: [Event] = []

  func record(_ event: Event) {
    events.append(event)
  }
}

private enum PreflightTestError: Error, Equatable, LocalizedError, Sendable {
  case observation
  case sipPrerequisite
  case snapshotPendingMessage

  var errorDescription: String? {
    switch self {
    case .observation: "observation failed"
    case .sipPrerequisite: "SIP prerequisite failed"
    case .snapshotPendingMessage: "recovery-snapshot-pending"
    }
  }
}

private enum RetainedFailureFixture: Sendable {
  case messageLookalike
  case otherTypedCode
}

private func retainedJournal(
  operation: PommeSecurityWorkflowOperation = .amfiDisable,
  phase: PommeSecurityWorkflowPhase = .securityMutationIntent,
  ownerPreparation: PommeSecurityWorkflowOwnerPreparation = .existing,
  generatedUID: UUID? = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
) throws -> PommeSecurityWorkflowJournal {
  let identity = try PommeSecurityWorkflowIdentity(
    vmName: "preflight-test",
    vmUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
    machineIdentifierSHA256: String(repeating: "a", count: 64),
    diskImageFileResourceID: "1:2",
    startupVolumeGroupUUID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
    volumeVUID: "vuid-1",
    immutableProvisioningPlanDigest: String(repeating: "b", count: 64))
  let owner = try PommeSecurityWorkflowOwnerRecord(
    accountUsername: "pomme",
    ownerPreparation: ownerPreparation,
    generatedUID: generatedUID)
  let date = Date(timeIntervalSince1970: 10)
  return try PommeSecurityWorkflowJournal(
    generation: 1,
    identity: identity,
    operation: operation,
    originalRunState: .running(.normal),
    requestedFinalState: .stopped,
    credential: nil,
    phase: phase,
    createdAt: date,
    updatedAt: date,
    owner: owner)
}

private func state(
  disabled: Bool,
  baselinePresent: Bool = false,
  reconciliationRequired: Bool = false,
  baselinePhase: String? = nil
) -> PommeSecurityWorkflowState {
  PommeSecurityWorkflowState(
    disabled: disabled,
    baselinePresent: baselinePresent,
    reconciliationRequired: reconciliationRequired,
    baselinePhase: baselinePhase)
}
