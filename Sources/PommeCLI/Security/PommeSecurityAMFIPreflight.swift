import Foundation

/// Errors raised before an AMFI workflow can publish a durable journal.
enum PommeSecurityAMFIPreflightError: Error, Equatable, LocalizedError, Sendable {
  case invalidOperation

  var errorDescription: String? {
    switch self {
    case .invalidOperation:
      "AMFI preflight received a SIP operation."
    }
  }
}

enum PommeSecurityAMFIPreflightObservation: Equatable, Sendable {
  case state(PommeSecurityWorkflowState)
  case retainedNormalCheckpoint
}

/// Performs the read-only AMFI/SIP gate before a workflow begins journaling.
///
/// The AMFI state is always observed first. A SIP check is unnecessary only
/// when the requested state is already present, there is no retained
/// reconciliation, and either this is an AMFI disable request or no baseline
/// is retained. Every other AMFI path requires an independently verified SIP
/// disabled result before credentials or a journal can be reached.
enum PommeSecurityAMFIPreflight {
  static func inspect(
    operation: PommeSecurityWorkflowOperation,
    observeAMFI: @Sendable () async throws -> PommeSecurityWorkflowState,
    requireSIPDisabled: @Sendable () async throws -> Void
  ) async throws -> PommeSecurityWorkflowState {
    try validate(operation: operation)
    let state = try await observeAMFI()
    return try await inspect(
      operation: operation,
      state: state,
      requireSIPDisabled: requireSIPDisabled
    )
  }

  /// Performs the ordinary preflight while recognizing the one retained
  /// normal-checkpoint recovery path. The observation is captured exactly
  /// once: a typed `snapshotPending` from `observeAMFI` may enter the retained
  /// path, while failures from the SIP prerequisite never do.
  static func inspectRetained(
    journal: PommeSecurityWorkflowJournal,
    observeAMFI: @Sendable () async throws -> PommeSecurityWorkflowState,
    requireSIPDisabled: @Sendable () async throws -> Void
  ) async throws -> PommeSecurityAMFIPreflightObservation {
    try validate(operation: journal.operation)
    let state: PommeSecurityWorkflowState
    do {
      state = try await observeAMFI()
    } catch let failure as PommeRecoveryGuestOperationFailure {
      guard failure.code == .snapshotPending,
        PommeSecurityWorkflow.canResumeRetainedAMFINormalCheckpoint(journal)
      else { throw failure }
      try await requireSIPDisabled()
      return .retainedNormalCheckpoint
    }
    return .state(try await inspect(
      operation: journal.operation,
      state: state,
      requireSIPDisabled: requireSIPDisabled
    ))
  }

  private static func validate(operation: PommeSecurityWorkflowOperation) throws {
    guard operation == .amfiDisable || operation == .amfiEnable else {
      throw PommeSecurityAMFIPreflightError.invalidOperation
    }
  }

  private static func inspect(
    operation: PommeSecurityWorkflowOperation,
    state: PommeSecurityWorkflowState,
    requireSIPDisabled: @Sendable () async throws -> Void
  ) async throws -> PommeSecurityWorkflowState {
    let alreadyRequested = state.disabled == operation.requestsDisabled
    let canSkipSIPCheck =
      alreadyRequested
      && !state.reconciliationRequired
      && (operation == .amfiDisable || !state.baselinePresent)

    if !canSkipSIPCheck {
      try await requireSIPDisabled()
    }
    return state
  }
}
