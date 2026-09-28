import Foundation
import Testing
import Synchronization

@Suite("Pomme normal guest owner preparation")
struct PommeSecurityOwnerPreparationTests {
  @Test("Buddy receipts must match the current boot, OS, and verified owner", arguments: [
    "success", "failed", "boot", "build", "version", "uid", "guid", "home", "account", "missingOwner", "unknownOutcome",
    "successStage", "waitingStage", "runningStage", "waitingError", "runningError", "successError",
  ])
  func buddyReceiptValidation(mode: String) async throws {
    let fixture = OwnerPreparationFixture(existingOwner: true)
    fixture.ownerSetupAssistantProcessPresent = true
    let calls = Mutex(0)
    let preparation = PommeSecurityOwnerPreparation(
      freshnessRequirements: .verifiedFresh, executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY,
      readBuddyPreferencesStatus: {
        calls.withLock { $0 += 1 }
        return .init(
          bootSessionUUID: mode == "boot" ? UUID().uuidString : "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB",
          productVersion: mode == "version" ? "27.0" : "26.6.2",
          buildVersion: mode == "build" ? "26A428" : "25G83",
          owner: mode == "missingOwner" ? nil : .init(
            account: mode == "account" ? "other" : "pomme", uid: mode == "uid" ? 502 : 501,
            generatedUID: mode == "guid" ? UUID().uuidString : fixture.generatedUID.uuidString,
            homeDirectory: mode == "home" ? "/var/empty" : "/Users/pomme"),
          stage: mode == "successStage" ? "maintainingBuild"
            : mode == "waitingError" ? "waitingForOwner"
            : mode == "runningError" ? "maintainingBuild" : "complete",
          outcome: mode == "failed" ? "failed" : mode == "unknownOutcome" ? "other"
            : mode.hasPrefix("waiting") ? "waiting" : mode.hasPrefix("running") ? "running" : "succeeded",
          error: mode.hasSuffix("Error") ? .init(code: "unexpected-error", numericCode: 1) : nil)
      })
    let verified = try await preparation.verifyOwner(password: "opaque-owner-secret")
    if mode == "success" {
      try await preparation.completeFreshOwnerAfterLogin(password: "opaque-owner-secret", expected: verified)
      #expect(fixture.ownerSetupAssistantProcessPresent)
    } else {
      let expected: PommeSecurityOwnerPreparationError = mode == "failed"
        ? .buddyPreferencesFailed : .ownerCompletionVerificationFailed
      await #expect(throws: expected) {
        try await preparation.completeFreshOwnerAfterLogin(password: "opaque-owner-secret", expected: verified)
      }
      #expect(fixture.ownerSetupAssistantProcessPresent)
    }
    #expect(calls.withLock { $0 } == 1)
    #expect(!fixture.guestArguments.contains { $0.first == "-TERM" })
    #expect(!fixture.guestArguments.contains { $0.contains("/usr/bin/defaults") && $0.contains("write") })
    #expect(!fixture.setupDone)
  }

  @Test("Buddy status waits without console login or host preference writes")
  func buddyReceiptWaitsBeforeLogin() async throws {
    let fixture = OwnerPreparationFixture(existingOwner: true)
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    let calls = Mutex(0)
    let waits = Mutex(0)
    let preparation = PommeSecurityOwnerPreparation(
      freshnessRequirements: .verifiedFresh, executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY,
      readBuddyPreferencesStatus: {
        let count = calls.withLock { $0 += 1; return $0 }
        if count == 1 { return nil }
        if count < 4 {
          return .init(bootSessionUUID: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB",
            productVersion: "26.6.2", buildVersion: "25G83",
            owner: count == 2 ? nil : fixture.buddyStatus()?.owner,
            stage: count == 2 ? "waitingForOwner" : "maintainingBuild",
            outcome: count == 2 ? "waiting" : "running", error: nil)
        }
        return fixture.buddyStatus()
      }, waitForFreshOwnerAPFS: { seconds in
        #expect(seconds == 2)
        waits.withLock { $0 += 1 }
      })
    let verified = try await preparation.verifyOwner(password: "opaque-owner-secret")
    let status = try await preparation.waitForBuddyPreferences(expected: verified)
    #expect(status.outcome == "succeeded")
    #expect(waits.withLock { $0 } == 3)
    #expect(!fixture.guestArguments.contains { $0.contains("/dev/console") || $0.contains("write") })
    #expect(!fixture.setupDone)
  }

  @Test("Missing Buddy capability requires an updated agent")
  func buddyCapabilityRequired() async throws {
    let fixture = OwnerPreparationFixture(existingOwner: true)
    let preparation = PommeSecurityOwnerPreparation(
      freshnessRequirements: .verifiedFresh, executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY)
    let verified = try await preparation.verifyOwner(password: "opaque-owner-secret")
    await #expect(throws: PommeSecurityOwnerPreparationError.buddyPreferencesAgentRequired) {
      try await preparation.waitForBuddyPreferences(expected: verified)
    }
    #expect(!fixture.setupDone)
  }

  @Test("Marker-first lab writes setup markers without per-user preferences", arguments: [false, true])
  func markerFirstDefersPreferences(alreadyConfigured: Bool) async throws {
    let fixture = OwnerPreparationFixture(existingOwner: true)
    if !alreadyConfigured { fixture.autoLoginStatusOutput = "Automatic login is OFF.\n" }
    fixture.setupAssistantBuildWriteExit = 1
    fixture.miniBuddyLaunchWriteExit = 1
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute, executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus)
    _ = try await preparation.configureLogin(
      password: "opaque-owner-secret", deferOwnerPreferences: true)
    #expect(fixture.setupDone)
    #expect(fixture.setupAssistantBuildPreference == nil)
    #expect(fixture.miniBuddyLaunchPreference == nil)
    #expect(fixture.ptyCommands.contains { $0.arguments.contains("-autologin") } == !alreadyConfigured)
  }

  @Test("Lab setter failure stops before completion and is never retried")
  func labSetterFailureStopsImmediately() async throws {
    let fixture = OwnerPreparationFixture(existingOwner: true)
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    let calls = Mutex(0)
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute, executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus)
    await #expect(throws: PommeSecurityOwnerPreparationError.privatePTYUnavailable) {
      try await preparation.configureLogin(password: "opaque-owner-secret", labSetter: { _ in
        calls.withLock { $0 += 1 }
        throw PommeSecurityOwnerPreparationError.privatePTYUnavailable
      })
    }
    #expect(calls.withLock { $0 } == 1)
    #expect(!fixture.setupDone)
    #expect(!fixture.ptyCommands.contains { $0.arguments.contains("-autologin") })
  }

  @Test("Lab setter retains common readback and Setup Assistant completion", arguments: [false, true])
  func labSetterSharedCompletion(rejectReadback: Bool) async throws {
    let fixture = OwnerPreparationFixture(existingOwner: true)
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    let calls = Mutex(0)
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute, executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus)
    let setter: @Sendable (String) async throws -> Void = { password in
      #expect(password == "opaque-owner-secret")
      calls.withLock { $0 += 1 }
      fixture.autoLoginStatusOutput = rejectReadback
        ? "Automatic login is OFF.\n" : "Automatic login user: pomme\n"
    }
    if rejectReadback {
      await #expect(throws: PommeSecurityOwnerPreparationError.autoLoginVerificationFailed) {
        try await preparation.configureLogin(password: "opaque-owner-secret", labSetter: setter)
      }
      #expect(!fixture.setupDone)
    } else {
      _ = try await preparation.configureLogin(password: "opaque-owner-secret", labSetter: setter)
      #expect(fixture.setupDone)
    }
    #expect(calls.withLock { $0 } == 1)
    #expect(!fixture.ptyCommands.contains { $0.arguments.contains("-autologin") })
  }

  @Test("MDM bootstrap-token keys are recognized but never prove a local account owner")
  func mdmBootstrapTokenAPFSUser() throws {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutput = fixture.pipePrefixedAPFSUsers
      .replacingOccurrences(of: "Recovery User", with: "MDM Bootstrap Token External Key")
      .replacingOccurrences(of: "Volume Owner: No", with: "Volume Owner: Yes")
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute, executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus)
    let probe = try preparation.probe()
    #expect(probe.evidence.apfsUsers.count == 2)
    #expect(probe.evidence.apfsLocalOwners.count == 1)
    #expect(probe.evidence.apfsLocalOwners.first?.generatedUID == fixture.generatedUID)
    #expect(!probe.freshness.isVerifiedFresh)
  }

  @Test("Stock Setup Assistant retry remains gated by attempt, freshness, identity, policy, and exact context", arguments: [
    "freshInitial", "nonfreshInitial", "nonfreshRetry", "otherOwner", "rootOwner", "offOwner", "malformed",
    "credential", "owner", "restricted", "unsupported", "contextUID", "contextPath", "contextDuplicate",
    "contextStale", "contextSession", "contextAudit", "languageChooser", "completedContext",
  ])
  func stockSetupOwnerRetryGates(mode: String) async throws {
    let fixture = OwnerPreparationFixture(existingOwner: true)
    fixture.autoLoginStatusOutput = "Automatic login user: _mbsetupuser\n"
    switch mode {
    case "otherOwner": fixture.autoLoginStatusOutput = "Automatic login user: other-owner\n"
    case "rootOwner": fixture.autoLoginStatusOutput = "Automatic login user: root\n"
    case "offOwner": fixture.autoLoginStatusOutput = "Automatic login user: OFF\n"
    case "malformed": fixture.autoLoginStatusOutput = "malformed\n"
    case "owner": fixture.customHome = "/var/empty"
    case "restricted": fixture.fileVaultEnabled = true
    case "contextUID", "completedContext": fixture.setupAssistantProcessUID = 501
    case "contextPath": fixture.setupAssistantProcessPath = "/usr/bin/other"
    case "contextDuplicate": fixture.setupAssistantDuplicateProcess = true
    case "contextStale": fixture.setupAssistantStaleRecheck = true
    case "contextSession": fixture.setupAssistantManagerName = "Background"
    case "contextAudit": fixture.setupAssistantAuditSessionID = 0
    case "languageChooser": fixture.useLanguageChooser = true
    default: break
    }
    if mode == "completedContext" { fixture.setupDone = true }
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: mode.hasPrefix("nonfresh") ? .unverified : .verifiedFresh,
      executeGuest: { request in
        if mode == "unsupported", request.path == "/usr/sbin/sysadminctl", request.arguments == ["-help"] {
          return .init(exitCode: 0, signal: nil, stdout: Data(), stderr: Data(),
                       stdoutTruncated: false, stderrTruncated: false, exited: true)
        }
        return try fixture.execute(request)
      }, executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )
    let expected: PommeSecurityOwnerPreparationError
    switch mode {
    case "credential": expected = .credentialRequired
    case "owner": expected = .ownerVerificationFailed
    case "restricted": expected = .loginRestricted
    case "unsupported": expected = .autoLoginUnsupported
    case "contextUID", "contextPath", "contextDuplicate", "contextStale", "contextSession", "contextAudit", "languageChooser", "completedContext":
      expected = .setupAssistantContextUnavailable
    default: expected = .autoLoginVerificationFailed
    }
    await #expect(throws: expected) {
      if mode.hasSuffix("Initial") {
        _ = try await preparation.configureLogin(password: "opaque-owner-secret")
      } else {
        _ = try await preparation.configureLogin(
          password: mode == "credential" ? "" : "opaque-owner-secret", attempt: .afterPreferenceRestart)
      }
    }
    #expect(fixture.ptyCommands.contains { $0.arguments.contains("-autologin") } == false)
    #expect(fixture.guestPaths.contains("/usr/sbin/languagesetup") == false)
    #expect(fixture.miniBuddyLaunchPreference == nil)
    #expect(fixture.setupDone == (mode == "completedContext"))
  }

  @Test("Temporary readback trace follows real reconciliation without retaining native data", arguments: [
    "valid", "off", "shape", "empty", "lines", "otherOwner", "nativeCommand", "nativeEvidence",
    "missingPreference", "preferenceShape", "preferenceMismatch", "missingArtifact",
    "metadataCommand", "metadataInvalid",
    "expectedUppercase", "setupOwner", "setupOwnerUppercase", "offOwner", "offOwnerUppercase", "rootOwner",
    "preferenceCase", "preferenceSetup", "preferenceSetupUppercase", "preferenceOff", "preferenceOffUppercase",
    "preferenceRoot", "preferenceRootUppercase",
  ])
  func autoLoginReadbackTraceBranches(mode: String) async throws {
    let fixture = OwnerPreparationFixture(existingOwner: true)
    let trace = Mutex<[PommeAutoLoginReadbackTrace]>([])
    let preparation = PommeSecurityOwnerPreparation(
      executeGuest: { request in
        var output: String?
        var exitCode = 0
        var truncated = false
        if request.path == "/usr/sbin/sysadminctl", request.arguments == ["-autologin", "status"] {
          switch mode {
          case "off": output = "Automatic login is OFF.\n"
          case "shape": output = "private-native-diagnostic\n"
          case "empty": output = "\n  \n"
          case "lines": output = "Automatic login user: pomme\nprivate-native-diagnostic\n"
          case "otherOwner": output = "Automatic login user: private-other-owner\n"
          case "expectedUppercase": output = "Automatic login user: POMME\n"
          case "setupOwner": output = "Automatic login user: _mbsetupuser\n"
          case "setupOwnerUppercase": output = "Automatic login user: _MBSETUPUSER\n"
          case "offOwner": output = "Automatic login user: off\n"
          case "offOwnerUppercase": output = "Automatic login user: OFF\n"
          case "rootOwner": output = "Automatic login user: root\n"
          case "nativeCommand": output = "private-native-diagnostic"; exitCode = 1
          case "nativeEvidence": output = "private-native-diagnostic"; truncated = true
          default: break
          }
        } else if request.path == "/usr/bin/defaults", request.arguments.last == "autoLoginUser" {
          switch mode {
          case "missingPreference": output = "private-defaults-diagnostic"; exitCode = 1
          case "preferenceShape": output = "private-value\nprivate-second-line"
          case "preferenceMismatch": output = "private-other-owner"
          case "preferenceCase": output = "POMME"
          case "preferenceSetup": output = "_mbsetupuser"
          case "preferenceSetupUppercase": output = "_MBSETUPUSER"
          case "preferenceOff": output = "off"
          case "preferenceOffUppercase": output = "OFF"
          case "preferenceRoot": output = "root"
          case "preferenceRootUppercase": output = "ROOT"
          default: break
          }
        } else if request.path == "/bin/test", request.arguments == ["-f", "/etc/kcpassword"], mode == "missingArtifact" {
          output = ""; exitCode = 1
        } else if request.path == "/usr/bin/stat", request.arguments == ["-f", "%u:%g:%Lp", "/etc/kcpassword"] {
          if mode == "metadataCommand" { output = "private-stat-diagnostic"; exitCode = 1 }
          if mode == "metadataInvalid" { output = "501:0:644" }
        }
        guard let output else { return try fixture.execute(request) }
        return GuestCommandResult(
          exitCode: exitCode, signal: nil, stdout: Data(output.utf8), stderr: Data(),
          stdoutTruncated: truncated, stderrTruncated: false, exited: true)
      },
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      autoLoginTrace: { event in trace.withLock { $0.append(event) } }
    )
    var failure: PommeSecurityOwnerPreparationError?
    do {
      let result = try await preparation.configureLogin(password: "")
      #expect(result.autoLoginConfigured)
    } catch let error as PommeSecurityOwnerPreparationError {
      failure = error
    }
    let prefix: [PommeAutoLoginReadbackTrace] = [.reconcileEntered, .nativeEntered]
    let expected: [PommeAutoLoginReadbackTrace]
    switch mode {
    case "off": expected = prefix + [.nativeOff, .reconcileOff]
    case "shape": expected = prefix + [.nativeShapeRejected, .reconcileRejected]
    case "empty": expected = prefix + [.nativeEmptyRejected, .reconcileRejected]
    case "lines": expected = prefix + [.nativeMultipleLinesRejected, .reconcileRejected]
    case "otherOwner": expected = prefix + [.nativeOtherOwner, .reconcileRejected]
    case "setupOwner", "setupOwnerUppercase": expected = prefix + [.nativeSetupAssistantOwner, .reconcileRejected]
    case "offOwner", "offOwnerUppercase": expected = prefix + [.nativeOffAsOwner, .reconcileRejected]
    case "rootOwner": expected = prefix + [.nativeRootOwner, .reconcileRejected]
    case "nativeCommand": expected = prefix + [.nativeCommandFailed, .reconcileRejected]
    case "nativeEvidence": expected = prefix + [.nativeEvidenceFailed, .reconcileRejected]
    default:
      let preference = prefix + [.nativeExpectedOwner, .preferenceEntered]
      switch mode {
      case "missingPreference": expected = preference + [.preferenceCommandFailed, .reconcileRejected]
      case "preferenceShape": expected = preference + [.preferenceShapeRejected, .reconcileRejected]
      case "preferenceMismatch": expected = preference + [.preferenceMismatch, .reconcileRejected]
      case "preferenceCase": expected = preference + [.preferenceExpectedOwnerCaseMismatch, .reconcileRejected]
      case "preferenceSetup", "preferenceSetupUppercase": expected = preference + [.preferenceSetupAssistantOwner, .reconcileRejected]
      case "preferenceOff", "preferenceOffUppercase": expected = preference + [.preferenceOffAsOwner, .reconcileRejected]
      case "preferenceRoot", "preferenceRootUppercase": expected = preference + [.preferenceRootOwner, .reconcileRejected]
      case "missingArtifact": expected = preference + [.preferenceMatch, .artifactEntered, .artifactAbsent, .reconcileRejected]
      case "metadataCommand": expected = preference + [.preferenceMatch, .artifactEntered, .artifactMetadataEntered, .artifactMetadataCommandFailed, .reconcileRejected]
      case "metadataInvalid": expected = preference + [.preferenceMatch, .artifactEntered, .artifactMetadataEntered, .artifactInvalid, .reconcileRejected]
      default: expected = preference + [.preferenceMatch, .artifactEntered, .artifactMetadataEntered, .artifactValid, .reconcileConfigured]
      }
    }
    #expect(trace.withLock { $0 } == expected)
    if mode == "valid" || mode == "expectedUppercase" { #expect(failure == nil) }
    else if mode == "off" { #expect(failure == .credentialRequired) }
    else if mode == "nativeCommand" { #expect(failure == .commandFailed(.autoLogin, exitCode: 1)) }
    else if mode == "missingPreference" || mode == "metadataCommand" {
      #expect(failure == .commandFailed(.loginWindow, exitCode: 1))
    } else if mode == "nativeEvidence" { #expect(failure == .evidenceUnavailable(.loginWindow)) }
    else { #expect(failure == .autoLoginVerificationFailed) }
    for event in trace.withLock({ $0 }) {
      #expect(event.message == "[DEBUG-autologin-readback-20260922] \(event.rawValue)")
      #expect(event.message.contains("private-") == false)
      #expect(event.rawValue.allSatisfy { $0.isLetter })
    }
  }

  @Test("Owner evidence commands allow bounded first-boot initialization")
  func evidenceCommandTimeout() {
    #expect(PommeSecurityOwnerPreparation.commandTimeout == 120)
  }

  @Test("Framework owner verification returns identity and login proofs without mutation", arguments: [
    "", "artifactReadOnly",
  ])
  func frameworkOwnerProof(artifact: String) async throws {
    let fixture = FrameworkOwnerProofFixture(failure: artifact)
    let proof = try await fixture.preparation.verifyFrameworkProvisionedOwner(
      password: FrameworkOwnerProofFixture.password,
      expectedGeneratedUID: fixture.base.generatedUID
    )
    #expect(proof.owner.generatedUID == fixture.base.generatedUID)
    #expect(proof.owner.startupVolumeGroupUUID == fixture.base.volumeGroupUUID)
    #expect(proof.startupRootVolumeUUID == fixture.base.rootVolumeUUID)
    #expect(proof.owner.uniqueID == 501)
    #expect(proof.owner.passwordVerified && proof.owner.isAdministrator)
    #expect(proof.owner.secureTokenEnabled && proof.owner.isAPFSVolumeOwner)
    #expect(proof.automaticLoginVerified && proof.consoleUserVerified)
    fixture.expectReadOnlyAndRedacted()
    #expect(!String(describing: proof).contains(FrameworkOwnerProofFixture.password))
  }

  @Test("Framework owner proof fails closed for each missing account and login proof", arguments: [
    "password", "admin", "token", "apfs", "volumeGroup", "generatedUID", "numericUID",
    "home", "fullName", "autologin", "preference", "artifactOwner", "artifactGroup", "artifactMode",
    "artifactSymlink", "artifactDirectory", "artifactLinks", "artifactMissing", "console",
    "executorError", "ptyError", "ambiguousToken",
  ])
  func frameworkOwnerMissingProof(failure: String) async throws {
    let fixture = FrameworkOwnerProofFixture(failure: failure)
    do {
      _ = try await fixture.preparation.verifyFrameworkProvisionedOwner(
        password: FrameworkOwnerProofFixture.password,
        expectedGeneratedUID: failure == "generatedUID" ? UUID() : fixture.base.generatedUID
      )
      Issue.record("Missing framework owner proof was accepted: \(failure)")
    } catch {
      #expect(error is PommeSecurityOwnerPreparationError)
      if failure == "ambiguousToken" {
        #expect(error as? PommeSecurityOwnerPreparationError == .malformedEvidence(.secureToken))
      }
      #expect(!String(describing: error).contains(FrameworkOwnerProofFixture.password))
      #expect(!error.localizedDescription.contains(FrameworkOwnerProofFixture.password))
    }
    fixture.expectReadOnlyAndRedacted()
  }

  @Test("Probe requires host ownership and prior-provisioning evidence for freshness")
  func freshnessBindsHostEvidence() throws {
    let fixture = OwnerPreparationFixture()
    let identity = PommeSecurityOwnerIdentity(expectedVolumeGroupUUID: fixture.volumeGroupUUID)
    let unverified = PommeSecurityOwnerPreparation(
      identity: identity,
      freshnessRequirements: .unverified,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )
    let probe = try unverified.probe()
    #expect(!probe.freshness.creationOwnershipVerified)
    #expect(!probe.freshness.priorProvisioningAbsent)
    #expect(!probe.freshness.isVerifiedFresh)

    let verified = PommeSecurityOwnerPreparation(
      identity: identity,
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )
    let freshProbe = try verified.probe()
    #expect(freshProbe.freshness.isVerifiedFresh)
    #expect(freshProbe.evidence.localUsers.isEmpty)
    #expect(freshProbe.evidence.apfsLocalOwners.isEmpty)
  }

  @Test("The macOS nobody -2 system record is accepted and excluded from freshness")
  func nobodySystemUIDIsIgnoredForFreshness() throws {
    let fixture = OwnerPreparationFixture()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let probe = try preparation.probe()
    #expect(probe.freshness.isVerifiedFresh)
    #expect(!probe.evidence.localUsers.contains { $0.recordName == "nobody" })
  }

  @Test("An arbitrary negative local UID is malformed evidence")
  func arbitraryNegativeUIDFailsClosed() {
    let fixture = OwnerPreparationFixture()
    fixture.invalidNegativeUID = true
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    #expect(throws: PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)) {
      try preparation.probe()
    }
  }

  @Test("A nobody system record remains an account collision when selected as the target")
  func nobodyTargetRemainsCollision() async throws {
    let fixture = OwnerPreparationFixture()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(
        username: "nobody",
        fullName: "Nobody",
        expectedVolumeGroupUUID: fixture.volumeGroupUUID
      ),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let probe = try preparation.probe()
    #expect(probe.evidence.targetAccountExists)
    await #expect(throws: PommeSecurityOwnerPreparationError.accountCollision) {
      try await preparation.createOwner(password: "opaque-owner-secret", probe: probe)
    }
    #expect(fixture.ptyCommands.isEmpty)
  }

  @Test("A low-UID account with a custom GeneratedUID blocks freshness")
  func customLowUIDAccountBlocksFreshness() throws {
    let fixture = OwnerPreparationFixture()
    fixture.includeCustomLowUser = true
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let probe = try preparation.probe()
    #expect(!probe.freshness.isVerifiedFresh)
    #expect(probe.evidence.normalLocalUsers.contains { $0.recordName == "alice" })
    #expect(
      probe.evidence.localUsers.first { $0.recordName == "alice" }?.homeDirectory == "/var/empty")
  }

  @Test("An unfamiliar low-UID account blocks freshness even with Apple's stock GeneratedUID")
  func stockShapedLowUIDGeneratedUIDBlocksFreshness() throws {
    let fixture = OwnerPreparationFixture()
    fixture.includeCustomLowUser = true
    fixture.customLowUsesStockGeneratedUID = true
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let probe = try preparation.probe()
    #expect(!probe.freshness.isVerifiedFresh)
    #expect(probe.evidence.normalLocalUsers.contains { $0.recordName == "alice" })
  }

  @Test("A high-UID account remains a user even with a stock-shaped GeneratedUID")
  func highUIDStockGeneratedUIDBlocksFreshness() throws {
    let fixture = OwnerPreparationFixture()
    fixture.includeDeterministicHighUIDUser = true
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let probe = try preparation.probe()
    #expect(!probe.freshness.isVerifiedFresh)
    #expect(probe.evidence.normalLocalUsers.contains { $0.recordName == "pomme" })
  }

  @Test("An unknown high-UID local record prevents a fresh-account decision")
  func hiddenNormalAccountBlocksFreshness() throws {
    let fixture = OwnerPreparationFixture()
    fixture.includeHiddenNormalUser = true
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let probe = try preparation.probe()
    #expect(!probe.freshness.isVerifiedFresh)
    #expect(probe.evidence.normalLocalUsers.contains { $0.recordName == "_hidden" })
  }

  @Test("Duplicate local-user fields are malformed evidence")
  func duplicateLocalRecordFieldFailsClosed() {
    let fixture = OwnerPreparationFixture()
    fixture.duplicateLocalRecord = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    #expect(throws: PommeSecurityOwnerPreparationError.malformedEvidence(.localUserRecord)) {
      try preparation.probe()
    }
  }

  @Test("An unrecognized nonempty APFS user collection cannot be hidden by an empty one")
  func unknownAPFSCollectionFailsClosed() {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutput = fixture.ambiguousAPFSUsersPlist
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    #expect(throws: PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)) {
      try preparation.probe()
    }
  }

  @Test("No APFS users evidence requires the exact startup-device header")
  func noAPFSUsersHeaderIsStrict() {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutput = "No cryptographic users for disk1s1\nUnexpected trailing text\n"
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    #expect(throws: PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)) {
      try preparation.probe()
    }
  }

  @Test("A residual non-owner APFS record still blocks fresh owner preparation")
  func residualAPFSRecordBlocksFreshness() throws {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutput = fixture.residualAPFSUser
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let probe = try preparation.probe()
    #expect(!probe.freshness.isVerifiedFresh)
    #expect(probe.evidence.apfsUsers.count == 1)
    #expect(probe.evidence.apfsLocalOwners.isEmpty)
  }

  @Test("APFS text records accept native pipe-prefixed fields for multiple users")
  func pipePrefixedAPFSFieldsAreParsed() throws {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutput = fixture.pipePrefixedAPFSUsers
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let probe = try preparation.probe()
    #expect(probe.evidence.apfsUsers.count == 2)
    #expect(!probe.freshness.isVerifiedFresh)
  }

  @Test("Fresh creation uses sysadminctl password marker and verifies every owner fact")
  func createsAndVerifiesOwnerWithoutSecretInCommand() async throws {
    let fixture = OwnerPreparationFixture()
    let identity = PommeSecurityOwnerIdentity(expectedVolumeGroupUUID: fixture.volumeGroupUUID)
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: identity,
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      reportPhase: phases.record
    )

    let probe = try preparation.probe()
    let verification = try await preparation.createOwner(
      password: "opaque-owner-secret",
      probe: probe
    )

    #expect(verification.username == "pomme")
    #expect(verification.passwordVerified)
    #expect(verification.isAdministrator)
    #expect(verification.secureTokenEnabled)
    #expect(verification.isAPFSVolumeOwner)
    #expect(
      fixture.ptyCommands.contains {
        $0.executable == "/usr/sbin/sysadminctl"
          && $0.arguments == [
            "-addUser", "pomme", "-fullName", "Pomme", "-admin", "-password", "-",
          ]
      })
    #expect(
      fixture.ptyCommands.contains {
        $0.executable == "/usr/bin/dscl"
          && $0.arguments == [".", "-authonly", "pomme"]
      })
    #expect(
      fixture.ptyCommands.allSatisfy { command in
        !command.arguments.contains("opaque-owner-secret")
      })
    #expect(phases.values.contains { $0 == (.createOwner, .intent) })
    #expect(phases.values.contains { $0 == (.createOwner, .receipt) })
  }

  @Test("Fresh creation re-observes transient malformed APFS evidence")
  func freshCreationRetriesTransientAPFSEvidence() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutputSequence = [
      "No cryptographic users for disk1s1\n",
      fixture.ambiguousAPFSUsersPlist,
      fixture.apfsUsers,
    ]
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      reportPhase: phases.record,
      waitForFreshOwnerAPFS: { _ in }
    )

    let probe = try preparation.probe()
    let verification = try await preparation.createOwner(
      password: "opaque-owner-secret",
      probe: probe
    )

    #expect(verification.isAPFSVolumeOwner)
    #expect(fixture.ptyCommands.filter { $0.arguments.first == "-addUser" }.count == 1)
    #expect(fixture.apfsOutputSequence.isEmpty)
    #expect(phases.values.contains { $0 == (.verifyOwner, .receipt) })
  }

  @Test("Persistent malformed post-create APFS evidence fails after bounded retries")
  func persistentMalformedPostCreateAPFSEvidenceFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutputSequence = [
      "No cryptographic users for disk1s1\n",
    ] + Array(repeating: fixture.ambiguousAPFSUsersPlist, count: 4)
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      reportPhase: phases.record,
      waitForFreshOwnerAPFS: { _ in }
    )

    let probe = try preparation.probe()
    await #expect(
      throws: PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
    ) {
      try await preparation.createOwner(password: "opaque-owner-secret", probe: probe)
    }

    #expect(fixture.ptyCommands.filter { $0.arguments.first == "-addUser" }.count == 1)
    #expect(fixture.apfsOutputSequence.isEmpty)
    #expect(!phases.values.contains { $0 == (.verifyOwner, .receipt) })
  }

  @Test("Malformed initial APFS evidence is rejected before fresh creation")
  func malformedInitialAPFSEvidenceDoesNotCreateOwner() {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutput = fixture.ambiguousAPFSUsersPlist
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      waitForFreshOwnerAPFS: { _ in throw CancellationError() }
    )

    #expect(throws: PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)) {
      try preparation.probe()
    }
    #expect(fixture.ptyCommands.isEmpty)
  }

  @Test("A non-APFS evidence error is not retried after fresh creation")
  func nonAPFSEvidenceErrorIsNotRetried() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutputSequence = [
      "No cryptographic users for disk1s1\n",
      fixture.apfsUsers,
    ]
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: { command, password in
        let status = try await fixture.executePTY(command, password)
        if command.arguments.first == "-addUser" {
          fixture.invalidNegativeUID = true
        }
        return status
      },
      reportPhase: phases.record,
      waitForFreshOwnerAPFS: { _ in throw CancellationError() }
    )

    let probe = try preparation.probe()
    await #expect(throws: PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)) {
      try await preparation.createOwner(password: "opaque-owner-secret", probe: probe)
    }

    #expect(fixture.ptyCommands.filter { $0.arguments.first == "-addUser" }.count == 1)
    #expect(fixture.apfsOutputSequence == [fixture.apfsUsers])
    #expect(!phases.values.contains { $0 == (.verifyOwner, .receipt) })
  }

  @Test("Cancellation during APFS re-observation stops fresh verification")
  func cancellationDuringFreshAPFSReobservationStopsVerification() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutputSequence = [
      "No cryptographic users for disk1s1\n",
      fixture.ambiguousAPFSUsersPlist,
      fixture.apfsUsers,
    ]
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      reportPhase: phases.record,
      waitForFreshOwnerAPFS: { _ in throw CancellationError() }
    )

    let probe = try preparation.probe()
    await #expect(throws: CancellationError.self) {
      try await preparation.createOwner(password: "opaque-owner-secret", probe: probe)
    }

    #expect(fixture.ptyCommands.filter { $0.arguments.first == "-addUser" }.count == 1)
    #expect(fixture.apfsOutputSequence == [fixture.apfsUsers])
    #expect(!phases.values.contains { $0 == (.verifyOwner, .receipt) })
  }

  @Test("No APFS re-observation starts after its retry deadline")
  func freshAPFSReobservationHonorsRetryDeadline() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.apfsOutputSequence = [
      "No cryptographic users for disk1s1\n",
      fixture.ambiguousAPFSUsersPlist,
      fixture.apfsUsers,
    ]
    let clock = MonotonicClock()
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      reportPhase: phases.record,
      waitForFreshOwnerAPFS: { _ in clock.advance(to: 30) },
      now: { clock.value }
    )

    let probe = try preparation.probe()
    await #expect(
      throws: PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
    ) {
      try await preparation.createOwner(password: "opaque-owner-secret", probe: probe)
    }

    #expect(clock.value == 30)
    #expect(fixture.ptyCommands.filter { $0.arguments.first == "-addUser" }.count == 1)
    #expect(fixture.apfsOutputSequence == [fixture.apfsUsers])
    #expect(!phases.values.contains { $0 == (.verifyOwner, .receipt) })
  }

  @Test("Autologin refusal classifier accepts only closed native markers")
  func classifiesNativeAutologinRefusals() {
    let cases: [(String, PommeSecurityOwnerAutologinRefusal)] = [
      (
        "2026-09-05 15:00:00.000 sysadminctl[1:2] Automatic login can not be set because because TouchID, Apple Pay or App Store purchases are enabled (use -force flag to override)\n",
        .purchaseProtection
      ),
      ("Automatic login is disabled by your system administrator.\n", .management),
      ("Automatic login is disabled because FileVault is enabled.\n", .fileVault),
      ("SystemConfiguration commitChanges failed.\n", .preferenceCommit),
      ("Failed to authenticate with SystemAdministration framework.\n", .authentication),
      (
        "sysadminctl should be run as root, or in interactive mode! (autologin)\n",
        .requiresRootOrInteractive
      ),
    ]

    for (output, expected) in cases {
      #expect(
        PommeSecurityOwnerAutologinRefusal.classify(Data(output.utf8)) == expected
      )
    }
  }

  @Test("Autologin refusal classifier ignores arbitrary and oversized output")
  func classifierRejectsArbitraryOutput() {
    #expect(
      PommeSecurityOwnerAutologinRefusal.classify(
        Data("prefix Automatic login is disabled by your system administrator. suffix".utf8)
      ) == nil
    )
    #expect(
      PommeSecurityOwnerAutologinRefusal.classify(Data("Automatic login is OFF.\n".utf8)) == nil
    )
    var oversized = Data(repeating: 0x20, count: 64 * 1024 + 1)
    oversized.append(Data("SystemConfiguration commitChanges failed.\n".utf8))
    #expect(PommeSecurityOwnerAutologinRefusal.classify(oversized) == nil)
  }

  @Test("An existing target account is a collision unless retry intent is explicit")
  func collisionRequiresRetryIntent() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )
    let probe = try preparation.probe()
    await #expect(throws: PommeSecurityOwnerPreparationError.accountCollision) {
      try await preparation.createOwner(password: "opaque-owner-secret", probe: probe)
    }

    let ptyCount = fixture.ptyCommands.count
    _ = try await preparation.createOwner(
      password: "opaque-owner-secret",
      probe: probe,
      retryIntent: true
    )
    #expect(fixture.ptyCommands.count == ptyCount + 1)
    #expect(fixture.ptyCommands.last?.arguments == [".", "-authonly", "pomme"])
  }

  @Test("An existing owner never uses fresh-create APFS re-observation")
  func existingOwnerMalformedAPFSEvidenceIsNotRetried() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.markCreated()
    fixture.apfsOutputSequence = [
      fixture.apfsUsers, fixture.ambiguousAPFSUsersPlist, fixture.apfsUsers,
    ]
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      reportPhase: phases.record,
      waitForFreshOwnerAPFS: { _ in throw CancellationError() }
    )
    let probe = try preparation.probe()
    await #expect(throws: PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)) {
      try await preparation.createOwner(
        password: "opaque-owner-secret", probe: probe, retryIntent: true)
    }
    #expect(!fixture.ptyCommands.contains { $0.arguments.first == "-addUser" })
    #expect(fixture.apfsOutputSequence == [fixture.apfsUsers])
    #expect(!phases.values.contains { $0 == (.verifyOwner, .receipt) })
  }

  @Test("Retry verification accepts an exact existing owner with a custom home")
  func existingOwnerCustomHomeIsVerified() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.customHome = "/var/empty"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let verification = try await preparation.verifyOwner(password: "opaque-owner-secret")
    #expect(verification.username == "pomme")
    #expect(verification.passwordVerified)
    #expect(fixture.ptyCommands.allSatisfy { $0.arguments.first != "-addUser" })
  }

  @Test("Autologin is rejected before any mutation when FileVault or management restricts it")
  func loginRestrictionsFailClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.fileVaultEnabled = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.loginRestricted) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
  }

  @Test("Any managed preference state blocks persistent automatic login")
  func managedPreferencesFailClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.managedPreferencesPresent = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.loginRestricted) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
  }

  @Test("An owner-scoped configuration profile blocks automatic login")
  func ownerConfigurationProfileFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.ownerConfigurationProfiles = "Configuration profile: com.example.managed\n"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.loginRestricted) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
  }

  @Test("A managed-preferences symlink blocks automatic login")
  func managedPreferencesSymlinkFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.managedPreferencesPathState = .symlink
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.loginRestricted) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
  }

  @Test("A managed-preferences non-directory blocks automatic login")
  func managedPreferencesNonDirectoryFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.managedPreferencesPathState = .nonDirectory
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.loginRestricted) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
  }

  @Test("An unreadable managed-preferences path fails closed")
  func unreadableManagedPreferencesFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.managedPreferencesPathState = .unreadable
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.commandFailed(
        .managedLoginWindow, exitCode: 2
      )
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
  }

  @Test("An existing managed-preferences directory requires successful enumeration")
  func managedPreferencesEnumerationFailureFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.managedPreferencesPresent = true
    fixture.managedPreferencesFindExit = 1
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.commandFailed(
        .managedLoginWindow, exitCode: 1
      )
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
  }

  @Test(
    "Configure login verifies native help, sets autologin through PTY, then finishes Setup Assistant"
  )
  func configuresLoginAndSetup() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.markCreated()
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      reportPhase: phases.record
    )

    let result = try await preparation.configureLogin(password: "opaque-owner-secret")
    #expect(result.autoLoginConfigured)
    #expect(result.setupAssistantFinished)
    #expect(
      fixture.ptyCommands.contains {
        $0.executable == "/bin/launchctl"
          && $0.arguments == [
            "asuser", "248", "/usr/sbin/sysadminctl",
            "-adminUser", "pomme", "-adminPassword", "-",
            "-autologin", "set", "-userName", "pomme", "-password", "-",
          ]
      })
    #expect(fixture.guestPaths.contains("/bin/test"))
    #expect(fixture.guestPaths.contains("/bin/sync"))
    #expect(fixture.setupDone)
    #expect(phases.values.contains { $0 == (.finishSetupAssistant, .intent) })
    #expect(phases.values.contains { $0 == (.finishSetupAssistant, .receipt) })
  }

  @Test("Fresh owner completion requires the canonical owner home")
  func freshOwnerCustomHomeFailsBeforePreferenceMutation() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.customHome = "/var/empty"
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.ownerVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(
      !fixture.guestArguments.contains { $0.first == "-n" && $0.contains("/usr/bin/defaults") })
    #expect(!fixture.setupDone)
  }

  @Test("Fresh completion does not signal MiniBuddy and log the owner out")
  func retainedOwnerSetupAssistantIsNotSignalled() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.ownerSetupAssistantProcessPresent = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    _ = try await preparation.configureLogin(password: "opaque-owner-secret")

    #expect(fixture.ownerSetupAssistantProcessPresent)
    #expect(
      !fixture.guestArguments.contains { $0.first == "-TERM" })
    #expect(fixture.setupDone)
  }

  @Test("A retained Setup Assistant for another UID is never terminated")
  func retainedOtherUIDSetupAssistantIsUntouched() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.ownerSetupAssistantProcessPresent = true
    fixture.ownerSetupAssistantProcessUID = 248
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .verifiedFresh,
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    _ = try await preparation.configureLogin(password: "opaque-owner-secret")

    #expect(fixture.ownerSetupAssistantProcessPresent)
    #expect(!fixture.guestArguments.contains { $0.first == "-TERM" })
  }

  @Test("Language Chooser handoff uses native language setup before autologin")
  func languageChooserHandoffUsesNativeTools() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.useLanguageChooser = true
    fixture.markCreated()
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      reportPhase: phases.record
    )

    let result = try await preparation.configureLogin(password: "opaque-owner-secret")

    #expect(result.autoLoginConfigured)
    #expect(result.setupAssistantFinished)
    #expect(fixture.guestPaths.contains("/usr/sbin/languagesetup"))
    #expect(fixture.guestPaths.contains("/usr/bin/notifyutil"))
    #expect(fixture.guestPaths.contains("/usr/bin/defaults"))
    #expect(phases.values.contains { $0 == (.setupAssistantHandoff, .intent) })
    #expect(phases.values.contains { $0 == (.setupAssistantHandoff, .receipt) })
  }

  @Test("Completion creates strict diagnostics and SetupDone markers and clears terms")
  func completionMarkersAreCreatedAndVerified() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.termsPresent = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let result = try await preparation.configureLogin(password: "opaque-owner-secret")

    #expect(result.setupAssistantFinished)
    #expect(fixture.setupDone)
    #expect(fixture.setupDoneMetadata == "0:0:400:0")
    #expect(fixture.diagnosticsPresent)
    #expect(fixture.diagnosticsMetadata == "0:0:400:0")
    #expect(!fixture.termsPresent)
    #expect(fixture.guestPaths.contains("/usr/bin/install"))
    #expect(fixture.guestPaths.contains("/bin/rm"))
  }

  @Test("An interrupted completion with diagnostics already present resumes")
  func interruptedCompletionResumesFromDiagnosticsMarker() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.diagnosticsPresent = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let result = try await preparation.configureLogin(password: "opaque-owner-secret")

    #expect(result.setupAssistantFinished)
    #expect(fixture.setupDone)
    #expect(fixture.diagnosticsPresent)
    #expect(fixture.guestPaths.filter { $0 == "/usr/bin/install" }.count == 1)
  }

  @Test("Existing valid completion markers are idempotent")
  func existingCompletionMarkersArePreserved() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.setupDone = true
    fixture.diagnosticsPresent = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let result = try await preparation.configureLogin(password: "opaque-owner-secret")

    #expect(result.setupAssistantFinished)
    #expect(fixture.guestPaths.filter { $0 == "/usr/bin/install" }.isEmpty)
    #expect(fixture.guestPaths.filter { $0 == "/bin/rm" }.isEmpty)
  }

  @Test("Legacy root-owned SetupDone mode is accepted while diagnostics stays strict")
  func legacySetupDoneModeIsAccepted() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.setupDone = true
    fixture.setupDoneMetadata = "0:0:644:0"
    fixture.diagnosticsPresent = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let result = try await preparation.configureLogin(password: "opaque-owner-secret")

    #expect(result.setupAssistantFinished)
    #expect(fixture.setupDoneMetadata == "0:0:644:0")
  }

  @Test("Nonempty SetupDone content fails closed even with a legacy mode")
  func nonemptySetupDoneMarkerFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.setupDone = true
    fixture.setupDoneMetadata = "0:0:644:1"
    fixture.diagnosticsPresent = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.ownerVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.setupDone)
    #expect(fixture.setupDoneMetadata == "0:0:644:1")
  }

  @Test("Unsafe diagnostics metadata blocks completion without SetupDone mutation")
  func unsafeDiagnosticsMarkerFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.diagnosticsPresent = true
    fixture.diagnosticsMetadata = "501:0:400:0"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.ownerVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.setupDone)
  }

  @Test("A diagnostics marker with the legacy mode fails closed")
  func diagnosticsLegacyModeFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.diagnosticsPresent = true
    fixture.diagnosticsMetadata = "0:0:644:0"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.ownerVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.setupDone)
  }

  @Test("Nonempty terms cookie blocks completion without removing it")
  func nonemptyTermsCookieFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.termsPresent = true
    fixture.termsMetadata = "0:0:400:1"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.ownerVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.termsPresent)
    #expect(!fixture.setupDone)
  }

  @Test("A terms-cookie symlink cannot be removed by completion")
  func termsCookieSymlinkFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.termsPresent = true
    fixture.termsSymlink = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.ownerVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.termsPresent)
    #expect(!fixture.setupDone)
  }

  @Test("A nonregular SetupDone marker fails closed")
  func nonregularSetupDoneMarkerFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.setupDone = true
    fixture.setupDoneRegularFile = false
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.ownerVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.setupDone)
  }

  @Test("A completion command failure does not record a receipt")
  func completionCommandFailureDoesNotRecordReceipt() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.completionInstallExit = 23
    fixture.markCreated()
    let phases = PhaseRecorder()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus,
      reportPhase: phases.record
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.commandFailed(
        .finishSetupAssistant, exitCode: 23
      )
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.diagnosticsPresent)
    #expect(!fixture.setupDone)
    #expect(!phases.values.contains { $0 == (.finishSetupAssistant, .receipt) })
  }

  @Test("An already verified automatic-login state resumes without PTY or context discovery")
  func configuredResumeAfterSetupDoneDoesNotUsePTY() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.setupDone = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let result = try await preparation.configureLogin(password: "opaque-owner-secret")
    #expect(result.autoLoginConfigured)
    #expect(result.setupAssistantFinished)
    #expect(fixture.ptyCommands.isEmpty)
    #expect(fixture.setupDone)
    #expect(!fixture.guestPaths.contains("/bin/ps"))
    #expect(!fixture.guestPaths.contains("/bin/launchctl"))
  }

  @Test("A native SetupDone marker still permits an exact existing Aqua session")
  func setupDoneWithExistingAquaContextCanConfigureAutologin() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.setupDone = true
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    let result = try await preparation.configureLogin(password: "opaque-owner-secret")

    #expect(result.autoLoginConfigured)
    #expect(result.setupAssistantFinished)
    #expect(
      fixture.ptyCommands.contains {
        $0.executable == "/bin/launchctl"
          && $0.arguments == [
            "asuser", "248", "/usr/sbin/sysadminctl",
            "-adminUser", "pomme", "-adminPassword", "-",
            "-autologin", "set", "-userName", "pomme", "-password", "-",
          ]
      })
    #expect(fixture.setupDone)
  }

  @Test("A SetupDone marker without an exact Aqua session fails without handoff")
  func setupDoneWithoutAquaContextFailsWithoutMutation() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.setupDone = true
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.setupAssistantCallerUID = "501"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
    #expect(!fixture.guestPaths.contains("/usr/sbin/languagesetup"))
    #expect(!fixture.guestPaths.contains("/usr/bin/notifyutil"))
    #expect(fixture.setupDone)
  }

  @Test("Setup Assistant context rejects a wrong process identity")
  func setupAssistantWrongUIDFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.setupAssistantProcessUID = 501
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
    #expect(!fixture.setupDone)
  }

  @Test("Setup Assistant context rejects a wrong manager or missing Aqua session")
  func setupAssistantManagerContextFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.setupAssistantCallerUID = "501"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
    #expect(!fixture.setupDone)
  }

  @Test("Setup Assistant context rejects a stale or duplicate process identity")
  func setupAssistantProcessIdentityFailsClosed() async throws {
    for duplicate in [false, true] {
      let fixture = OwnerPreparationFixture()
      fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
      fixture.setupAssistantDuplicateProcess = duplicate
      fixture.setupAssistantStaleRecheck = !duplicate
      fixture.markCreated()
      let preparation = PommeSecurityOwnerPreparation(
        identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
        freshnessRequirements: .init(
          creationOwnershipVerified: true,
          priorProvisioningAbsent: false,
          retryExistingAccount: true
        ),
        executeGuest: fixture.execute,
        executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
      )

      await #expect(
        throws: PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
      ) {
        try await preparation.configureLogin(password: "opaque-owner-secret")
      }
      #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
      #expect(!fixture.setupDone)
    }
  }

  @Test("Setup Assistant context rejects an unexpected executable path")
  func setupAssistantPathFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.setupAssistantProcessPath = "/usr/bin/other"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
    #expect(!fixture.setupDone)
  }

  @Test("Setup Assistant launchd context rejects duplicate top-level fields")
  func setupAssistantDuplicateLaunchdFieldFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.duplicateLaunchdHandle = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
    #expect(!fixture.setupDone)
  }

  @Test("Setup Assistant launchd context rejects nested required fields")
  func setupAssistantNestedLaunchdFieldFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.nestedLaunchdHandle = true
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(fixture.ptyCommands.allSatisfy { !$0.arguments.contains("-autologin") })
    #expect(!fixture.setupDone)
  }

  @Test("Missing kcpassword artifact prevents autologin receipt and Setup Assistant completion")
  func missingAutoLoginArtifactFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.kcpasswordPresent = false
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.autoLoginVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.setupDone)
  }

  @Test("Typed native autologin refusal is preserved without Setup Assistant completion")
  func nativeAutologinRefusalIsPreserved() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.autoLoginRefusal = .purchaseProtection
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.autoLoginRefused(.purchaseProtection)
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.setupDone)
  }

  @Test("Native autologin OFF status prevents configuration receipt")
  func offAutoLoginStatusFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.autoLoginPTYUpdatesStatus = false
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.autoLoginVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.setupDone)
  }

  @Test("Native autologin status for another account fails closed")
  func wrongAutoLoginStatusFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login user: other\n"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.autoLoginVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.setupDone)
  }

  @Test("Negated native autologin status cannot satisfy the positive proof")
  func negatedAutoLoginStatusFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is not enabled.\n"
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(throws: PommeSecurityOwnerPreparationError.autoLoginVerificationFailed) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.setupDone)
  }

  @Test("Nonzero native autologin status cannot satisfy the positive proof")
  func nonzeroAutoLoginStatusFailsClosed() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusExit = 1
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.commandFailed(.autoLogin, exitCode: 1)
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.setupDone)
  }

  @Test("Native autologin failure is returned before any Setup Assistant completion")
  func nativeAutoLoginFailureStopsConfiguration() async throws {
    let fixture = OwnerPreparationFixture()
    fixture.autoLoginStatusOutput = "Automatic login is OFF.\n"
    fixture.autoLoginPTYStatus = 23
    fixture.markCreated()
    let preparation = PommeSecurityOwnerPreparation(
      identity: .init(expectedVolumeGroupUUID: fixture.volumeGroupUUID),
      freshnessRequirements: .init(
        creationOwnershipVerified: true,
        priorProvisioningAbsent: false,
        retryExistingAccount: true
      ),
      executeGuest: fixture.execute,
      executePrivatePTY: fixture.executePTY, readBuddyPreferencesStatus: fixture.buddyStatus
    )

    await #expect(
      throws: PommeSecurityOwnerPreparationError.commandFailed(.autoLogin, exitCode: 23)
    ) {
      try await preparation.configureLogin(password: "opaque-owner-secret")
    }
    #expect(!fixture.setupDone)
  }
}

private final class PhaseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [(PommeSecurityOwnerPreparationPhase, PommeSecurityOwnerPreparationEvent)] =
    []

  var values: [(PommeSecurityOwnerPreparationPhase, PommeSecurityOwnerPreparationEvent)] {
    lock.withLock { stored }
  }

  func record(
    _ phase: PommeSecurityOwnerPreparationPhase,
    _ event: PommeSecurityOwnerPreparationEvent
  ) {
    lock.withLock { stored.append((phase, event)) }
  }
}

private final class MonotonicClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: TimeInterval = 0

  var value: TimeInterval {
    lock.withLock { storedValue }
  }

  func advance(to value: TimeInterval) {
    lock.withLock { storedValue = value }
  }
}

private enum ManagedPreferencesPathState: Equatable, Sendable {
  case absent
  case directory
  case symlink
  case nonDirectory
  case unreadable
}

private final class OwnerPreparationFixture: @unchecked Sendable {
  let volumeGroupUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
  let rootVolumeUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  let generatedUID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
  private let lock = NSLock()
  private var createdValue = false
  private var setupDoneValue = false
  private var setupDoneMetadataValue = "0:0:400:0"
  private var setupDoneSymlinkValue = false
  private var setupDoneRegularFileValue = true
  private var diagnosticsPresentValue = false
  private var diagnosticsMetadataValue = "0:0:400:0"
  private var diagnosticsSymlinkValue = false
  private var diagnosticsRegularFileValue = true
  private var termsPresentValue = false
  private var termsMetadataValue = "0:0:400:0"
  private var termsSymlinkValue = false
  private var termsRegularFileValue = true
  private var completionInstallExitValue: Int32 = 0
  private var completionRemoveExitValue: Int32 = 0
  private var completionSyncExitValue: Int32 = 0
  private var fileVaultEnabledValue = false
  private var includeHiddenNormalUserValue = false
  private var invalidNegativeUIDValue = false
  private var includeCustomLowUserValue = false
  private var customLowUsesStockGeneratedUIDValue = false
  private var includeDeterministicHighUIDUserValue = false
  private var duplicateLocalRecordValue = false
  private var apfsOutputValue: String?
  private var apfsOutputSequenceValue: [String] = []
  private var managedPreferencesPresentValue = false
  private var managedPreferencesPathStateValue = ManagedPreferencesPathState.absent
  private var managedPreferencesFindExitValue: Int32 = 0
  private var ownerConfigurationProfilesValue =
    "There are no configuration profiles installed for user 'pomme'\n"
  private var customHomeValue: String?
  private var kcpasswordPresentValue = true
  private var autoLoginStatusOutputValue =
    "2026-09-05 14:08:43.780 sysadminctl[335:2142] Automatic login user: pomme\n"
  private var autoLoginStatusExitValue: Int32 = 0
  private var autoLoginPTYStatusValue: Int32 = 0
  private var autoLoginPTYUpdatesStatusValue = true
  private var autoLoginRefusalValue: PommeSecurityOwnerAutologinRefusal?
  private var autoLoginUserOutputValue = "pomme\n"
  private var autoLoginArtifactMetadataValue = "0:0:600\n"
  private var nativeBuildVersionValue = "25G83"
  private var nativeBuildExitValue: Int32 = 0
  private var setupAssistantBuildPreferenceValue: String?
  private var setupAssistantBuildReadTypeOutputValue: String?
  private var setupAssistantBuildReadOutputValue: String?
  private var miniBuddyLaunchPreferenceValue: Bool?
  private var miniBuddyLaunchReadTypeOutputValue: String?
  private var miniBuddyLaunchReadOutputValue: String?
  private var setupAssistantBuildWriteExitValue: Int32 = 0
  private var miniBuddyLaunchWriteExitValue: Int32 = 0
  private var ownerSetupAssistantProcessPresentValue = false
  private var ownerSetupAssistantProcessUIDValue: UInt32 = 501
  private var ownerSetupAssistantProcessPIDValue: Int32 = 5252
  private var ownerSetupAssistantProcessStartIdentityValue = "Sat Sep 5 14:30:00 2026"
  private var ownerSetupAssistantProcessPathValue =
    "/System/Library/CoreServices/Setup Assistant.app/Contents/MacOS/Setup Assistant"
  private var ownerSetupAssistantKillExitValue: Int32 = 0
  private var ownerSetupAssistantExitsAfterKillValue = true
  private var driftOwnerPreferencesAfterKillValue = false
  private var missingDefaultsDiagnosticEmptyValue = false
  private var setupAssistantProcessUIDValue: UInt32 = 248
  private var setupAssistantProcessPathValue =
    "/System/Library/CoreServices/Setup Assistant.app/Contents/MacOS/Setup Assistant"
  private var setupAssistantProcessPIDValue: Int32 = 4242
  private var setupAssistantStartIdentityValue = "Sat Sep 5 14:00:00 2026"
  private let languageChooserProcessPIDValue: Int32 = 236
  private var useLanguageChooserValue = false
  private var languageHandoffCompletedValue = false
  private var setupAssistantDuplicateProcessValue = false
  private var setupAssistantStaleRecheckValue = false
  private var setupAssistantAuditSessionIDValue: UInt64 = 100003
  private var duplicateLaunchdHandleValue = false
  private var nestedLaunchdHandleValue = false
  private var setupAssistantManagerNameValue = "Aqua"
  private var setupAssistantManagerUIDValue = "248"
  private var setupAssistantCallerUIDValue = "0"
  private var commandsValue: [PommeSecurityOwnerPTYCommand] = []
  private var guestPathsValue: [String] = []
  private var guestArgumentsValue: [[String]] = []

  init(existingOwner: Bool = false) {
    createdValue = existingOwner
  }

  var ptyCommands: [PommeSecurityOwnerPTYCommand] { lock.withLock { commandsValue } }
  var guestPaths: [String] { lock.withLock { guestPathsValue } }
  var guestArguments: [[String]] { lock.withLock { guestArgumentsValue } }
  var setupDone: Bool {
    get { lock.withLock { setupDoneValue } }
    set { lock.withLock { setupDoneValue = newValue } }
  }
  var setupDoneMetadata: String {
    get { lock.withLock { setupDoneMetadataValue } }
    set { lock.withLock { setupDoneMetadataValue = newValue } }
  }
  var setupDoneSymlink: Bool {
    get { lock.withLock { setupDoneSymlinkValue } }
    set { lock.withLock { setupDoneSymlinkValue = newValue } }
  }
  var setupDoneRegularFile: Bool {
    get { lock.withLock { setupDoneRegularFileValue } }
    set { lock.withLock { setupDoneRegularFileValue = newValue } }
  }
  var diagnosticsPresent: Bool {
    get { lock.withLock { diagnosticsPresentValue } }
    set { lock.withLock { diagnosticsPresentValue = newValue } }
  }
  var diagnosticsMetadata: String {
    get { lock.withLock { diagnosticsMetadataValue } }
    set { lock.withLock { diagnosticsMetadataValue = newValue } }
  }
  var diagnosticsSymlink: Bool {
    get { lock.withLock { diagnosticsSymlinkValue } }
    set { lock.withLock { diagnosticsSymlinkValue = newValue } }
  }
  var diagnosticsRegularFile: Bool {
    get { lock.withLock { diagnosticsRegularFileValue } }
    set { lock.withLock { diagnosticsRegularFileValue = newValue } }
  }
  var termsPresent: Bool {
    get { lock.withLock { termsPresentValue } }
    set { lock.withLock { termsPresentValue = newValue } }
  }
  var termsMetadata: String {
    get { lock.withLock { termsMetadataValue } }
    set { lock.withLock { termsMetadataValue = newValue } }
  }
  var termsSymlink: Bool {
    get { lock.withLock { termsSymlinkValue } }
    set { lock.withLock { termsSymlinkValue = newValue } }
  }
  var termsRegularFile: Bool {
    get { lock.withLock { termsRegularFileValue } }
    set { lock.withLock { termsRegularFileValue = newValue } }
  }
  var completionInstallExit: Int32 {
    get { lock.withLock { completionInstallExitValue } }
    set { lock.withLock { completionInstallExitValue = newValue } }
  }
  var completionRemoveExit: Int32 {
    get { lock.withLock { completionRemoveExitValue } }
    set { lock.withLock { completionRemoveExitValue = newValue } }
  }
  var completionSyncExit: Int32 {
    get { lock.withLock { completionSyncExitValue } }
    set { lock.withLock { completionSyncExitValue = newValue } }
  }
  var fileVaultEnabled: Bool {
    get { lock.withLock { fileVaultEnabledValue } }
    set { lock.withLock { fileVaultEnabledValue = newValue } }
  }
  var includeHiddenNormalUser: Bool {
    get { lock.withLock { includeHiddenNormalUserValue } }
    set { lock.withLock { includeHiddenNormalUserValue = newValue } }
  }
  var invalidNegativeUID: Bool {
    get { lock.withLock { invalidNegativeUIDValue } }
    set { lock.withLock { invalidNegativeUIDValue = newValue } }
  }
  var includeCustomLowUser: Bool {
    get { lock.withLock { includeCustomLowUserValue } }
    set { lock.withLock { includeCustomLowUserValue = newValue } }
  }
  var customLowUsesStockGeneratedUID: Bool {
    get { lock.withLock { customLowUsesStockGeneratedUIDValue } }
    set { lock.withLock { customLowUsesStockGeneratedUIDValue = newValue } }
  }
  var includeDeterministicHighUIDUser: Bool {
    get { lock.withLock { includeDeterministicHighUIDUserValue } }
    set { lock.withLock { includeDeterministicHighUIDUserValue = newValue } }
  }
  var duplicateLocalRecord: Bool {
    get { lock.withLock { duplicateLocalRecordValue } }
    set { lock.withLock { duplicateLocalRecordValue = newValue } }
  }
  var apfsOutput: String? {
    get { lock.withLock { apfsOutputValue } }
    set { lock.withLock { apfsOutputValue = newValue } }
  }
  var apfsOutputSequence: [String] {
    get { lock.withLock { apfsOutputSequenceValue } }
    set { lock.withLock { apfsOutputSequenceValue = newValue } }
  }
  var managedPreferencesPresent: Bool {
    get { lock.withLock { managedPreferencesPresentValue } }
    set {
      lock.withLock {
        managedPreferencesPresentValue = newValue
        managedPreferencesPathStateValue = newValue ? .directory : .absent
      }
    }
  }
  var managedPreferencesPathState: ManagedPreferencesPathState {
    get { lock.withLock { managedPreferencesPathStateValue } }
    set {
      lock.withLock {
        managedPreferencesPathStateValue = newValue
        managedPreferencesPresentValue = newValue == .directory
      }
    }
  }
  var managedPreferencesFindExit: Int32 {
    get { lock.withLock { managedPreferencesFindExitValue } }
    set { lock.withLock { managedPreferencesFindExitValue = newValue } }
  }
  var ownerConfigurationProfiles: String {
    get { lock.withLock { ownerConfigurationProfilesValue } }
    set { lock.withLock { ownerConfigurationProfilesValue = newValue } }
  }
  var customHome: String? {
    get { lock.withLock { customHomeValue } }
    set { lock.withLock { customHomeValue = newValue } }
  }
  var kcpasswordPresent: Bool {
    get { lock.withLock { kcpasswordPresentValue } }
    set { lock.withLock { kcpasswordPresentValue = newValue } }
  }
  var autoLoginStatusOutput: String {
    get { lock.withLock { autoLoginStatusOutputValue } }
    set { lock.withLock { autoLoginStatusOutputValue = newValue } }
  }
  var autoLoginStatusExit: Int32 {
    get { lock.withLock { autoLoginStatusExitValue } }
    set { lock.withLock { autoLoginStatusExitValue = newValue } }
  }
  var autoLoginPTYStatus: Int32 {
    get { lock.withLock { autoLoginPTYStatusValue } }
    set { lock.withLock { autoLoginPTYStatusValue = newValue } }
  }

  var autoLoginPTYUpdatesStatus: Bool {
    get { lock.withLock { autoLoginPTYUpdatesStatusValue } }
    set { lock.withLock { autoLoginPTYUpdatesStatusValue = newValue } }
  }
  var autoLoginRefusal: PommeSecurityOwnerAutologinRefusal? {
    get { lock.withLock { autoLoginRefusalValue } }
    set { lock.withLock { autoLoginRefusalValue = newValue } }
  }

  var nativeBuildVersion: String {
    get { lock.withLock { nativeBuildVersionValue } }
    set { lock.withLock { nativeBuildVersionValue = newValue } }
  }
  var nativeBuildExit: Int32 {
    get { lock.withLock { nativeBuildExitValue } }
    set { lock.withLock { nativeBuildExitValue = newValue } }
  }
  var setupAssistantBuildPreference: String? {
    get { lock.withLock { setupAssistantBuildPreferenceValue } }
    set { lock.withLock { setupAssistantBuildPreferenceValue = newValue } }
  }
  var setupAssistantBuildReadTypeOutput: String? {
    get { lock.withLock { setupAssistantBuildReadTypeOutputValue } }
    set { lock.withLock { setupAssistantBuildReadTypeOutputValue = newValue } }
  }
  var setupAssistantBuildReadOutput: String? {
    get { lock.withLock { setupAssistantBuildReadOutputValue } }
    set { lock.withLock { setupAssistantBuildReadOutputValue = newValue } }
  }
  var miniBuddyLaunchPreference: Bool? {
    get { lock.withLock { miniBuddyLaunchPreferenceValue } }
    set { lock.withLock { miniBuddyLaunchPreferenceValue = newValue } }
  }
  var miniBuddyLaunchReadTypeOutput: String? {
    get { lock.withLock { miniBuddyLaunchReadTypeOutputValue } }
    set { lock.withLock { miniBuddyLaunchReadTypeOutputValue = newValue } }
  }
  var miniBuddyLaunchReadOutput: String? {
    get { lock.withLock { miniBuddyLaunchReadOutputValue } }
    set { lock.withLock { miniBuddyLaunchReadOutputValue = newValue } }
  }
  var setupAssistantBuildWriteExit: Int32 {
    get { lock.withLock { setupAssistantBuildWriteExitValue } }
    set { lock.withLock { setupAssistantBuildWriteExitValue = newValue } }
  }
  var miniBuddyLaunchWriteExit: Int32 {
    get { lock.withLock { miniBuddyLaunchWriteExitValue } }
    set { lock.withLock { miniBuddyLaunchWriteExitValue = newValue } }
  }
  var ownerSetupAssistantProcessPresent: Bool {
    get { lock.withLock { ownerSetupAssistantProcessPresentValue } }
    set { lock.withLock { ownerSetupAssistantProcessPresentValue = newValue } }
  }
  var ownerSetupAssistantProcessUID: UInt32 {
    get { lock.withLock { ownerSetupAssistantProcessUIDValue } }
    set { lock.withLock { ownerSetupAssistantProcessUIDValue = newValue } }
  }
  var ownerSetupAssistantProcessPID: Int32 {
    get { lock.withLock { ownerSetupAssistantProcessPIDValue } }
    set { lock.withLock { ownerSetupAssistantProcessPIDValue = newValue } }
  }
  var ownerSetupAssistantProcessStartIdentity: String {
    get { lock.withLock { ownerSetupAssistantProcessStartIdentityValue } }
    set { lock.withLock { ownerSetupAssistantProcessStartIdentityValue = newValue } }
  }
  var ownerSetupAssistantProcessPath: String {
    get { lock.withLock { ownerSetupAssistantProcessPathValue } }
    set { lock.withLock { ownerSetupAssistantProcessPathValue = newValue } }
  }
  var ownerSetupAssistantKillExit: Int32 {
    get { lock.withLock { ownerSetupAssistantKillExitValue } }
    set { lock.withLock { ownerSetupAssistantKillExitValue = newValue } }
  }
  var ownerSetupAssistantExitsAfterKill: Bool {
    get { lock.withLock { ownerSetupAssistantExitsAfterKillValue } }
    set { lock.withLock { ownerSetupAssistantExitsAfterKillValue = newValue } }
  }
  var driftOwnerPreferencesAfterKill: Bool {
    get { lock.withLock { driftOwnerPreferencesAfterKillValue } }
    set { lock.withLock { driftOwnerPreferencesAfterKillValue = newValue } }
  }
  var missingDefaultsDiagnosticEmpty: Bool {
    get { lock.withLock { missingDefaultsDiagnosticEmptyValue } }
    set { lock.withLock { missingDefaultsDiagnosticEmptyValue = newValue } }
  }

  var setupAssistantProcessUID: UInt32 {
    get { lock.withLock { setupAssistantProcessUIDValue } }
    set { lock.withLock { setupAssistantProcessUIDValue = newValue } }
  }

  var setupAssistantManagerName: String {
    get { lock.withLock { setupAssistantManagerNameValue } }
    set { lock.withLock { setupAssistantManagerNameValue = newValue } }
  }

  var setupAssistantProcessPath: String {
    get { lock.withLock { setupAssistantProcessPathValue } }
    set { lock.withLock { setupAssistantProcessPathValue = newValue } }
  }

  var setupAssistantDuplicateProcess: Bool {
    get { lock.withLock { setupAssistantDuplicateProcessValue } }
    set { lock.withLock { setupAssistantDuplicateProcessValue = newValue } }
  }

  var setupAssistantStaleRecheck: Bool {
    get { lock.withLock { setupAssistantStaleRecheckValue } }
    set { lock.withLock { setupAssistantStaleRecheckValue = newValue } }
  }

  var setupAssistantManagerUID: String {
    get { lock.withLock { setupAssistantManagerUIDValue } }
    set { lock.withLock { setupAssistantManagerUIDValue = newValue } }
  }

  var setupAssistantCallerUID: String {
    get { lock.withLock { setupAssistantCallerUIDValue } }
    set { lock.withLock { setupAssistantCallerUIDValue = newValue } }
  }

  var setupAssistantAuditSessionID: UInt64 {
    get { lock.withLock { setupAssistantAuditSessionIDValue } }
    set { lock.withLock { setupAssistantAuditSessionIDValue = newValue } }
  }

  var useLanguageChooser: Bool {
    get { lock.withLock { useLanguageChooserValue } }
    set { lock.withLock { useLanguageChooserValue = newValue } }
  }

  var duplicateLaunchdHandle: Bool {
    get { lock.withLock { duplicateLaunchdHandleValue } }
    set { lock.withLock { duplicateLaunchdHandleValue = newValue } }
  }

  var nestedLaunchdHandle: Bool {
    get { lock.withLock { nestedLaunchdHandleValue } }
    set { lock.withLock { nestedLaunchdHandleValue = newValue } }
  }

  func markCreated() { lock.withLock { createdValue = true } }

  private func testPath(_ arguments: [String]) -> (Int32, String) {
    guard arguments.count == 2,
      let operation = arguments.first,
      let path = arguments.last,
      ["-L", "-e", "-d"].contains(operation)
    else { return (2, "") }

    if path == "/Users" {
      return operation == "-L" ? (1, "") : (0, "")
    }
    if path == "/Users/pomme/Library/Managed Preferences" {
      return (1, "")
    }
    guard path == "/Library/Managed Preferences" else { return (2, "") }

    let state = managedPreferencesPathState
    switch state {
    case .absent:
      return (1, "")
    case .directory:
      return operation == "-L" ? (1, "") : (0, "")
    case .symlink:
      return operation == "-L" ? (0, "") : (0, "")
    case .nonDirectory:
      return operation == "-L" ? (1, "") : operation == "-e" ? (0, "") : (1, "")
    case .unreadable:
      return (2, "")
    }
  }

  private func markerTest(_ arguments: [String]) -> (Int32, String)? {
    guard arguments.count == 2,
      let operation = arguments.first,
      let path = arguments.last,
      [
        "/var/db/.AppleSetupDone", "/var/db/.AppleDiagnosticsSetupDone",
        "/var/db/.AppleSetupTermsOfService",
      ].contains(path)
    else { return nil }

    let symlink: Bool
    let exists: Bool
    let regular: Bool
    switch path {
    case "/var/db/.AppleSetupDone":
      symlink = setupDoneSymlink
      exists = setupDone
      regular = setupDoneRegularFile
    case "/var/db/.AppleDiagnosticsSetupDone":
      symlink = diagnosticsSymlink
      exists = diagnosticsPresent
      regular = diagnosticsRegularFile
    default:
      symlink = termsSymlink
      exists = termsPresent
      regular = termsRegularFile
    }

    switch operation {
    case "-L": return (symlink ? 0 : 1, "")
    case "-e": return (exists ? 0 : 1, "")
    case "-f": return (exists && regular ? 0 : 1, "")
    default: return (2, "")
    }
  }

  private func missingDefaultsDiagnostic(domain: String, key: String) -> String {
    if missingDefaultsDiagnosticEmpty { return "" }
    return
      "2026-09-05 14:08:43.780 defaults[335:2142] \nThe domain/default pair of (\(domain), \(key)) does not exist\n"
  }

  func buddyStatus() -> PommeBuddyPreferencesStatus? {
    .init(bootSessionUUID: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB", productVersion: "26.6.2",
      buildVersion: "25G83", owner: .init(account: "pomme", uid: 501,
      generatedUID: generatedUID.uuidString, homeDirectory: "/Users/pomme"),
      stage: "complete", outcome: "succeeded", error: nil)
  }

  func execute(_ request: GuestCommandRequest) throws -> GuestCommandResult {
    lock.withLock {
      guestPathsValue.append(request.path)
      guestArgumentsValue.append(request.arguments)
    }
    let response: (Int32, String)
    if request.path == "/bin/test", let markerResponse = markerTest(request.arguments) {
      response = markerResponse
    } else if request.path == "/bin/test", request.arguments == ["-f", "/etc/kcpassword"] {
      response = (kcpasswordPresent ? 0 : 1, "")
    } else if request.path == "/bin/test" {
      response = testPath(request.arguments)
    } else if request.path == "/usr/bin/find" {
      if request.arguments.first == "/Library/Managed Preferences",
        managedPreferencesPathState == .directory
      {
        response = (
          managedPreferencesFindExit,
          managedPreferencesFindExit == 0
            ? "/Library/Managed Preferences/com.apple.loginwindow.plist\n" : ""
        )
      } else {
        response = (0, "")
      }
    } else if request.path == "/usr/sbin/sysctl", request.arguments == ["-n", "kern.bootsessionuuid"] {
      response = (0, "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB\n")
    } else if request.path == "/usr/bin/sw_vers", request.arguments == ["-productVersion"] {
      response = (0, "26.6.2\n")
    } else if request.path == "/usr/bin/sw_vers", request.arguments == ["-buildVersion"] {
      response = (nativeBuildExit, nativeBuildVersion + "\n")
    } else if request.path == "/usr/bin/sudo",
      request.arguments.count >= 5,
      Array(request.arguments.prefix(4)) == ["-n", "-H", "-u", "pomme"],
      request.arguments[4] == "/usr/bin/defaults"
    {
      let defaultsArguments = Array(request.arguments.dropFirst(5))
      if defaultsArguments.count == 3, defaultsArguments[0] == "read-type" {
        let domain = defaultsArguments[1]
        let key = defaultsArguments[2]
        switch (domain, key) {
        case ("com.apple.SetupAssistant", "LastSeenBuddyBuildVersion"):
          if setupAssistantBuildPreference != nil {
            response = (0, setupAssistantBuildReadTypeOutput ?? "Type is string\n")
          } else {
            response = (1, missingDefaultsDiagnostic(domain: domain, key: key))
          }
        case ("com.apple.loginwindow", "MiniBuddyLaunch"):
          if miniBuddyLaunchPreference != nil {
            response = (0, miniBuddyLaunchReadTypeOutput ?? "Type is boolean\n")
          } else {
            response = (1, missingDefaultsDiagnostic(domain: domain, key: key))
          }
        default:
          response = (2, "")
        }
      } else if defaultsArguments.count == 3, defaultsArguments[0] == "read" {
        let domain = defaultsArguments[1]
        let key = defaultsArguments[2]
        switch (domain, key) {
        case ("com.apple.SetupAssistant", "LastSeenBuddyBuildVersion"):
          if let value = setupAssistantBuildPreference {
            response = (0, setupAssistantBuildReadOutput ?? value + "\n")
          } else {
            response = (1, missingDefaultsDiagnostic(domain: domain, key: key))
          }
        case ("com.apple.loginwindow", "MiniBuddyLaunch"):
          if let value = miniBuddyLaunchPreference {
            response = (0, miniBuddyLaunchReadOutput ?? (value ? "1\n" : "0\n"))
          } else {
            response = (1, missingDefaultsDiagnostic(domain: domain, key: key))
          }
        default:
          response = (2, "")
        }
      } else if defaultsArguments.count == 5,
        defaultsArguments[0] == "write",
        defaultsArguments[3] == "-string"
      {
        let domain = defaultsArguments[1]
        let key = defaultsArguments[2]
        let value = defaultsArguments[4]
        switch (domain, key) {
        case ("com.apple.SetupAssistant", "LastSeenBuddyBuildVersion"):
          response = (setupAssistantBuildWriteExit, "")
          if setupAssistantBuildWriteExit == 0,
            value.range(of: "^[A-Za-z0-9]{1,32}$", options: .regularExpression) != nil
          {
            lock.withLock {
              setupAssistantBuildPreferenceValue = value
              setupAssistantBuildReadOutputValue = nil
            }
          }
        default:
          response = (2, "")
        }
      } else if defaultsArguments.count == 5,
        defaultsArguments[0] == "write",
        defaultsArguments[1] == "com.apple.loginwindow",
        defaultsArguments[2] == "MiniBuddyLaunch",
        defaultsArguments[3] == "-bool"
      {
        response = (miniBuddyLaunchWriteExit, "")
        if miniBuddyLaunchWriteExit == 0, defaultsArguments[4] == "false" {
          lock.withLock {
            miniBuddyLaunchPreferenceValue = false
            miniBuddyLaunchReadOutputValue = nil
          }
        }
      } else {
        response = (2, "")
      }
    } else if request.path == "/bin/kill", request.arguments.count == 2,
      request.arguments[0] == "-TERM",
      let processID = Int32(request.arguments[1]),
      processID == ownerSetupAssistantProcessPID
    {
      response = (ownerSetupAssistantKillExit, "")
      if ownerSetupAssistantKillExit == 0, ownerSetupAssistantExitsAfterKill {
        lock.withLock {
          ownerSetupAssistantProcessPresentValue = false
          if driftOwnerPreferencesAfterKillValue {
            setupAssistantBuildReadOutputValue = "26G99\n"
            miniBuddyLaunchReadOutputValue = "1\n"
          }
        }
      }
    } else if request.path == "/bin/ps" {
      let line = currentProcessLine
      if request.arguments == ["-axo", "pid=,uid=,lstart=,comm="] {
        let duplicate = setupAssistantDuplicateProcess ? line + line : line
        let owner = ownerSetupAssistantProcessPresent ? ownerSetupAssistantProcessLine : ""
        response = (0, relativeBackgroundProcessLine + duplicate + owner)
      } else if request.arguments == [
        "-p", String(languageChooserProcessPIDValue), "-o", "pid=,uid=,lstart=,comm=",
      ], useLanguageChooser && !languageHandoffCompleted {
        response = (0, languageChooserProcessLine)
      } else if request.arguments == [
        "-p", String(ownerSetupAssistantProcessPIDValue), "-o", "pid=,uid=,lstart=,comm=",
      ], ownerSetupAssistantProcessPresent {
        response = (0, ownerSetupAssistantProcessLine)
      } else if request.arguments == [
        "-p", String(setupAssistantProcessPIDValue), "-o", "pid=,uid=,lstart=,comm=",
      ], !useLanguageChooser || languageHandoffCompleted {
        let recheckLine =
          setupAssistantStaleRecheck
          ? setupAssistantProcessLine(startIdentity: "Sat Sep 5 14:00:01 2026")
          : line
        response = (0, recheckLine)
      } else {
        response = (1, "")
      }
    } else if request.path == "/bin/launchctl" {
      if request.arguments == ["print", "gui/248"] {
        response = (0, setupAssistantGUIDomain)
      } else if request.arguments == ["print", "pid/\(setupAssistantProcessPIDValue)"] {
        response = (0, setupAssistantPIDDomain)
      } else if request.arguments == [
        "asuser", "248", "/bin/launchctl", "managername",
      ] {
        response = (0, setupAssistantManagerNameValue + "\n")
      } else if request.arguments == [
        "asuser", "248", "/bin/launchctl", "manageruid",
      ] {
        response = (0, setupAssistantManagerUIDValue + "\n")
      } else if request.arguments == [
        "asuser", "248", "/usr/bin/id", "-u",
      ] {
        response = (0, setupAssistantCallerUIDValue + "\n")
      } else {
        response = (1, "")
      }
    } else if request.path == "/usr/bin/profiles",
      request.arguments == ["status", "-type", "enrollment"]
    {
      response = (0, "Enrolled via DEP: No\nMDM enrollment: No\n")
    } else if request.path == "/usr/bin/profiles",
      request.arguments == ["list", "-type", "configuration"]
    {
      response = (0, "There are no configuration profiles installed in the system domain\n")
    } else if request.path == "/usr/bin/profiles",
      request.arguments == ["list", "-type", "configuration", "-user", "pomme"]
    {
      response = (0, ownerConfigurationProfiles)
    } else if request.path == "/usr/bin/profiles",
      request.arguments == ["status", "-type", "configuration"]
    {
      response = (0, "There are no configuration profiles installed on this system\n")
    } else if request.path == "/usr/sbin/languagesetup",
      request.arguments == ["-langspec", "en"]
    {
      response = (0, "System Language set to: en\n")
    } else if request.path == "/usr/bin/notifyutil",
      request.arguments == ["-p", "com.apple.lca.done"]
    {
      lock.withLock { languageHandoffCompletedValue = true }
      response = (0, "")
    } else if request.path == "/usr/bin/dscl",
      request.arguments == [".", "-list", "/Users", "UniqueID"]
    {
      let hidden = includeHiddenNormalUser ? "_hidden 550\n" : ""
      let nobody = invalidNegativeUID ? "nobody -3\n" : "nobody -2\n"
      let customLow = includeCustomLowUser ? "alice 499\n" : ""
      response = (
        0,
        created || includeDeterministicHighUIDUser
          ? "root 0\n_mbsetupuser 248\n\(nobody)\(customLow)\(hidden)pomme 501\n"
          : "root 0\n_mbsetupuser 248\n\(nobody)\(customLow)\(hidden)"
      )
    } else if request.path == "/usr/bin/dscl",
      request.arguments == [".", "-list", "/Users", "GeneratedUID"]
    {
      response = (0, generatedUIDList)
    } else if request.path == "/usr/bin/dscl" {
      if request.arguments.contains("/Users/_mbsetupuser") {
        response = (0, mbsetupLocalRecord)
      } else if request.arguments.contains("/Users/_hidden") {
        response = (0, hiddenLocalRecord)
      } else if request.arguments.contains("/Users/nobody") {
        response = (0, nobodyLocalRecord)
      } else if request.arguments.contains("/Users/alice") {
        response = (0, customLowLocalRecord)
      } else if duplicateLocalRecord {
        let record = localRecord.trimmingCharacters(in: .newlines)
        response = (0, record + "\nUniqueID: 501\n")
      } else {
        response = (0, localRecord)
      }
    } else if request.path == "/usr/sbin/diskutil",
      request.arguments == ["apfs", "listVolumeGroups", "-plist"]
    {
      response = (0, volumeGroupsPlist)
    } else if request.path == "/usr/sbin/diskutil", request.arguments == ["info", "-plist", "/"] {
      response = (0, rootInfoPlist)
    } else if request.path == "/usr/sbin/diskutil", request.arguments == ["apfs", "listUsers", "/"]
    {
      let output = lock.withLock {
        if !apfsOutputSequenceValue.isEmpty {
          return apfsOutputSequenceValue.removeFirst()
        }
        if let apfsOutputValue { return apfsOutputValue }
        return createdValue ? apfsUsers : "No cryptographic users for disk1s1\n"
      }
      response = (0, output)
    } else if request.path == "/usr/sbin/sysadminctl",
      request.arguments == ["-autologin", "status"]
    {
      response = (autoLoginStatusExit, autoLoginStatusOutput)
    } else if request.path == "/usr/sbin/sysadminctl",
      request.arguments.first == "-secureTokenStatus"
    {
      response = (0, "Secure token is ENABLED for user pomme\n")
    } else if request.path == "/usr/bin/dsmemberutil" {
      response = (0, "user pomme is a member of group admin\n")
    } else if request.path == "/usr/bin/id" {
      response = (0, "501\n")
    } else if request.path == "/usr/bin/fdesetup" {
      response = (0, fileVaultEnabled ? "FileVault is On.\n" : "FileVault is Off.\n")
    } else if request.path == "/usr/bin/defaults",
      request.arguments == [
        "read", "/Library/Preferences/.GlobalPreferences", "AppleLanguages",
      ]
    {
      response = (0, "(\n    en\n)\n")
    } else if request.path == "/usr/bin/defaults",
      request.arguments == ["read", "/Library/Preferences/com.apple.loginwindow"]
    {
      response = (0, "DisableFDEAutoLogin = 0;\n")
    } else if request.path == "/usr/bin/defaults", request.arguments.last == "autoLoginUser" {
      response = (0, autoLoginUserOutputValue)
    } else if request.path == "/usr/sbin/sysadminctl", request.arguments == ["-help"] {
      response = (
        0,
        "-adminUser administrator -adminPassword - -autologin set -userName username -password -\n"
      )
    } else if request.path == "/usr/bin/install",
      request.arguments.count == 9,
      Array(request.arguments.dropLast()) == [
        "-S", "-m", "0400", "-o", "root", "-g", "wheel", "/dev/null",
      ],
      let path = request.arguments.last,
      ["/var/db/.AppleSetupDone", "/var/db/.AppleDiagnosticsSetupDone"].contains(path)
    {
      response = (completionInstallExit, "")
      if completionInstallExit == 0 {
        lock.withLock {
          if path == "/var/db/.AppleSetupDone" {
            setupDoneValue = true
            setupDoneMetadataValue = "0:0:400:0"
          } else {
            diagnosticsPresentValue = true
            diagnosticsMetadataValue = "0:0:400:0"
          }
        }
      }
    } else if request.path == "/bin/rm",
      request.arguments == ["-f", "/var/db/.AppleSetupTermsOfService"]
    {
      response = (completionRemoveExit, "")
      if completionRemoveExit == 0 {
        lock.withLock { termsPresentValue = false }
      }
    } else if request.path == "/bin/sync" {
      response = (completionSyncExit, "")
    } else if request.path == "/usr/bin/stat",
      request.arguments == ["-f", "%Su:%u", "/dev/console"]
    {
      let console =
        useLanguageChooser && !languageHandoffCompleted
        ? "_windowserver:88\n" : "_mbsetupuser:248\n"
      response = (0, console)
    } else if request.path == "/usr/bin/stat",
      request.arguments.count == 3,
      request.arguments[0] == "-f",
      request.arguments[1] == "%u:%g:%Lp:%z",
      let path = request.arguments.last
    {
      switch path {
      case "/var/db/.AppleSetupDone":
        response = (0, setupDoneMetadataValue)
      case "/var/db/.AppleDiagnosticsSetupDone":
        response = (0, diagnosticsMetadataValue)
      case "/var/db/.AppleSetupTermsOfService":
        response = (0, termsMetadataValue)
      default:
        response = (1, "")
      }
    } else if request.path == "/usr/bin/stat",
      request.arguments == ["-f", "%u:%HT", "/Users/pomme"]
    {
      response = (0, "501:Directory\n")
    } else if request.path == "/usr/bin/stat" {
      response = (0, autoLoginArtifactMetadataValue)
    } else {
      throw PommeSecurityOwnerPreparationError.evidenceUnavailable(.localUsers)
    }
    let nativeDiagnosticOnStderr =
      request.path == "/usr/sbin/sysadminctl"
      && (request.arguments.first == "-secureTokenStatus"
        || request.arguments == ["-help"]
        || request.arguments == ["-autologin", "status"])
    let defaultsMissingDiagnosticOnStderr =
      request.path == "/usr/bin/sudo"
      && request.arguments.contains("/usr/bin/defaults")
      && response.0 == 1
    let stdout = nativeDiagnosticOnStderr || defaultsMissingDiagnosticOnStderr ? "" : response.1
    let stderr = nativeDiagnosticOnStderr || defaultsMissingDiagnosticOnStderr ? response.1 : ""
    return GuestCommandResult(
      exitCode: Int(response.0),
      signal: nil,
      stdout: Data(stdout.utf8),
      stderr: Data(stderr.utf8),
      stdoutTruncated: false,
      stderrTruncated: false,
      exited: true
    )
  }

  func executePTY(_ command: PommeSecurityOwnerPTYCommand, _: String) async throws -> Int32 {
    let (status, refusal) = lock.withLock {
      commandsValue.append(command)
      if command.arguments.first == "-addUser" {
        createdValue = true
      }
      return (
        command.arguments.contains("-autologin") ? autoLoginPTYStatusValue : 0,
        autoLoginRefusalValue
      )
    }
    if command.arguments.contains("-autologin"), let refusal {
      throw PommeSecurityOwnerPreparationError.autoLoginRefused(refusal)
    }
    if command.arguments.contains("-autologin"), status == 0, autoLoginPTYUpdatesStatus {
      lock.withLock {
        autoLoginStatusOutputValue = "Automatic login user: pomme\n"
      }
    }
    return status
  }

  private var created: Bool { lock.withLock { createdValue } }

  private var languageHandoffCompleted: Bool {
    lock.withLock { languageHandoffCompletedValue }
  }

  private var localRecord: String {
    """
    RecordName: pomme
    RealName: Pomme
    GeneratedUID: \(normalUserGeneratedUID)
    UniqueID: 501
    NFSHomeDirectory: \(customHome ?? "/Users/pomme")
    """
  }

  private var normalUserGeneratedUID: String {
    includeDeterministicHighUIDUser
      ? "FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F5"
      : generatedUID.uuidString
  }

  private var setupAssistantProcessLine: String {
    setupAssistantProcessLine(startIdentity: setupAssistantStartIdentityValue)
  }

  private var ownerSetupAssistantProcessLine: String {
    "\(ownerSetupAssistantProcessPIDValue) \(ownerSetupAssistantProcessUIDValue) \(ownerSetupAssistantProcessStartIdentityValue) \(ownerSetupAssistantProcessPathValue)\n"
  }

  private var currentProcessLine: String {
    useLanguageChooser && !languageHandoffCompleted
      ? languageChooserProcessLine : setupAssistantProcessLine
  }

  private var languageChooserProcessLine: String {
    "\(languageChooserProcessPIDValue) 0 Sat Sep 5 14:00:00 2026 /System/Library/CoreServices/Language Chooser.app/Contents/MacOS/Language Chooser\n"
  }

  private var relativeBackgroundProcessLine: String {
    "88 0 Sat Sep 5 14:00:00 2026 endpointsecurityd\n"
  }

  private func setupAssistantProcessLine(startIdentity: String) -> String {
    "\(setupAssistantProcessPIDValue) \(setupAssistantProcessUIDValue) \(startIdentity) \(setupAssistantProcessPathValue)\n"
  }

  private var setupAssistantGUIDomain: String {
    let duplicateHandle = duplicateLaunchdHandle ? "\n\thandle = 100004" : ""
    let nestedHandle = nestedLaunchdHandle ? "\n\t\thandle = 100004" : ""
    return """
      gui/248 = {
       type = login
       handle = 100003
      \(duplicateHandle)
       session = Aqua
       security context = {
           uid = 248
           asid = \(setupAssistantAuditSessionIDValue)
      \(nestedHandle)
       }
      }
      """
  }

  private var setupAssistantPIDDomain: String {
    """
    pid/\(setupAssistantProcessPIDValue) = {
    	type = pid
    	handle = \(setupAssistantProcessPIDValue)
    	originator = /System/Library/CoreServices/Setup Assistant.app
    	creator euid = \(setupAssistantProcessUIDValue)
    	uniqueid = \(setupAssistantProcessPIDValue)
    	security context = {
    		uid = \(setupAssistantProcessUIDValue)
    		asid = \(setupAssistantAuditSessionIDValue)
    	}
    }
    """
  }

  private var mbsetupLocalRecord: String {
    """
    RecordName: _mbsetupuser
    RealName: Setup User
    GeneratedUID: FFFFEEEE-DDDD-CCCC-BBBB-AAAA000000F8
    UniqueID: 248
    NFSHomeDirectory: /var/setup
    """
  }

  private var hiddenLocalRecord: String {
    """
    RecordName: _hidden
    RealName: Hidden Service
    GeneratedUID: 88888888-7777-6666-5555-444444444444
    UniqueID: 550
    NFSHomeDirectory: /var/empty
    """
  }

  private var nobodyLocalRecord: String {
    """
    RecordName: nobody
    RealName: Nobody
    GeneratedUID: FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
    UniqueID: -2
    NFSHomeDirectory: /var/empty
    """
  }

  private var customLowLocalRecord: String {
    """
    RecordName: alice
    RealName: Alice
    GeneratedUID: \(customLowGeneratedUID)
    UniqueID: 499
    NFSHomeDirectory: /var/empty
    """
  }

  private var customLowGeneratedUID: String {
    customLowUsesStockGeneratedUID
      ? "FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F3"
      : "66666666-5555-4444-3333-222222222222"
  }

  private var generatedUIDList: String {
    var lines = [
      "root FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000",
      "_mbsetupuser FFFFEEEE-DDDD-CCCC-BBBB-AAAA000000F8",
      "nobody FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE",
    ]
    if includeCustomLowUser {
      lines.append("alice \(customLowGeneratedUID)")
    }
    if includeHiddenNormalUser {
      lines.append("_hidden 88888888-7777-6666-5555-444444444444")
    }
    if created || includeDeterministicHighUIDUser {
      lines.append("pomme \(normalUserGeneratedUID)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private var volumeGroupsPlist: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>Containers</key><array><dict><key>VolumeGroups</key><array><dict>
    <key>APFSVolumeGroupUUID</key><string>\(volumeGroupUUID.uuidString)</string>
    <key>Volumes</key><array>
    <dict><key>Role</key><string>System</string><key>DeviceIdentifier</key><string>disk1s1</string></dict>
    <dict><key>Role</key><string>Data</string><key>DeviceIdentifier</key><string>disk1s5</string></dict>
    </array></dict></array></dict></array></dict></plist>
    """
  }

  private var rootInfoPlist: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>APFSVolumeGroupID</key><string>\(volumeGroupUUID.uuidString)</string>
    <key>VolumeUUID</key><string>\(rootVolumeUUID.uuidString)</string>
    <key>DeviceIdentifier</key><string>disk1s1</string>
    <key>FilesystemType</key><string>apfs</string>
    <key>MountPoint</key><string>/</string>
    </dict></plist>
    """
  }

  var apfsUsers: String {
    """
    Cryptographic user for disk1s1 (1 found)
    +-- \(generatedUID.uuidString)
        Type: Local Open Directory User
        Volume Owner: Yes
    """
  }

  var pipePrefixedAPFSUsers: String {
    """
    Cryptographic users for disk1s1 (2 found)
    +-- \(generatedUID.uuidString)
    |   Type: Local Open Directory User
    |   Volume Owner: Yes
    +-- 44444444-3333-2222-1111-000000000000
        Type: Recovery User
        Volume Owner: No
    """
  }

  var residualAPFSUser: String {
    """
    Cryptographic user for disk1s1 (1 found)
    +-- 44444444-3333-2222-1111-000000000000
        Type: Recovery User
        Volume Owner: No
    """
  }

  var ambiguousAPFSUsersPlist: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Users</key><array></array>
    <key>OtherUsers</key><array><dict>
    <key>GeneratedUID</key><string>99999999-8888-7777-6666-555555555555</string>
    <key>Type</key><string>Local Open Directory User</string>
    </dict></array>
    </dict></plist>
    """
  }
}

private final class FrameworkOwnerProofFixture: @unchecked Sendable {
  static let password = "framework-private-password-never-rendered"
  let base = OwnerPreparationFixture(existingOwner: true)
  let failure: String
  private let lock = NSLock()
  private var commands: [PommeSecurityOwnerPTYCommand] = []

  init(failure: String = "") {
    self.failure = failure
  }

  var preparation: PommeSecurityOwnerPreparation {
    .init(
      identity: .init(
        expectedVolumeGroupUUID: failure == "volumeGroup" ? UUID() : base.volumeGroupUUID),
      executeGuest: execute,
      executePrivatePTY: authenticate
    )
  }

  func authenticate(_ command: PommeSecurityOwnerPTYCommand, _ password: String) async throws -> Int32 {
    lock.withLock { commands.append(command) }
    #expect(password == Self.password)
    #expect(command == .init(executable: "/usr/bin/dscl", arguments: [".", "-authonly", "pomme"]))
    if failure == "ptyError" { throw NSError(domain: Self.password, code: 1) }
    return failure == "password" ? 1 : 0
  }

  func execute(_ request: GuestCommandRequest) throws -> GuestCommandResult {
    lock.withLock { commands.append(.init(executable: request.path, arguments: request.arguments)) }
    if failure == "executorError" {
      throw NSError(domain: Self.password, code: 1)
    }
    var output: String?
    var exitCode = 0
    switch (request.path, request.arguments) {
    case ("/usr/bin/dsmemberutil", _) where failure == "admin":
      output = "user pomme is not a member of group admin\n"
    case ("/usr/sbin/sysadminctl", ["-secureTokenStatus", "pomme"]) where failure == "token":
      output = "Secure token is DISABLED for user pomme\n"
    case ("/usr/sbin/sysadminctl", ["-secureTokenStatus", "pomme"]) where failure == "ambiguousToken":
      output = "Secure token is ENABLED for user pomme\nSecureToken is DISABLED for user pomme\n"
    case ("/usr/sbin/diskutil", ["apfs", "listUsers", "/"]) where failure == "apfs":
      output = base.apfsUsers.replacingOccurrences(of: "Volume Owner: Yes", with: "Volume Owner: No")
    case ("/usr/bin/id", ["-u", "pomme"]) where failure == "numericUID":
      output = "502\n"
    case ("/usr/bin/dscl", let arguments)
      where arguments.contains("/Users/pomme") && ["home", "fullName"].contains(failure):
      let original = try base.execute(request)
      output = String(decoding: original.stdout, as: UTF8.self)
        .replacingOccurrences(of: failure == "home" ? "/Users/pomme" : "RealName: Pomme", with: "wrong")
    case ("/usr/sbin/sysadminctl", ["-autologin", "status"]) where failure == "autologin":
      output = "Automatic login is off.\n"
    case ("/usr/bin/defaults", let arguments) where arguments.last == "autoLoginUser" && failure == "preference":
      output = "someoneelse\n"
    case ("/usr/bin/stat", ["-f", "%u:%g:%p:%l", "/etc/kcpassword"]):
      output = [
        "artifactOwner": "501:0:100600:1", "artifactMode": "0:0:100644:1",
        "artifactGroup": "0:20:100600:1", "artifactReadOnly": "0:0:100400:1",
        "artifactSymlink": "0:0:120600:1", "artifactDirectory": "0:0:40600:1",
        "artifactLinks": "0:0:100600:2",
      ][failure] ?? "0:0:100600:1"
      if failure == "artifactMissing" { exitCode = 1 }
    case ("/usr/bin/stat", ["-f", "%Su:%u", "/dev/console"]):
      output = failure == "console" ? "root:0\n" : "pomme:501\n"
    default:
      return try base.execute(request)
    }
    return .init(
      exitCode: exitCode, signal: nil, stdout: Data((output ?? "").utf8), stderr: Data(),
      stdoutTruncated: false, stderrTruncated: false, exited: true
    )
  }

  func expectReadOnlyAndRedacted() {
    let recorded = lock.withLock { commands }
    for command in recorded {
      #expect(!String(describing: command).contains(Self.password))
      switch command.executable {
      case "/usr/bin/dscl":
        #expect(["-authonly", "-list", "-read"].contains(command.arguments[1]))
      case "/usr/sbin/sysadminctl":
        #expect(command.arguments == ["-secureTokenStatus", "pomme"]
          || command.arguments == ["-autologin", "status"])
      case "/usr/sbin/diskutil":
        #expect(["info", "apfs"].contains(command.arguments[0]))
        #expect(!command.arguments.contains("deleteUser"))
      case "/usr/bin/defaults":
        #expect(command.arguments.first == "read")
      default:
        #expect(["/bin/test", "/usr/bin/stat", "/usr/bin/id", "/usr/bin/dsmemberutil"].contains(command.executable))
      }
    }
  }
}
