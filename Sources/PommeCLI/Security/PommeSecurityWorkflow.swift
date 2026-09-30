import Foundation

/// One sequential durable cursor, shared with the synchronous native-tool
/// callbacks. The per-VM lease covers the complete lifetime of this cursor.
final class PommeSecurityWorkflowProgress: @unchecked Sendable {
  let store: PommeSecurityWorkflowJournalStore
  let lease: VMBundleMutationLease
  private let lock = NSLock()
  private var value: PommeSecurityWorkflowJournal

  init(
    _ journal: PommeSecurityWorkflowJournal, store: PommeSecurityWorkflowJournalStore,
    lease: VMBundleMutationLease
  ) {
    value = journal
    self.store = store
    self.lease = lease
  }

  var journal: PommeSecurityWorkflowJournal { lock.withLock { value } }
  @discardableResult
  func update(_ body: (PommeSecurityWorkflowJournal) throws -> PommeSecurityWorkflowJournal)
    rethrows -> PommeSecurityWorkflowJournal
  {
    try lock.withLock {
      value = try body(value)
      return value
    }
  }
  func advance(_ phase: PommeSecurityWorkflowPhase) throws {
    try update { try store.advance($0, to: phase, lease: lease) }
  }
}

struct PommeSecurityWorkflowDependencies: Sendable {
  let observe: @Sendable () async throws -> PommeSecurityWorkflowState
  let prepareOwner:
    @Sendable (PommeSecurityWorkflowProgress) async throws -> PommeGuestSecurityCredentials
  let mutate: @Sendable (PommeGuestSecurityCredentials) async throws -> JSONValue
  let recoverConfiguredAMFI:
    (@Sendable (PommeGuestSecurityCredentials) async throws -> JSONValue)?
  let verifyNormalBoot: @Sendable () async throws -> Void
  let restore: @Sendable (VMRunStateSnapshot) async throws -> Void
  let log: @Sendable (String) -> Void

  init(
    observe: @escaping @Sendable () async throws -> PommeSecurityWorkflowState,
    prepareOwner: @escaping @Sendable (PommeSecurityWorkflowProgress) async throws
      -> PommeGuestSecurityCredentials,
    mutate: @escaping @Sendable (PommeGuestSecurityCredentials) async throws -> JSONValue,
    verifyNormalBoot: @escaping @Sendable () async throws -> Void,
    restore: @escaping @Sendable (VMRunStateSnapshot) async throws -> Void,
    log: @escaping @Sendable (String) -> Void,
    recoverConfiguredAMFI: (@Sendable (PommeGuestSecurityCredentials) async throws -> JSONValue)? = nil
  ) {
    self.observe = observe
    self.prepareOwner = prepareOwner
    self.mutate = mutate
    self.verifyNormalBoot = verifyNormalBoot
    self.restore = restore
    self.log = log
    self.recoverConfiguredAMFI = recoverConfiguredAMFI
  }
}

enum PommeSecurityWorkflow {
  static func canResumeRetainedAMFINormalCheckpoint(
    _ journal: PommeSecurityWorkflowJournal
  ) -> Bool {
    journal.operation == .amfiDisable
      && [.securityMutationIntent, .securityMutationVerified].contains(journal.phase)
      && journal.owner?.ownerPreparation == .existing
      && journal.owner?.generatedUID != nil
  }

  /// State is observed before the credential callback is reachable. An
  /// interrupted mutation is reconciled using guest read-back and the
  /// retained phase before applying the requested operation again.
  static func run(
    progress: PommeSecurityWorkflowProgress,
    dependencies: PommeSecurityWorkflowDependencies
  ) async throws -> JSONValue {
    guard ![.preflightIntent, .preflightRejected].contains(progress.journal.phase) else {
      throw PommeSecurityWorkflowError.incompleteTransaction
    }
    let operation = progress.journal.operation
    let target = progress.journal.originalRunState.resolving(progress.journal.requestedFinalState)
    var normalBootVerified = progress.journal.normalBootVerified
    var noOp = progress.journal.noMutationNeeded
    do {
      dependencies.log("Inspecting security state before owner preparation.")
      PommeProgressContext.sink?.step(vm: progress.journal.identity.vmName, "Checking security state")
      let state = try await dependencies.observe()
      let matches = state.disabled == operation.requestsDisabled
      let baselineNeedsRestoration = operation == .amfiEnable && state.baselinePresent
      let reconciled = !state.reconciliationRequired && !baselineNeedsRestoration
      let phase = progress.journal.phase
      let retainedPartialNormalAMFIDisable =
        state.baselinePhase == "policyApplied"
        || state.baselinePhase == "normalNVRAMApplying"
        || state.baselinePhase == "normalNVRAMApplied"
      let retainedConfiguredAMFIDisable = operation == .amfiDisable
        && (phase == .securityMutationIntent || phase == .securityMutationVerified)
        && progress.journal.owner?.ownerPreparation == .existing
        && progress.journal.owner?.generatedUID != nil
        && state.baselinePresent
        && state.reconciliationRequired
        && ((state.baselinePhase == "disabledConfigured" && !state.disabled)
          || retainedPartialNormalAMFIDisable)
      // Staged AMFI retains its baseline until a new normal boot proves the
      // effective arguments. These guest phases require complete policy and
      // NVRAM receipts; they authorize verification, never a fresh no-op.
      let awaitingAMFIBoot = !operation.isSIP && state.baselinePresent && matches
        && state.baselinePhase == (operation.requestsDisabled ? "disabledConfigured" : "enabledConfigured")
      let mutationConfigured = reconciled || awaitingAMFIBoot
      if !operation.isSIP, state.baselinePresent, let baselinePhase = state.baselinePhase {
        guard PommeGuestAMFITransactionPhase(rawValue: baselinePhase) != nil else {
          throw PommeSecurityWorkflowError.incompleteTransaction
        }
        if ["disabledConfigured", "enabledConfigured"].contains(baselinePhase),
           !awaitingAMFIBoot, !retainedConfiguredAMFIDisable {
          throw PommeSecurityWorkflowError.incompleteTransaction
        }
      }

      if [.noMutationVerified, .restorationPending].contains(phase) {
        guard matches, reconciled else { throw PommeSecurityWorkflowError.incompleteTransaction }
        if phase == .noMutationVerified { try progress.advance(.restorationPending) }
        try await restoreWithProgress(target, progress: progress, dependencies: dependencies)
        try progress.advance(.restorationComplete)
        return result(
          progress: progress, noOp: progress.journal.noMutationNeeded,
          normalBootVerified: progress.journal.normalBootVerified)
      }

      if matches, reconciled, [.credentialPending, .credentialStored].contains(phase) {
        noOp = true
        dependencies.log("The requested security state is already configured.")
        try progress.advance(.noMutationVerified)
      } else {
        if operation == .amfiEnable, state.disabled, !state.baselinePresent {
          throw PommeSecurityWorkflowError.missingBaseline
        }
        switch progress.journal.phase {
        case .normalBootVerified:
          guard matches, reconciled else { throw PommeSecurityWorkflowError.incompleteTransaction }
          normalBootVerified = true
        case .securityMutationVerified where retainedConfiguredAMFIDisable:
          try await recoverConfiguredAMFIDisable(
            progress: progress, dependencies: dependencies)
        case .securityMutationVerified:
          guard matches, mutationConfigured else { throw PommeSecurityWorkflowError.incompleteTransaction }
        case .securityMutationIntent where matches && mutationConfigured:
          dependencies.log("Reconciled the interrupted security write from retained receipts and read-back.")
          try progress.advance(.securityMutationVerified)
        case .securityMutationIntent where retainedConfiguredAMFIDisable:
          try await recoverConfiguredAMFIDisable(
            progress: progress, dependencies: dependencies)
        default:
          let credentials = try await prepareOwnerPreservingFailure(progress: progress, dependencies: dependencies)
          if progress.journal.phase != .securityMutationIntent {
            try progress.advance(.securityMutationIntent)
          }
          dependencies.log(operation.isSIP
            ? "Applying the requested change in authenticated Recovery."
            : "Applying the journaled AMFI policy and normal-boot NVRAM stages.")
          PommeProgressContext.sink?.step(vm: progress.journal.identity.vmName,
            (operation.requestsDisabled ? "Disabling " : "Enabling ") + (operation.isSIP ? "SIP" : "AMFI"))
          let output = try await dependencies.mutate(credentials)
          guard output.objectValue?["verified"] == .bool(true) else {
            throw PommeSecurityWorkflowError.statusUnverified
          }
          // The guest performs policy/NVRAM read-back before its
          // receipt. No boot-argument inspection is called proof of
          // live AMFI enforcement.
          let key = operation.isSIP ? "sipDisabled" : "amfiDisabled"
          guard output.objectValue?[key] == .bool(operation.requestsDisabled) else {
            throw PommeSecurityWorkflowError.statusUnverified
          }
          try progress.advance(.securityMutationVerified)
        }
        if progress.journal.phase == .securityMutationVerified {
          dependencies.log("Verifying configuration after a normal boot.")
          try await verifyNormalBootWithProgress(progress: progress, dependencies: dependencies)
          normalBootVerified = true
          try progress.advance(.normalBootVerified)
        }
      }
      try progress.advance(.restorationPending)
      dependencies.log("Restoring the requested VM run state.")
      try await restoreWithProgress(target, progress: progress, dependencies: dependencies)
      try progress.advance(.restorationComplete)
      return result(progress: progress, noOp: noOp, normalBootVerified: normalBootVerified)
    } catch {
      let primary = error
      if let preparation = error as? OwnerPreparationFailure {
        PommeProgressContext.sink?.warning("Owner preparation failed; VM state and journal retained without failure restoration or retry.")
        dependencies.log("Owner preparation failed at \(progress.journal.phase.rawValue); VM state and journal retained without failure restoration or retry.")
        throw preparation.underlying
      }
      // A failed Recovery cleanup barrier is not permission to boot.
      if (error as? PommeRecoverySessionError) == .cleanupFailed
        || (error as? PommeLiveRecoveryIntegration.Error) == .cleanupFailed
        || (error as? PommeSecurityWorkflowError) == .restorationIncomplete
      {
        throw PommeSecurityWorkflowError.restorationIncomplete
      }
      PommeProgressContext.sink?.warning("Security progress was retained; restoring the VM run state after failure.")
      dependencies.log("Security progress was retained; restoring the VM run state after failure.")
      do { try await dependencies.restore(progress.journal.originalRunState) } catch {
        throw PommeSecurityWorkflowError.restorationIncomplete
      }
      throw primary
    }
  }

  static func resumeRetainedAMFINormalCheckpoint(
    progress: PommeSecurityWorkflowProgress,
    dependencies: PommeSecurityWorkflowDependencies
  ) async throws -> JSONValue {
    guard canResumeRetainedAMFINormalCheckpoint(progress.journal) else {
      throw PommeSecurityWorkflowError.incompleteTransaction
    }
    let target = progress.journal.originalRunState.resolving(progress.journal.requestedFinalState)
    do {
      dependencies.log("Reconciling the retained normal AMFI checkpoint after Recovery inspection.")
      try await recoverConfiguredAMFIDisable(
        progress: progress, dependencies: dependencies)
      dependencies.log("Verifying configuration after a normal boot.")
      try await verifyNormalBootWithProgress(progress: progress, dependencies: dependencies)
      try progress.advance(.normalBootVerified)
      try progress.advance(.restorationPending)
      dependencies.log("Restoring the requested VM run state.")
      try await restoreWithProgress(target, progress: progress, dependencies: dependencies)
      try progress.advance(.restorationComplete)
      return result(progress: progress, noOp: false, normalBootVerified: true)
    } catch {
      let primary = error
      if let preparation = error as? OwnerPreparationFailure {
        PommeProgressContext.sink?.warning("Owner preparation failed; VM state and journal retained without failure restoration or retry.")
        dependencies.log("Owner preparation failed at \(progress.journal.phase.rawValue); VM state and journal retained without failure restoration or retry.")
        throw preparation.underlying
      }
      // A failed Recovery cleanup barrier is not permission to boot.
      if (error as? PommeRecoverySessionError) == .cleanupFailed
        || (error as? PommeLiveRecoveryIntegration.Error) == .cleanupFailed
        || (error as? PommeSecurityWorkflowError) == .restorationIncomplete
      {
        throw PommeSecurityWorkflowError.restorationIncomplete
      }
      PommeProgressContext.sink?.warning("Security progress was retained; restoring the VM run state after failure.")
      dependencies.log("Security progress was retained; restoring the VM run state after failure.")
      do { try await dependencies.restore(progress.journal.originalRunState) } catch {
        throw PommeSecurityWorkflowError.restorationIncomplete
      }
      throw primary
    }
  }

  private struct OwnerPreparationFailure: Error {
    let underlying: any Error
  }

  private static func prepareOwnerPreservingFailure(
    progress: PommeSecurityWorkflowProgress, dependencies: PommeSecurityWorkflowDependencies
  ) async throws -> PommeGuestSecurityCredentials {
    PommeProgressContext.sink?.step(vm: progress.journal.identity.vmName, "Preparing volume owner")
    do { return try await dependencies.prepareOwner(progress) }
    catch { throw OwnerPreparationFailure(underlying: error) }
  }

  private static func recoverConfiguredAMFIDisable(
    progress: PommeSecurityWorkflowProgress,
    dependencies: PommeSecurityWorkflowDependencies
  ) async throws {
    guard let recoverConfiguredAMFI = dependencies.recoverConfiguredAMFI else {
      throw PommeSecurityWorkflowError.incompleteTransaction
    }
    let credentials = try await prepareOwnerPreservingFailure(progress: progress, dependencies: dependencies)
    PommeProgressContext.sink?.step(vm: progress.journal.identity.vmName, "Reconciling AMFI configuration")
    let output = try await recoverConfiguredAMFI(credentials)
    guard output.objectValue?["verified"] == .bool(true),
          output.objectValue?["amfiDisabled"] == .bool(true) else {
      throw PommeSecurityWorkflowError.statusUnverified
    }
    if progress.journal.phase == .securityMutationIntent {
      try progress.advance(.securityMutationVerified)
    }
  }

  private static func verifyNormalBootWithProgress(
    progress: PommeSecurityWorkflowProgress, dependencies: PommeSecurityWorkflowDependencies
  ) async throws {
    PommeProgressContext.sink?.step(vm: progress.journal.identity.vmName, "Verifying security after normal boot")
    try await dependencies.verifyNormalBoot()
  }

  private static func restoreWithProgress(
    _ target: VMRunStateSnapshot, progress: PommeSecurityWorkflowProgress,
    dependencies: PommeSecurityWorkflowDependencies
  ) async throws {
    PommeProgressContext.sink?.step(vm: progress.journal.identity.vmName, "Restoring VM state")
    try await dependencies.restore(target)
  }

  private static func result(
    progress: PommeSecurityWorkflowProgress, noOp: Bool, normalBootVerified: Bool
  ) -> JSONValue {
    let journal = progress.journal
    let setting = journal.operation.isSIP ? "SIP" : "AMFI override"
    let configured =
      journal.operation.requestsDisabled
      ? (journal.operation.isSIP ? "disabled" : "enabled")
      : (journal.operation.isSIP ? "enabled" : "removed")
    var description = "\(setting) configured: \(configured)."
    if noOp { description += " Already in the requested state." }
    if normalBootVerified { description += " Verified after a normal boot." }
    if !journal.operation.isSIP { description += " Live AMFI enforcement was not tested." }
    return .object([
      "ok": .bool(true), "name": .string(journal.identity.vmName),
      "operation": .string(journal.operation.wireName), "noOp": .bool(noOp),
      "output": .string(description),
      "configured": .bool(true), "configuredDisabled": .bool(journal.operation.requestsDisabled),
      "normalBootVerified": .bool(normalBootVerified),
      "runtimeConfigurationVerified": .bool(normalBootVerified),
      "enforcementVerified": .bool(journal.operation.isSIP && normalBootVerified),
      "finalState": .string(
        finalStateName(journal.originalRunState.resolving(journal.requestedFinalState))),
      "finalStateVerified": .bool(true), "hostExitCode": .integer(0),
    ])
  }

  private static func finalStateName(_ state: VMRunStateSnapshot) -> String {
    switch state {
    case .stopped: "stopped"
    case .running(let mode): mode.rawValue
    case .paused: "paused"
    }
  }
}
