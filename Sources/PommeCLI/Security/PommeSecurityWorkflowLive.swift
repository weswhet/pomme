import Foundation

/// The boot identity this process proved after its most recent native reboot
/// following an AMFI NVRAM write. Normal-boot verification may run on that
/// boot instead of rebooting it a second time.
actor PommeSecurityProvenBootRecord {
  private var identity: String?
  var provenIdentity: String? { identity }
  func record(_ identity: String) { self.identity = identity }
}

extension PommeSecurityWorkflow {
  /// A fresh owner credential is returned to the security mutation only after
  /// the current normal boot proves that the owner still has an Aqua desktop.
  /// The autologin receipt is durable, but the desktop can regress before a
  /// later retry reaches the security mutation intent.
  static func freshOwnerDesktopProofRequired(
    for phase: PommeSecurityWorkflowPhase
  ) -> Bool {
    switch phase {
    case .autologinVerified, .securityMutationIntent:
      return true
    default:
      return false
    }
  }

  /// AMFI verification must observe a boot that started after the last NVRAM
  /// write. A VM that this verification itself started from a non-running
  /// state is such a boot, and so is the boot this process already proved
  /// after its NVRAM reboot. Any other running boot is rebooted first, so a
  /// retry in a new process still verifies a fresh boot.
  static func amfiVerificationRequiresReboot(
    startedFreshBoot: Bool,
    currentBootIdentity: String?,
    provenBootIdentity: String?
  ) -> Bool {
    if startedFreshBoot { return false }
    guard let currentBootIdentity, let provenBootIdentity else { return true }
    return currentBootIdentity != provenBootIdentity
  }

  static func runLive(
    reference: VMReference,
    operation: PommeSecurityWorkflowOperation,
    finalState: VMFinalState,
    force: Bool,
    lease: VMBundleMutationLease,
    recoveryFactory: PommeRecoveryIntegrationFactory
  ) async throws -> JSONValue {
    // Capture this before even the read-only Recovery inspection boots.
    let original = try PommeCore.stableVMRunState(reference: reference)
    let plan = try PommeCore.securityProvisioningPlan(reference: reference)
    try PommeRecoverySecurityQualification.require(
      profile: try PommeCore.recoveryProfileEvidence(for: plan)
    )
    let runtimeMetadata = try PommeCore.provisioningRuntimeMetadata(for: plan)
    guard let group = runtimeMetadata.startupVolumeGroupUUID else {
      throw PommeSecurityWorkflowJournalError.invalidIdentity
    }
    let identity = try PommeSecurityWorkflowIdentity.capture(
      vmName: reference.displayName, bundle: reference.bundle,
      startupVolumeGroupUUID: group, immutableProvisioningPlanDigest: plan.digest
    )
    let store = PommeSecurityWorkflowJournalStore(bundleURL: reference.bundle.rootURL)
    let recovery = PommeSecurityRecoveryAdapter(
      reference: reference, volumeGroupUUID: group, factory: recoveryFactory)
    func resumeGuided(_ error: Error) -> Error {
      guard let retained = PommeSecurityWorkflowResumeGuidance.latestTrustedRetainedJournal(
        store: store, identity: identity, lease: lease
      ) else {
        return error
      }
      return PommeSecurityWorkflowResumeGuidance.appendingGuidance(
        to: error, journal: retained)
    }
    // Journal the original state before even a read-only Recovery boot.
    // A rejected prerequisite is terminal only after restoration is proven;
    // it never becomes a receipt for the requested security configuration.
    let retained = try store.loadIfPresent(lease: lease)
    let journal: PommeSecurityWorkflowJournal
    do {
      journal = try store.begin(
        operation: operation, identity: identity,
        originalRunState: original, requestedFinalState: finalState,
        lease: lease, preflight: !operation.isSIP)
    } catch {
      guard let journalError = error as? PommeSecurityWorkflowJournalError,
        journalError == .conflictingOperation || journalError == .immutableRequestMismatch,
        let retained = PommeSecurityWorkflowResumeGuidance.latestTrustedRetainedJournal(
          store: store, identity: identity, lease: lease
        )
      else {
        throw error
      }
      throw PommeSecurityWorkflowResumeGuidance.appendingGuidance(
        to: error, journal: retained)
    }
    let progress = PommeSecurityWorkflowProgress(journal, store: store, lease: lease)
    let normal = PommeSecurityNormalAgent(
      reference: reference, expectedExecutableDigest: plan.normalAgent.executableDigest)
    // SIP is read from the effective state of the current normal boot. This is
    // the same `csrutil status` read that proves every SIP workflow after its
    // final normal boot and the state that governs AMFI's normal-boot NVRAM
    // writes. It needs no owner credentials and no Recovery session; the
    // normal boot it may perform is the one owner preparation needs anyway.
    let observeNormalSIPDisabled: @Sendable () async throws -> Bool = {
      PommeCore.log(
        "Reading the effective SIP state through the persistent normal agent.",
        vmName: reference.displayName)
      try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
      try await normal.authenticate()
      return try normal.observeSIPDisabled()
    }
    // AMFI state is fully observable from a normal boot: the policy, the
    // NVRAM projection, and the retained transaction all live where the
    // persistent agent can read them. Prefer that over spending a Recovery
    // session, and fall back to Recovery whenever the pinned agent predates
    // the contract or the read cannot be completed there.
    let observeAMFI: @Sendable () async throws -> PommeSecurityWorkflowState = {
        if try PommeCore.stableVMRunState(reference: reference) == .running(.normal),
          (try? await normal.authenticate()) != nil,
          let state = normal.observeAMFIState(volumeGroupUUID: group)
        {
            PommeCore.log(
                "Read the AMFI configuration through the persistent normal agent.",
                vmName: reference.displayName)
            return state
        }
        return try await recovery.observe(operation)
    }
    let provenBoot = PommeSecurityProvenBootRecord()
    let initialAMFIObservation: PommeSecurityAMFIPreflightObservation?
    if operation.isSIP {
      initialAMFIObservation = nil
    } else {
      do {
        if retained?.phase == .preflightIntent {
          try await PommeCore.restoreStableVMRunState(journal.originalRunState, reference: reference)
          guard try PommeCore.provesStableVMRunState(journal.originalRunState, reference: reference) else {
            throw PommeSecurityWorkflowError.restorationIncomplete
          }
        }
        initialAMFIObservation = try await PommeSecurityAMFIPreflight.inspectRetained(
          journal: progress.journal,
          observeAMFI: { try await observeAMFI() },
          requireSIPDisabled: {
            guard try await observeNormalSIPDisabled() else {
              throw PommeSecurityWorkflowError.amfiRequiresSIPDisabled
            }
          })
        if progress.journal.phase == .preflightIntent {
          try progress.advance(.credentialPending)
        }
      } catch {
        let primary = error
        // A failed temporary-session cleanup is a barrier to another boot.
        if (error as? PommeRecoverySessionError) == .cleanupFailed
          || (error as? PommeLiveRecoveryIntegration.Error) == .cleanupFailed
          || (error as? PommeSecurityWorkflowError) == .restorationIncomplete {
          throw resumeGuided(PommeSecurityWorkflowError.restorationIncomplete)
        }
        do {
          try await PommeCore.restoreStableVMRunState(journal.originalRunState, reference: reference)
          guard try PommeCore.provesStableVMRunState(journal.originalRunState, reference: reference) else {
            throw PommeSecurityWorkflowError.restorationIncomplete
          }
          if progress.journal.phase == .preflightIntent {
            try progress.advance(.preflightRejected)
          }
        } catch { throw resumeGuided(PommeSecurityWorkflowError.restorationIncomplete) }
        throw resumeGuided(primary)
      }
    }
    let owner = PommeSecurityLiveOwnerPreparation(
      reference: reference, normal: normal, force: force)
    let changeNormalBootArguments: @Sendable () async throws -> JSONValue = {
      PommeCore.log(
        "Booting normal macOS for the journaled AMFI boot-argument change.",
        vmName: reference.displayName)
      try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
      try await normal.authenticate()
      try normal.requireAMFIWorkflowSupport()
      _ = try normal.currentBootIdentity()
      PommeProgressContext.sink?.step(vm: reference.displayName,
        operation.requestsDisabled ? "Writing AMFI boot arguments" : "Removing AMFI boot arguments")
      let result = try normal.performAMFI(
        operation: operation.requestsDisabled ? "amfi.normal.disable" : "amfi.normal.enable",
        volumeGroupUUID: group)
      PommeProgressContext.sink?.step(vm: reference.displayName, "Restarting macOS")
      // Native reboot commits the guest's firmware state before another host
      // lifecycle transition, including enable's subsequent Recovery stage.
      // The rebooted session is remembered so verification can run on it.
      await provenBoot.record(try await normal.rebootAndAuthenticate())
      return result
    }
    // `csrutil clear` is the one SIP change macOS allows outside Recovery: it
    // restores the default protection once a volume owner authenticates, and
    // it takes effect on the next boot. Enabling SIP therefore needs no
    // Recovery session when the pinned agent can run it. A native reboot
    // commits the new LocalPolicy, as it does for AMFI's NVRAM stage, and the
    // proven boot is the one verification reads. Nil means the pinned agent
    // predates the operation and the caller must use Recovery.
    let clearSIPInNormalBoot: @Sendable (PommeGuestSecurityCredentials) async throws -> JSONValue? = {
      credentials in
      try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
      try await normal.authenticate()
      guard try normal.supportsNormalSIPClear() else {
        PommeCore.log(
          "The pinned agent predates normal-boot csrutil clear; enabling SIP in authenticated Recovery.",
          vmName: reference.displayName)
        return nil
      }
      PommeCore.log(
        "Clearing the SIP configuration in normal macOS as the volume owner.",
        vmName: reference.displayName)
      try normal.clearSIPConfiguration(credentials: credentials, volumeGroupUUID: group)
      PommeProgressContext.sink?.step(vm: reference.displayName, "Restarting macOS")
      await provenBoot.record(try await normal.rebootAndAuthenticate())
      // The native receipt is for the cleared configuration. The proven boot
      // is the first that can report it, and verification reads it there.
      return .object([
        "operation": .string(operation.wireName), "sipDisabled": .bool(false),
        "verified": .bool(true),
      ])
    }
    let dependencies = PommeSecurityWorkflowDependencies(
      observe: {
        // Framework owners must still prove their saved identity and desktop
        // when SIP already matches, before the engine can issue a no-op receipt.
        if operation.isSIP {
          _ = try await owner.prepareFrameworkOwnerIfPresent(progress: progress, advance: false)
        }
        switch initialAMFIObservation {
        case .state(let state)?: return state
        case .retainedNormalCheckpoint?:
          // This outcome has no observed phase to synthesize. Only the
          // separately guarded retained-checkpoint entry point may use it.
          throw PommeSecurityWorkflowError.incompleteTransaction
        case nil:
          guard operation.isSIP else { return try await observeAMFI() }
          return .init(
            disabled: try await observeNormalSIPDisabled(),
            baselinePresent: false, reconciliationRequired: false, baselinePhase: nil)
        }
      },
      prepareOwner: { try await owner.prepare(progress: $0) },
      mutate: { credentials in
        if operation.isSIP {
          if operation == .sipEnable, let cleared = try await clearSIPInNormalBoot(credentials) {
            return cleared
          }
          PommeCore.log(
            "Applying the requested SIP change in authenticated Recovery.",
            vmName: reference.displayName)
          return try await recovery.mutate(operation, credentials: credentials)
        }
        try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
        try await normal.authenticate()
        try normal.requireAMFIWorkflowSupport()
        _ = try normal.currentBootIdentity()
        return try await PommeSecurityAMFIStages(
          operation: operation,
          changePolicy: { try await recovery.mutate(operation, credentials: $0) },
          changeBootArguments: changeNormalBootArguments
        ).mutate(credentials: credentials)
      },
      verifyNormalBoot: {
        if operation.isSIP {
          // A normal-boot clear already rebooted natively and proved the new
          // boot in this process, so verify on it. Any other boot, such as
          // one after Recovery or a retry in a new process, is replaced by a
          // fresh normal boot first.
          if let proven = await provenBoot.provenIdentity,
            try PommeCore.stableVMRunState(reference: reference) == .running(.normal)
          {
            try await normal.authenticate()
            if try normal.currentBootIdentity() == proven {
              try normal.verifyNormalSecurity(sip: true, disabled: operation.requestsDisabled)
              return
            }
          }
          try await PommeCore.restoreStableVMRunState(.stopped, reference: reference)
          try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
          try await normal.authenticate()
          try normal.verifyNormalSecurity(sip: true, disabled: operation.requestsDisabled)
        } else {
          let observed = try PommeCore.stableVMRunState(reference: reference)
          try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
          try await normal.authenticate()
          let current = try normal.currentBootIdentity()
          if PommeSecurityWorkflow.amfiVerificationRequiresReboot(
            startedFreshBoot: observed != .running(.normal),
            currentBootIdentity: current,
            provenBootIdentity: await provenBoot.provenIdentity)
          {
            PommeCore.log(
              "Rebooting normal macOS to verify the AMFI configuration on a fresh boot.",
              vmName: reference.displayName)
            PommeProgressContext.sink?.step(vm: reference.displayName, "Restarting macOS")
            try await normal.rebootAndAuthenticate()
          } else {
            PommeCore.log(
              "Verifying the AMFI configuration on the fresh normal boot.",
              vmName: reference.displayName)
          }
          _ = try normal.performAMFI(
            operation: operation.requestsDisabled
              ? "amfi.normal.verifyDisabled" : "amfi.normal.verifyEnabled",
            volumeGroupUUID: group)
        }
      },
      restore: { state in
        try await PommeCore.restoreStableVMRunState(state, reference: reference)
        guard try PommeCore.provesStableVMRunState(state, reference: reference) else {
          throw PommeSecurityWorkflowError.restorationIncomplete
        }
      },
      log: { PommeCore.log($0, vmName: reference.displayName) },
      recoverConfiguredAMFI: { _ in
        guard operation == .amfiDisable else {
          throw PommeSecurityWorkflowError.incompleteTransaction
        }
        // The pinned guest independently proves the exact owned policy and
        // checkpoint before/target before publishing a new NVRAM intent.
        return try await changeNormalBootArguments()
      }
    )
    do {
      if case .retainedNormalCheckpoint? = initialAMFIObservation {
        return try await resumeRetainedAMFINormalCheckpoint(
          progress: progress, dependencies: dependencies)
      }
      return try await run(progress: progress, dependencies: dependencies)
    } catch {
      throw resumeGuided(error)
    }
  }
}

/// Every stage runs once per explicitly requested attempt. A failure preserves
/// the phase at the caller and never triggers a reboot or a second preference write.
/// The Buddy preference stages are advisory: their failure is logged and skipped.
struct PommeSecurityFreshOwnerLoginSequence: Sendable {
  let verifyPreferencesCapability: @Sendable () async throws -> Void
  let configureLoginAndMarkers: @Sendable () async throws -> Void
  let verifyOwnerPreferences: @Sendable () async throws -> Void
  let restartAndAuthenticate: @Sendable () async throws -> Void
  let verifyOwnerConsole: @Sendable () async throws -> Void
  let completeOwnerPreferences: @Sendable () async throws -> Void
  let verifyDesktop: @Sendable () async throws -> Void
  var log: @Sendable (String) -> Void = { _ in }

  func run() async throws {
    let stages: [(String, Bool, @Sendable () async throws -> Void)] = [
      ("agent-preference-capability", true, verifyPreferencesCapability),
      ("autologin-and-system-markers", false, configureLoginAndMarkers),
      ("normal-reboot-and-authentication", false, restartAndAuthenticate),
      ("owner-console-proof", false, verifyOwnerConsole),
      ("owner-agent-preference-receipt", true, verifyOwnerPreferences),
      ("owner-revalidation-and-preference-receipt", true, completeOwnerPreferences),
      ("full-desktop-proof", false, verifyDesktop)
    ]
    for (stage, advisory, perform) in stages {
      log("Fresh-owner stage started: \(stage).")
      if advisory {
        try await PommeBuddyPreferencesGate.failOpen(stage, log: log) { try await perform() }
        continue
      }
      do { try await perform() } catch {
        log("Fresh-owner stage failed: \(stage). State retained; no automatic retry or failure restart.")
        throw error
      }
      log("Fresh-owner stage verified: \(stage).")
    }
  }
}

/// The framework path has one credential source and no account/login mutation
/// callbacks. A failed exact read or native proof cannot enter legacy resolution.
struct PommeSecurityFrameworkOwnerPreparation: Sendable {
  let credentialReference: PommeOwnerCredentialReference
  let generatedUID: UUID
  let startupVolumeGroupUUID: UUID
  let readCredential: @Sendable (PommeOwnerCredentialReference) throws -> PommeOwnerCredential
  let verifyOwner: @Sendable (String, UUID) async throws -> PommeSecurityFrameworkOwnerVerification
  let verifyDesktop: @Sendable (String, UInt32) async throws -> Void

  func prepare(progress: PommeSecurityWorkflowProgress, advance: Bool = true) async throws
    -> PommeGuestSecurityCredentials
  {
    guard credentialReference.account == "pomme",
      credentialReference.matches(progress.journal.identity),
      credentialReference.generatedUID == nil || credentialReference.generatedUID == generatedUID,
      startupVolumeGroupUUID == progress.journal.identity.startupVolumeGroupUUID
    else { throw PommeSecurityWorkflowJournalError.identityMismatch }
    try progress.update {
      try progress.store.recordOwnerIntent(
        $0, accountUsername: credentialReference.account,
        ownerPreparation: .existing, lease: progress.lease)
    }
    try progress.update {
      try progress.store.setCredential($0, credential: credentialReference, lease: progress.lease)
    }
    let credential = try readCredential(credentialReference)
    guard credential.reference == credentialReference else {
      throw PommeOwnerCredentialStoreError.invalidReference
    }
    let proof = try await verifyOwner(credential.password, generatedUID)
    let owner = proof.owner
    guard owner.username == credentialReference.account, owner.generatedUID == generatedUID,
      owner.startupVolumeGroupUUID == startupVolumeGroupUUID,
      owner.passwordVerified, owner.isAdministrator, owner.secureTokenEnabled,
      owner.isAPFSVolumeOwner, owner.uniqueID >= 501,
      proof.automaticLoginVerified, proof.consoleUserVerified
    else { throw PommeSecurityOwnerPreparationError.ownerVerificationFailed }
    try await verifyDesktop(owner.username, owner.uniqueID)
    try progress.update {
      try progress.store.bind(
        $0, volumeVUID: proof.startupRootVolumeUUID.uuidString.lowercased(), lease: progress.lease)
    }
    try progress.update {
      try progress.store.recordOwnerVerified($0, generatedUID: owner.generatedUID, lease: progress.lease)
    }
    if advance && [.credentialPending, .credentialStored].contains(progress.journal.phase) {
      try progress.advance(.accountCreationVerified)
    }
    return try .init(username: owner.username, password: credential.password)
  }
}

/// Coordinates durable owner intent with native guest checks. Only the fresh
/// branch is allowed to create an account or alter automatic login.
struct PommeSecurityLiveOwnerPreparation: Sendable {
  let reference: VMReference
  let normal: PommeSecurityNormalAgent
  let force: Bool
  let labStrategy: PommeAutologinComparisonStrategy?
  private let credentials = PommeOwnerCredentialStore()
  private let interaction = PommeSecurityOwnerInteraction()

  init(reference: VMReference, normal: PommeSecurityNormalAgent, force: Bool,
       labStrategy: PommeAutologinComparisonStrategy? = nil) {
    self.reference = reference
    self.normal = normal
    self.force = force
    self.labStrategy = labStrategy
  }

  func prepare(progress: PommeSecurityWorkflowProgress) async throws
    -> PommeGuestSecurityCredentials
  {
    if let framework = try await prepareFrameworkOwnerIfPresent(progress: progress) {
      return framework
    }
    PommeCore.log(
      "Authenticating the persistent normal agent for owner preparation.",
      vmName: reference.displayName)
    try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
    try await normal.authenticate(requirePrivateInput: true)
    let metadata = try metadataPayload(bundle: reference.bundle)
    let legacyAccount = metadata[Constants.guestKCPasswordUserMetadataKey] as? String
    let initial = progress.journal
    let helper = preparation(
      username: initial.owner?.accountUsername ?? "pomme", progress: progress,
      priorProvisioningAbsent: (initial.owner == nil || initial.owner?.ownerPreparation == .new)
        && legacyAccount == nil)
    PommeCore.log(
      "Inspecting Setup Assistant, local accounts, and startup-volume ownership.",
      vmName: reference.displayName)
    let probe = try helper.probe()
    if labStrategy != nil, !probe.freshness.isVerifiedFresh {
      throw RunnerError.hostCommandFailed("Autologin comparison refused: the normal agent did not prove a fresh ownerless guest. No owner mutation was attempted.")
    }
    try progress.update {
      try progress.store.bind(
        $0, volumeVUID: probe.evidence.startupIdentity.rootVolumeUUID.uuidString.lowercased(),
        lease: progress.lease)
    }

    if initial.owner?.ownerPreparation == .new
      || (initial.owner == nil && probe.freshness.isVerifiedFresh)
    {
      return try await prepareFresh(progress: progress, helper: helper, probe: probe)
    }

    let authorization: PommeGuestSecurityCredentials
    var offerSave = false
    var adoptRecovered = false
    if let environment = try PommeSecurityOwnerInteraction.environmentOwner(
      ProcessInfo.processInfo.environment)
    {
      authorization = environment
    } else if let saved = progress.journal.credential {
      let value = try credentials.read(saved)
      authorization = try .init(username: saved.account, password: value.password)
    } else if let username = initial.owner?.accountUsername ?? legacyAccount,
      let password = try credentials.readExistingOwnerCredential(
        identity: progress.journal.identity, account: username)
    {
      authorization = try .init(username: username, password: password)
    } else if let recovered = recoverOwnerCredentialFromGuest(
      expecting: initial.owner?.accountUsername ?? legacyAccount)
    {
      authorization = recovered
      adoptRecovered = true
    } else {
      authorization = try interaction.existingOwner(vmName: reference.displayName)
      offerSave = true
    }
    if let owner = progress.journal.owner, owner.accountUsername != authorization.username {
      throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
    }
    try progress.update {
      try progress.store.recordOwnerIntent(
        $0, accountUsername: authorization.username,
        ownerPreparation: .existing, lease: progress.lease)
    }
    let existing = preparation(
      username: authorization.username, progress: progress, priorProvisioningAbsent: false)
    PommeProgressContext.sink?.step(vm: reference.displayName, "Verifying volume owner")
    let verified = try await existing.verifyOwner(password: authorization.password)
    try recordVerification(verified, progress: progress)
    // A recovered credential is Pomme's own generated secret, already proven
    // by the verification above, so it is adopted for this VM's identity
    // without a prompt. A credential typed by the user is still only stored
    // when they say so.
    if adoptRecovered || (offerSave && interaction.shouldSaveOwner(vmName: reference.displayName)) {
      // Reference intent is durable before the Keychain write. A failed
      // save does not change the existing user's password or login.
      let pointer = try PommeOwnerCredentialReference(
        identity: progress.journal.identity,
        account: authorization.username, generatedUID: verified.generatedUID)
      try progress.update {
        try progress.store.setCredential($0, credential: pointer, lease: progress.lease)
      }
      _ = try credentials.store(.init(reference: pointer, password: authorization.password))
    }
    if [.credentialPending, .credentialStored].contains(progress.journal.phase) {
      try progress.advance(.accountCreationVerified)
    }
    return authorization
  }

  func prepareFrameworkOwnerIfPresent(
    progress: PommeSecurityWorkflowProgress, advance: Bool = true
  ) async throws -> PommeGuestSecurityCredentials? {
    guard let context = try PommeCore.frameworkProvisionedOwner(reference: reference) else {
      return nil
    }
    try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
    try await normal.authenticate(requirePrivateInput: true)
    let helper = preparation(username: "pomme", progress: progress, priorProvisioningAbsent: false)
    return try await PommeSecurityFrameworkOwnerPreparation(
      credentialReference: context.credentialReference,
      generatedUID: context.generatedUID,
      startupVolumeGroupUUID: context.startupVolumeGroupUUID,
      readCredential: { try credentials.read($0) },
      verifyOwner: { password, expectedUID in
        try await helper.verifyFrameworkProvisionedOwner(
          password: password, expectedGeneratedUID: expectedUID)
      },
      verifyDesktop: { username, uniqueID in
        try await normal.verifyConsoleLogin(username: username, uniqueID: uniqueID)
      }
    ).prepare(progress: progress, advance: advance)
  }

  private func prepareFresh(
    progress: PommeSecurityWorkflowProgress,
    helper: PommeSecurityOwnerPreparation,
    probe: PommeSecurityOwnerProbe
  ) async throws -> PommeGuestSecurityCredentials {
    let account = helper.identity.username
    guard account == PommeSecurityOwnerIdentity.pomme.username,
      progress.journal.owner?.accountUsername == nil
        || progress.journal.owner?.accountUsername == account
    else {
      throw PommeSecurityWorkflowJournalError.immutableRequestMismatch
    }
    if progress.journal.owner == nil {
      try interaction.authorizeFreshOwner(vmName: reference.displayName, force: force)
      try progress.update {
        try progress.store.recordOwnerIntent(
          $0, accountUsername: account, ownerPreparation: .new, lease: progress.lease)
      }
    }
    let credential: PommeOwnerCredential
    if let saved = progress.journal.credential {
      // Missing credentials after any creation intent are never replaced.
      do { credential = try credentials.read(saved) } catch PommeOwnerCredentialStoreError
        .keychainMissing
        where progress.journal.phase == .credentialPending && probe.freshness.isVerifiedFresh
      {
        let intent = try credentials.prepare(identity: progress.journal.identity, account: account)
        guard intent.reference == saved else {
          throw PommeOwnerCredentialStoreError.invalidReference
        }
        credential = try credentials.store(intent)
      }
    } else {
      guard progress.journal.phase == .credentialPending, probe.freshness.isVerifiedFresh else {
        throw PommeOwnerCredentialStoreError.keychainMissing
      }
      let intent = try credentials.prepare(identity: progress.journal.identity, account: account)
      try progress.update {
        try progress.store.setCredential($0, credential: intent.reference, lease: progress.lease)
      }
      credential = try credentials.store(intent)
    }
    if progress.journal.phase == .credentialPending { try progress.advance(.credentialStored) }
    let hadCreationIntent = progress.journal.phase != .credentialStored
    if progress.journal.phase == .credentialStored { try progress.advance(.accountCreationIntent) }
    let verified: PommeSecurityOwnerVerification
    if progress.journal.phase == .accountCreationIntent {
      PommeCore.log(
        "Preparing and verifying owner \(account) through the persistent agent.",
        vmName: reference.displayName)
      PommeProgressContext.sink?.step(vm: reference.displayName, "Creating volume owner")
      verified = try await helper.createOwner(
        password: credential.password, probe: probe, retryIntent: hadCreationIntent)
      try recordVerification(verified, progress: progress)
      try progress.advance(.accountCreationVerified)
    } else {
      verified = try await helper.verifyOwner(password: credential.password)
      try recordVerification(verified, progress: progress)
    }
    if progress.journal.phase == .accountCreationVerified { try progress.advance(.autologinIntent) }
    if progress.journal.phase == .autologinIntent {
      PommeCore.log(
        "Configuring persistent automatic login for verified owner \(account).",
        vmName: reference.displayName)
      if labStrategy == nil {
        try await PommeSecurityFreshOwnerLoginSequence(
          verifyPreferencesCapability: {
            _ = try normal.buddyPreferencesStatus()
          },
          configureLoginAndMarkers: {
            _ = try await helper.configureLogin(password: credential.password, deferOwnerPreferences: true)
          },
          verifyOwnerPreferences: {
            _ = try await helper.waitForBuddyPreferences(expected: verified)
          },
          restartAndAuthenticate: {
            try await PommeCore.restoreStableVMRunState(.stopped, reference: reference)
            try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
            try await normal.authenticate()
          },
          verifyOwnerConsole: {
            try await normal.verifyOwnerConsole(username: verified.username, uniqueID: verified.uniqueID)
          },
          completeOwnerPreferences: {
            try await helper.completeFreshOwnerAfterLogin(password: credential.password, expected: verified)
          },
          verifyDesktop: {
            PommeProgressContext.sink?.step(vm: reference.displayName, "Verifying owner login")
            try await normal.verifyConsoleLogin(username: verified.username, uniqueID: verified.uniqueID)
          },
          log: { PommeCore.log($0, vmName: reference.displayName) }
        ).run()
        try progress.advance(.autologinVerified)
        return try .init(username: credential.reference.account, password: credential.password)
      }
      if let labStrategy {
        try await PommeBuddyPreferencesGate.failOpen("capability check", log: { PommeCore.log($0, vmName: reference.displayName) }) {
          _ = try normal.buddyPreferencesStatus()
        }
        let setter: (@Sendable (String) async throws -> Void)?
        if labStrategy == .legacy {
          setter = { @Sendable password in
            try PommeAutologinComparison.setLegacy(reference: reference, password: password)
          }
        } else {
          setter = nil
        }
        if labStrategy == .markerfirst {
          PommeCore.log("Marker-first lab: agent capability verified; configuring native autologin and Setup Assistant markers.", vmName: reference.displayName)
        }
        _ = try await helper.configureLogin(
          password: credential.password, labSetter: setter,
          deferOwnerPreferences: labStrategy == .markerfirst)
      }
      PommeCore.log(
        "Restarting normally to verify automatic login as \(account).",
        vmName: reference.displayName)
      try await PommeCore.restoreStableVMRunState(.stopped, reference: reference)
      try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
      try await normal.authenticate()
      try await normal.verifyOwnerConsole(username: verified.username, uniqueID: verified.uniqueID)
      try await PommeBuddyPreferencesGate.failOpen("receipt", log: { PommeCore.log($0, vmName: reference.displayName) }) {
        _ = try await helper.waitForBuddyPreferences(expected: verified)
      }
      if labStrategy == .markerfirst {
        PommeCore.log("Marker-first lab: reboot and agent preferences verified; checking the owner console.", vmName: reference.displayName)
        try await PommeAutologinComparison.verifyOwnerConsole(
          normal: normal, username: verified.username, uniqueID: verified.uniqueID)
        try PommeAutologinComparison.recordMarkerReady(
          reference: reference, progress: progress, uniqueID: verified.uniqueID)
        return try .init(username: credential.reference.account, password: credential.password)
      }
      PommeCore.log(
        "Checking the console user and login session for \(account).",
        vmName: reference.displayName)
      PommeProgressContext.sink?.step(vm: reference.displayName, "Verifying owner login")
      try await normal.verifyConsoleLogin(username: verified.username, uniqueID: verified.uniqueID)
      try progress.advance(.autologinVerified)
    } else if PommeSecurityWorkflow.freshOwnerDesktopProofRequired(
      for: progress.journal.phase
    ) {
      // A durable autologin receipt records what a previous attempt proved;
      // it does not prove that the normal desktop still exists after a later
      // crash or manual change. Recheck it before returning credentials to
      // the security mutation, without repeating account or autologin effects.
      PommeCore.log(
        "Revalidating the normal desktop for owner \(account) before security mutation.",
        vmName: reference.displayName)
      try await normal.verifyOwnerConsole(username: verified.username, uniqueID: verified.uniqueID)
      try await PommeBuddyPreferencesGate.failOpen("receipt", log: { PommeCore.log($0, vmName: reference.displayName) }) {
        _ = try await helper.waitForBuddyPreferences(expected: verified)
      }
      PommeProgressContext.sink?.step(vm: reference.displayName, "Verifying owner login")
      try await normal.verifyConsoleLogin(username: verified.username, uniqueID: verified.uniqueID)
    }
    return try .init(username: credential.reference.account, password: credential.password)
  }

  /// A VM cloned from a provisioned template carries the owner account but no
  /// host Keychain item, because that item is scoped to the UUID of the VM the
  /// template was captured from. Ask the root agent for the automatic-login
  /// credential Pomme itself configured instead of prompting for a password
  /// nobody was ever told. The result is only a candidate: the ordinary owner
  /// verification below still has to prove the account, its administrator
  /// membership, Secure Token, and APFS ownership before it is recorded.
  ///
  /// An older pinned agent that does not advertise the contract, or a guest
  /// with no automatic-login artifact, simply yields nil and the caller falls
  /// back to its existing resolution.
  private func recoverOwnerCredentialFromGuest(
    expecting account: String?
  ) -> PommeGuestSecurityCredentials? {
    guard normal.supportsOwnerCredentialRecovery(),
      let recovered = try? normal.recoverOwnerCredential(account: account)
    else { return nil }
    PommeCore.log(
      "Recovered owner \(recovered.username)'s credential from the guest's automatic-login configuration.",
      vmName: reference.displayName)
    return recovered
  }

  private func recordVerification(
    _ verified: PommeSecurityOwnerVerification, progress: PommeSecurityWorkflowProgress
  ) throws {
    guard verified.startupVolumeGroupUUID == progress.journal.identity.startupVolumeGroupUUID else {
      throw PommeSecurityWorkflowJournalError.identityMismatch
    }
    try progress.update {
      try progress.store.recordOwnerVerified(
        $0, generatedUID: verified.generatedUID, lease: progress.lease)
    }
  }

  private func preparation(
    username: String, progress: PommeSecurityWorkflowProgress, priorProvisioningAbsent: Bool
  ) -> PommeSecurityOwnerPreparation {
    .init(
      identity: .init(
        username: username,
        expectedVolumeGroupUUID: progress.journal.identity.startupVolumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true, priorProvisioningAbsent: priorProvisioningAbsent),
      executeGuest: { try normal.execute($0) },
      executePrivatePTY: { command, password in
        try await PommeCore.runSecurityPrivatePTY(
          reference: reference,
          expectedExecutableDigest: normal.expectedExecutableDigest,
          command: command, password: password)
      },
      readBuddyPreferencesStatus: { try normal.buddyPreferencesStatus() },
      readDirectory: { try normal.localDirectory() },
      verifyPassword: { try normal.verifyDirectoryPassword(username: $0, password: $1) },
      reportPhase: { phase, event in
        PommeCore.log(
          "Owner preparation: \(phase.rawValue) \(event.rawValue).",
          vmName: reference.displayName)
      })
  }
}
