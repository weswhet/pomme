import Foundation

/// A CLI-facing wrapper that keeps the original failure while telling the
/// caller how to resume the exact retained security request.
struct PommeSecurityWorkflowResumeDiagnostic: Error, LocalizedError {
  let underlyingDescription: String
  let command: String

  var errorDescription: String? {
    "\(underlyingDescription) Resume the retained security operation with `\(command)` after resolving any reported cleanup or restoration failure; the operation and final state must match the retained transaction."
  }
}

enum PommeSecurityWorkflowResumeGuidance {
  /// Reloads the journal under the caller's mutation lease and accepts it for
  /// guidance only when its immutable identity matches the current VM. A
  /// terminal journal must never produce a stale retry command.
  static func latestTrustedRetainedJournal(
    store: PommeSecurityWorkflowJournalStore,
    identity: PommeSecurityWorkflowIdentity,
    lease: VMBundleMutationLease
  ) -> PommeSecurityWorkflowJournal? {
    let journal: PommeSecurityWorkflowJournal?
    do {
      journal = try store.loadIfPresent(lease: lease)
    } catch {
      return nil
    }
    guard let journal,
      journal.identity.isWellFormed(),
      journal.identity.matches(identity),
      journal.phase != .restorationComplete,
      journal.phase != .preflightRejected
    else {
      return nil
    }
    return journal
  }

  static func diagnostic(
    for error: Error,
    journal: PommeSecurityWorkflowJournal
  ) -> PommeSecurityWorkflowResumeDiagnostic {
    .init(
      underlyingDescription: error.localizedDescription,
      command: command(for: journal)
    )
  }

  static func appendingGuidance(
    to error: Error,
    journal: PommeSecurityWorkflowJournal
  ) -> Error {
    guard !isRestorationBarrier(error) else { return error }
    return diagnostic(for: error, journal: journal)
  }

  static func command(for journal: PommeSecurityWorkflowJournal) -> String {
    command(
      operation: journal.operation,
      vmName: journal.identity.vmName,
      finalState: journal.requestedFinalState
    )
  }

  static func command(
    operation: PommeSecurityWorkflowOperation,
    vmName: String,
    finalState: VMFinalState
  ) -> String {
    "pomme \(operation.commandFamily) \(operation.commandAction) \(shellQuote(vmName)) --final-state \(finalState.rawValue)"
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
  }

  private static func isRestorationBarrier(_ error: Error) -> Bool {
    (error as? PommeSecurityWorkflowError) == .restorationIncomplete
      || (error as? PommeRecoverySessionError) == .cleanupFailed
      || (error as? PommeLiveRecoveryIntegration.Error) == .cleanupFailed
  }
}

private extension PommeSecurityWorkflowOperation {
  var commandFamily: String {
    isSIP ? "sip" : "amfi"
  }

  var commandAction: String {
    requestsDisabled ? "disable" : "enable"
  }
}
