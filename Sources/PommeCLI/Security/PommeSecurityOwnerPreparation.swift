import Foundation

/// Stable, redacted operation names used by the normal-guest owner boundary.
/// These values are safe to retain in the parent's durable phase journal.
enum PommeSecurityOwnerPreparationPhase: String, CaseIterable, Codable, Equatable, Sendable {
  case evidence
  case freshness
  case createOwner
  case verifyOwner
  case loginRestrictions
  case configureLogin
  case globalAutoLoginReadback
  case ownerCompletion
  case setupAssistantHandoff
  case finishSetupAssistant
}

enum PommeSecurityOwnerPreparationEvent: String, Codable, Equatable, Sendable {
  case intent
  case receipt
}

/// Guest commands used by this type are deliberately closed.  A PTY worker
/// receives one of these commands and a separate password value; passwords
/// are never included in this value or in a GuestCommandRequest.
struct PommeSecurityOwnerPTYCommand: Equatable, Sendable {
  let executable: String
  let arguments: [String]
}

enum PommeSecurityOwnerEvidenceKind: String, Equatable, Sendable {
  case setupAssistant
  case localUsers
  case localUserRecord
  case startupVolume
  case apfsUsers
  case secureToken
  case administratorMembership
  case accountIdentity
  case fileVault
  case loginWindow
  case autoLoginSupport
}

enum PommeSecurityOwnerCommandKind: String, Equatable, Sendable {
  case setupAssistant
  case listLocalUsers
  case readLocalUser
  case startupVolumeGroups
  case startupVolumeInfo
  case apfsUsers
  case secureToken
  case administratorMembership
  case accountID
  case createOwner
  case fileVault
  case loginWindow
  case managedLoginWindow
  case autoLoginSupport
  case autoLogin
  case ownerCompletion
  case finishSetupAssistant
}

/// Closed, redacted refusal reasons emitted by the native autologin command.
/// The classifier deliberately retains no native output and returns only one
/// of these stable values for the parent journal.
enum PommeSecurityOwnerAutologinRefusal: String, CaseIterable, Equatable, Sendable {
  case purchaseProtection
  case management
  case fileVault
  case preferenceCommit
  case authentication
  case requiresRootOrInteractive
  case sessionUnavailable

  var localizedDescription: String {
    switch self {
    case .purchaseProtection:
      return "Touch ID, Apple Pay, or App Store purchase protection is enabled"
    case .management:
      return "a system management policy disabled it"
    case .fileVault:
      return "FileVault is enabled"
    case .preferenceCommit:
      return "the login preferences could not be committed"
    case .authentication:
      return "native authorization failed"
    case .requiresRootOrInteractive:
      return "native root or interactive authorization was required"
    case .sessionUnavailable:
      return "the native SessionAgent for a GUI login session is unavailable"
    }
  }

  /// Classifies only exact native diagnostic lines. The observed sysadminctl
  /// timestamp/process prefix is accepted, while arbitrary surrounding text
  /// is rejected. Output is bounded before decoding so no unbounded PTY data
  /// can enter this helper.
  static func classify(_ output: Data) -> Self? {
    guard output.count <= 64 * 1024 else { return nil }
    let text = String(decoding: output, as: UTF8.self)
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      for refusal in allCases where refusal.matchesNativeLine(line) {
        return refusal
      }
    }
    return nil
  }

  private var nativeMarkers: [String] {
    switch self {
    case .purchaseProtection:
      [
        "Automatic login can not be set because because TouchID, Apple Pay or App Store purchases are enabled (use -force flag to override)"
      ]
    case .management:
      ["Automatic login is disabled by your system administrator."]
    case .fileVault:
      ["Automatic login is disabled because FileVault is enabled."]
    case .preferenceCommit:
      ["SystemConfiguration commitChanges failed."]
    case .authentication:
      ["Failed to authenticate with SystemAdministration framework."]
    case .requiresRootOrInteractive:
      ["sysadminctl should be run as root, or in interactive mode! (%@)"]
    case .sessionUnavailable:
      []  // Reported only by the process-bound native system-log diagnostic.
    }
  }

  private func matchesNativeLine(_ line: String) -> Bool {
    if nativeMarkers.contains(line) { return true }
    for marker in nativeMarkers where line.hasSuffix(" \(marker)") {
      let prefix = String(line.dropLast(marker.count + 1))
      if prefix.range(
        of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ sysadminctl\[\d+:\d+\]$"#,
        options: .regularExpression
      ) != nil {
        return true
      }
    }

    // The root/interactive diagnostic contains one native format argument.
    // Permit only the known autologin operation after native formatting; the
    // unformatted `%@` marker above remains useful for fixture/help output.
    guard self == .requiresRootOrInteractive,
      line.hasPrefix("sysadminctl should be run as root, or in interactive mode! ("),
      line.hasSuffix(")")
    else { return false }
    let prefix = "sysadminctl should be run as root, or in interactive mode! ("
    let argument = String(line.dropFirst(prefix.count).dropLast())
    return argument == "autologin" || argument == "-autologin"
  }
}

/// Errors intentionally contain only closed operation names and exit status.
/// In particular, command output and credential material are never embedded in
/// an error or forwarded to the parent journal.
enum PommeSecurityOwnerPreparationError: Error, LocalizedError, Equatable, Sendable {
  case invalidIdentity
  case credentialRequired
  case commandFailed(PommeSecurityOwnerCommandKind, exitCode: Int?)
  case malformedEvidence(PommeSecurityOwnerEvidenceKind)
  case evidenceUnavailable(PommeSecurityOwnerEvidenceKind)
  case freshnessRejected
  case accountCollision
  case retryIntentRequired
  case existingAccountNotExact
  case passwordVerificationFailed
  case ownerVerificationFailed
  case autoLoginVerificationFailed
  case autoLoginRefused(PommeSecurityOwnerAutologinRefusal)
  case loginRestricted
  case autoLoginUnsupported
  case setupAssistantContextUnavailable
  case ownerCompletionVerificationFailed
  case setupAssistantProcessCleanupFailed
  case privatePTYUnavailable
  case phaseCallbackFailed

  var errorDescription: String? {
    switch self {
    case .invalidIdentity:
      return "The normal guest owner identity is invalid."
    case .credentialRequired:
      return "The normal guest owner credential is required."
    case .commandFailed(let kind, let exitCode):
      let suffix = exitCode.map { " with status \($0)" } ?? ""
      return "The normal guest \(kind.rawValue) command failed\(suffix)."
    case .malformedEvidence(let kind):
      return "Normal guest \(kind.rawValue) evidence was malformed."
    case .evidenceUnavailable(let kind):
      return "Normal guest \(kind.rawValue) evidence was unavailable."
    case .freshnessRejected:
      return "The normal guest cannot be proven fresh for owner preparation."
    case .accountCollision:
      return "The normal guest owner account already exists."
    case .retryIntentRequired:
      return "Reusing an existing normal guest owner account requires explicit retry intent."
    case .existingAccountNotExact:
      return "The existing normal guest owner account is not the exact intended owner."
    case .passwordVerificationFailed:
      return "The normal guest owner password could not be verified."
    case .ownerVerificationFailed:
      return "The normal guest owner identity could not be verified."
    case .autoLoginVerificationFailed:
      return
        "The native normal guest automatic-login state could not be verified; Setup Assistant completion was not recorded."
    case .autoLoginRefused(let refusal):
      return
        "The native normal guest automatic-login step was refused because \(refusal.localizedDescription); the prepared owner remains for retry and security restrictions were not overridden."
    case .loginRestricted:
      return "Normal guest automatic login is restricted by the current security policy."
    case .autoLoginUnsupported:
      return "The native normal guest automatic-login command is unsupported."
    case .setupAssistantContextUnavailable:
      return "The native Setup Assistant Aqua session could not be verified."
    case .ownerCompletionVerificationFailed:
      return "The fresh normal guest owner completion state could not be verified."
    case .setupAssistantProcessCleanupFailed:
      return "The retained owner Setup Assistant process could not be closed safely."
    case .privatePTYUnavailable:
      return "The private normal guest PTY is unavailable."
    case .phaseCallbackFailed:
      return "The normal guest owner phase could not be durably recorded."
    }
  }
}

/// Immutable identity selected by the parent coordinator.  The default is the
/// purpose-built `pomme` administrator used by normal owner preparation.
struct PommeSecurityOwnerIdentity: Equatable, Sendable {
  let username: String
  let fullName: String
  let expectedVolumeGroupUUID: UUID?

  init(
    username: String = "pomme",
    fullName: String = "Pomme",
    expectedVolumeGroupUUID: UUID? = nil
  ) {
    self.username = username
    self.fullName = fullName
    self.expectedVolumeGroupUUID = expectedVolumeGroupUUID
  }

  func validate() throws {
    guard
      username.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil,
      !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !fullName.contains("\0"),
      !fullName.contains("\n"),
      !fullName.contains("\r")
    else { throw PommeSecurityOwnerPreparationError.invalidIdentity }
  }

  static let pomme = Self()
}

/// Host-side prerequisites supplied by the durable Pomme coordinator.  The
/// guest cannot establish either fact, so an omitted or false value fails
/// freshness closed.
struct PommeSecurityOwnerFreshnessRequirements: Equatable, Sendable {
  let creationOwnershipVerified: Bool
  let priorProvisioningAbsent: Bool
  let retryExistingAccount: Bool

  init(
    creationOwnershipVerified: Bool,
    priorProvisioningAbsent: Bool,
    retryExistingAccount: Bool = false
  ) {
    self.creationOwnershipVerified = creationOwnershipVerified
    self.priorProvisioningAbsent = priorProvisioningAbsent
    self.retryExistingAccount = retryExistingAccount
  }

  static let unverified = Self(
    creationOwnershipVerified: false,
    priorProvisioningAbsent: false
  )

  static let verifiedFresh = Self(
    creationOwnershipVerified: true,
    priorProvisioningAbsent: true
  )
}

struct PommeSecurityOwnerLocalUser: Equatable, Sendable {
  let recordName: String
  let realName: String
  let generatedUID: UUID
  let uniqueID: Int64
  let homeDirectory: String
  let isKnownSystemAccount: Bool

  init(
    recordName: String,
    realName: String,
    generatedUID: UUID,
    uniqueID: Int64,
    homeDirectory: String,
    isKnownSystemAccount: Bool = false
  ) {
    self.recordName = recordName
    self.realName = realName
    self.generatedUID = generatedUID
    self.uniqueID = uniqueID
    self.homeDirectory = homeDirectory
    self.isKnownSystemAccount = isKnownSystemAccount
  }

  /// Built-in records are marked only after their native GeneratedUID identity
  /// has been validated. Unknown records, including custom low-UID records,
  /// remain candidates so freshness cannot be claimed while one is present.
  var isNormalLocalUser: Bool {
    !isKnownSystemAccount
  }
}

struct PommeSecurityOwnerAPFSUser: Equatable, Sendable {
  enum Kind: String, Equatable, Sendable {
    case localOpenDirectoryUser
    case other
  }

  let generatedUID: UUID
  let kind: Kind
  let volumeOwner: Bool

  init(generatedUID: UUID, kind: Kind, volumeOwner: Bool = true) {
    self.generatedUID = generatedUID
    self.kind = kind
    self.volumeOwner = volumeOwner
  }
}

struct PommeSecurityOwnerStartupIdentity: Equatable, Sendable {
  let volumeGroupUUID: UUID
  let rootVolumeUUID: UUID
  let rootDevice: String
  let systemDevice: String
  let dataDevice: String
}

struct PommeSecurityOwnerEvidence: Equatable, Sendable {
  let targetUsername: String
  let setupAssistantComplete: Bool
  let localUsers: [PommeSecurityOwnerLocalUser]
  let startupIdentity: PommeSecurityOwnerStartupIdentity
  let apfsUsers: [PommeSecurityOwnerAPFSUser]
  let targetSecureTokenEnabled: Bool?
  let targetIsAdministrator: Bool?

  var targetUser: PommeSecurityOwnerLocalUser? {
    localUsers.first(where: { $0.recordName == targetUsername })
  }

  var targetAccountExists: Bool { targetUser != nil }

  var normalLocalUsers: [PommeSecurityOwnerLocalUser] {
    localUsers.filter(\.isNormalLocalUser)
  }

  var apfsLocalOwners: [PommeSecurityOwnerAPFSUser] {
    apfsUsers.filter { $0.kind == .localOpenDirectoryUser && $0.volumeOwner }
  }
}

/// Freshness is a returned fact rather than an implicit side effect.  This
/// lets the parent journal the evidence decision before invoking a mutating
/// account operation.
struct PommeSecurityOwnerFreshness: Equatable, Sendable {
  let creationOwnershipVerified: Bool
  let priorProvisioningAbsent: Bool
  let setupAssistantIncomplete: Bool
  let targetAccountAbsent: Bool
  let noExistingNormalAccount: Bool
  let noAPFSLocalOwner: Bool

  var isVerifiedFresh: Bool {
    creationOwnershipVerified
      && priorProvisioningAbsent
      && setupAssistantIncomplete
      && targetAccountAbsent
      && noExistingNormalAccount
      && noAPFSLocalOwner
  }
}

struct PommeSecurityOwnerProbe: Equatable, Sendable {
  let evidence: PommeSecurityOwnerEvidence
  let freshness: PommeSecurityOwnerFreshness
}

struct PommeSecurityOwnerVerification: Equatable, Sendable {
  let username: String
  let generatedUID: UUID
  let uniqueID: UInt32
  let passwordVerified: Bool
  let isAdministrator: Bool
  let secureTokenEnabled: Bool
  let isAPFSVolumeOwner: Bool
  let startupVolumeGroupUUID: UUID
}

/// Read-only account and login proof for an owner created by Virtualization.
/// This is not a complete desktop proof: callers must also use the normal
/// agent's stable Aqua-session and Dock verification for `owner.uniqueID`
/// before admitting a Recovery transaction or completing provisioning.
struct PommeSecurityFrameworkOwnerVerification: Equatable, Sendable {
  let owner: PommeSecurityOwnerVerification
  let startupRootVolumeUUID: UUID
  let automaticLoginVerified: Bool
  let consoleUserVerified: Bool
}

struct PommeSecurityOwnerLoginRestrictions: Equatable, Sendable {
  let fileVaultEnabled: Bool
  let managedLoginWindow: Bool
  let disableFileVaultAutomaticLogin: Bool
}

struct PommeSecurityOwnerLoginConfiguration: Equatable, Sendable {
  let username: String
  let restrictions: PommeSecurityOwnerLoginRestrictions
  let autoLoginConfigured: Bool
  let setupAssistantFinished: Bool
}

/// A live Setup Assistant Aqua context that can be used as the launchd and
/// audit-session anchor for native automatic-login configuration. The verified
/// asuser proofs establish that this existing Aqua login session belongs to
/// the expected Setup Assistant user before the native setter is invoked.
struct PommeSecurityOwnerSetupAssistantContext: Equatable, Sendable {
  let processID: Int32
  let userID: UInt32
  let executablePath: String
  let startIdentity: String
  let sessionType: String
  let auditSessionID: UInt64
  let processContextUID: UInt32
}

/// Security-only normal-guest owner preparation.  The parent supplies the
/// authenticated guest command bridge and the private PTY worker.  This type
/// never starts/stops a VM, chooses a guest transport, writes host state, or
/// performs display/OCR input.
struct PommeSecurityOwnerPreparation: Sendable {
  typealias GuestCommandExecutor = @Sendable (GuestCommandRequest) throws -> GuestCommandResult
  typealias PrivatePTYExecutor =
    @Sendable (PommeSecurityOwnerPTYCommand, String) async throws -> Int32
  typealias PhaseReporter =
    @Sendable (
      PommeSecurityOwnerPreparationPhase,
      PommeSecurityOwnerPreparationEvent
    ) throws -> Void

  // Native account and APFS tools can take over 30 seconds during macOS 27's
  // first boot. Keep each evidence command bounded while allowing initialization.
  static let commandTimeout: TimeInterval = 120
  private static let setupAssistantRecordName = "_mbsetupuser"
  private static let setupAssistantUID: UInt32 = 248
  private static let setupAssistantExecutablePath =
    "/System/Library/CoreServices/Setup Assistant.app/Contents/MacOS/Setup Assistant"
  private static let setupAssistantOriginatorPath =
    "/System/Library/CoreServices/Setup Assistant.app"
  private static let languageChooserExecutablePath =
    "/System/Library/CoreServices/Language Chooser.app/Contents/MacOS/Language Chooser"
  private static let consoleWindowServerIdentity = "_windowserver:88"
  private static let languageHandoffTimeout: TimeInterval = 30
  private static let setupDonePath = "/var/db/.AppleSetupDone"
  private static let diagnosticsSetupDonePath = "/var/db/.AppleDiagnosticsSetupDone"
  private static let setupTermsOfServicePath = "/var/db/.AppleSetupTermsOfService"
  private static let setupAssistantPreferencesDomain = "com.apple.SetupAssistant"
  private static let loginWindowPreferencesDomain = "com.apple.loginwindow"
  private static let lastSeenBuddyBuildVersionKey = "LastSeenBuddyBuildVersion"
  private static let miniBuddyLaunchKey = "MiniBuddyLaunch"
  private static let ownerPreferenceOutputLimit = 4 * 1024
  private static let ownerSetupAssistantCleanupTimeout: TimeInterval = 5
  // A malformed APFS observation can be transient immediately after account
  // creation. Re-observe the complete read-only evidence set for a bounded
  // interval; this is scoped to the fresh create path and never replays
  // account creation or credentials.
  // This is a retry-admission window. An in-flight read-only collection may
  // finish after its deadline, but no new collection starts after it expires.
  private static let freshOwnerAPFSReobserveRetryWindow: TimeInterval = 30
  private static let freshOwnerAPFSReobserveInterval: TimeInterval = 1
  private static let freshOwnerAPFSReobserveMaximumRetries = 3

  private enum AutoLoginStatus: Equatable {
    case enabled(username: String)
    case disabled
  }

  private enum OwnerPreferenceType: Equatable {
    case string
    case boolean

    var nativeReadType: String {
      switch self {
      case .string: return "Type is string"
      case .boolean: return "Type is boolean"
      }
    }

    var nativeWriteFlag: String {
      switch self {
      case .string: return "-string"
      case .boolean: return "-bool"
      }
    }
  }

  private struct SetupMarkerMetadata: Equatable {
    let uid: UInt32
    let gid: UInt32
    let mode: String
    let size: UInt64
  }

  private enum SetupMarkerState: Equatable {
    case absent
    case present(SetupMarkerMetadata)
  }

  private struct SetupAssistantProcessIdentity: Equatable {
    let processID: Int32
    let userID: UInt32
    let executablePath: String
    let startIdentity: String
  }

  private struct SetupAssistantLaunchdContext: Equatable {
    let handle: UInt64
    let sessionType: String
    let userID: UInt32
    let auditSessionID: UInt64
  }

  let identity: PommeSecurityOwnerIdentity
  let freshnessRequirements: PommeSecurityOwnerFreshnessRequirements
  private let executeGuest: GuestCommandExecutor
  private let executePrivatePTY: PrivatePTYExecutor
  private let reportPhase: PhaseReporter
  private let waitForFreshOwnerAPFS: @Sendable (TimeInterval) async throws -> Void
  private let now: @Sendable () -> TimeInterval

  init(
    identity: PommeSecurityOwnerIdentity = .pomme,
    freshnessRequirements: PommeSecurityOwnerFreshnessRequirements = .unverified,
    executeGuest: @escaping GuestCommandExecutor,
    executePrivatePTY: @escaping PrivatePTYExecutor,
    reportPhase: @escaping PhaseReporter = { _, _ in },
    waitForFreshOwnerAPFS: @escaping @Sendable (TimeInterval) async throws -> Void = {
      interval in
      let milliseconds = Int64(max(1, min(interval, 60) * 1_000))
      try await Task.sleep(for: .milliseconds(milliseconds))
    },
    now: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.identity = identity
    self.freshnessRequirements = freshnessRequirements
    self.executeGuest = executeGuest
    self.executePrivatePTY = executePrivatePTY
    self.reportPhase = reportPhase
    self.waitForFreshOwnerAPFS = waitForFreshOwnerAPFS
    self.now = now
  }

  /// Convenience initializer for callers that want to expose an unavailable
  /// PTY explicitly.  Production composition should always inject a worker.
  init(
    identity: PommeSecurityOwnerIdentity = .pomme,
    freshnessRequirements: PommeSecurityOwnerFreshnessRequirements = .unverified,
    executeGuest: @escaping GuestCommandExecutor,
    reportPhase: @escaping PhaseReporter = { _, _ in }
  ) {
    self.init(
      identity: identity,
      freshnessRequirements: freshnessRequirements,
      executeGuest: executeGuest,
      executePrivatePTY: { _, _ in
        throw PommeSecurityOwnerPreparationError.privatePTYUnavailable
      },
      reportPhase: reportPhase
    )
  }

  /// Reads every normal-account and startup/APFS fact needed for the
  /// freshness decision. Unknown command status, truncation, malformed plist
  /// or an unrecognized native status fails closed.
  func probe() throws -> PommeSecurityOwnerProbe {
    try identity.validate()
    try phase(.evidence, .intent)
    let evidence = try collectEvidence()
    try phase(.evidence, .receipt)

    let freshness = PommeSecurityOwnerFreshness(
      creationOwnershipVerified: freshnessRequirements.creationOwnershipVerified,
      priorProvisioningAbsent: freshnessRequirements.priorProvisioningAbsent,
      setupAssistantIncomplete: !evidence.setupAssistantComplete,
      targetAccountAbsent: !evidence.targetAccountExists,
      noExistingNormalAccount: evidence.normalLocalUsers.isEmpty,
      noAPFSLocalOwner: evidence.apfsUsers.isEmpty
    )
    try phase(.freshness, .intent)
    try phase(.freshness, .receipt)
    return .init(evidence: evidence, freshness: freshness)
  }

  /// Creates `pomme` only after host ownership, prior-provisioning, setup,
  /// account, and APFS freshness evidence has been accepted. A pre-existing
  /// account can be reused only for an explicitly journaled partial-create
  /// retry, and that path performs verification only.
  func createOwner(
    password: String,
    probe: PommeSecurityOwnerProbe,
    retryIntent: Bool? = nil
  ) async throws -> PommeSecurityOwnerVerification {
    try identity.validate()
    guard !password.isEmpty else { throw PommeSecurityOwnerPreparationError.credentialRequired }

    let allowRetry = retryIntent ?? freshnessRequirements.retryExistingAccount
    if probe.evidence.targetAccountExists {
      guard allowRetry else {
        throw PommeSecurityOwnerPreparationError.accountCollision
      }
      guard probe.evidence.targetUser?.recordName == identity.username else {
        throw PommeSecurityOwnerPreparationError.existingAccountNotExact
      }
      return try await verifyOwner(password: password, requireFullName: false)
    }

    guard probe.freshness.isVerifiedFresh else {
      throw PommeSecurityOwnerPreparationError.freshnessRejected
    }

    try phase(.createOwner, .intent)
    let command = PommeSecurityOwnerPTYCommand(
      executable: "/usr/sbin/sysadminctl",
      arguments: [
        "-addUser", identity.username,
        "-fullName", identity.fullName,
        "-admin",
        "-password", "-",
      ]
    )
    let status: Int32
    do {
      status = try await executePrivatePTY(command, password)
    } catch let error as PommeSecurityOwnerPreparationError {
      if case .autoLoginRefused = error {
        throw error
      }
      throw PommeSecurityOwnerPreparationError.privatePTYUnavailable
    } catch {
      throw PommeSecurityOwnerPreparationError.privatePTYUnavailable
    }
    guard status == 0 else {
      throw PommeSecurityOwnerPreparationError.commandFailed(.createOwner, exitCode: Int(status))
    }
    try phase(.createOwner, .receipt)
    return try await verifyFreshOwnerAfterCreation(password: password)
  }

  /// Authenticates the password through a PTY prompt, then verifies the
  /// local record, `id`, admin membership, Secure Token, and exact APFS local
  /// owner UUID. It does not modify an existing account.
  func verifyOwner(
    password: String,
    requireFullName: Bool = false
  ) async throws -> PommeSecurityOwnerVerification {
    try identity.validate()
    guard !password.isEmpty else { throw PommeSecurityOwnerPreparationError.credentialRequired }
    try phase(.verifyOwner, .intent)

    try await authenticateOwner(password: password)
    let evidence = try collectEvidence()
    let verification = try verifyOwnerEvidence(
      evidence: evidence, requireFullName: requireFullName)
    try phase(.verifyOwner, .receipt)
    return verification
  }

  /// Verifies a framework-created owner without account creation, login
  /// configuration, or Setup Assistant mutation. The password must be the
  /// original scoped credential; this boundary never generates a replacement.
  /// On subsequent verification the caller must supply the persisted volume
  /// group in `identity` and the persisted GeneratedUID, when available.
  /// A successful result still requires the caller's stable Aqua/Dock proof.
  func verifyFrameworkProvisionedOwner(
    password: String,
    expectedGeneratedUID: UUID? = nil
  ) async throws -> PommeSecurityFrameworkOwnerVerification {
    guard identity.username == "pomme", identity.fullName == "Pomme" else {
      throw PommeSecurityOwnerPreparationError.invalidIdentity
    }
    try identity.validate()
    guard !password.isEmpty else { throw PommeSecurityOwnerPreparationError.credentialRequired }
    try phase(.verifyOwner, .intent)
    try await authenticateOwner(password: password)
    let evidence = try collectEvidence()
    let owner = try verifyOwnerEvidence(evidence: evidence, requireFullName: true)
    try phase(.verifyOwner, .receipt)
    guard owner.uniqueID >= 501,
      expectedGeneratedUID == nil || owner.generatedUID == expectedGeneratedUID
    else { throw PommeSecurityOwnerPreparationError.ownerVerificationFailed }

    try verifyAutoLoginStatus()
    guard try autoLoginUser() == identity.username else {
      throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed
    }
    // stat without -L uses lstat: the type bits reject symbolic links and
    // nonregular files. Require exactly one link and never read the contents.
    let metadata = try run(
      .init(
        executable: "/usr/bin/stat",
        arguments: ["-f", "%u:%g:%p:%l", "/etc/kcpassword"]
      ),
      kind: .loginWindow,
      acceptedExitCodes: [0]
    )
    guard ["0:0:100400:1", "0:0:100600:1"].contains(
      metadata.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed
    }
    guard try consoleIdentity() == "\(identity.username):\(owner.uniqueID)" else {
      throw PommeSecurityOwnerPreparationError.ownerVerificationFailed
    }
    return .init(
      owner: owner, startupRootVolumeUUID: evidence.startupIdentity.rootVolumeUUID,
      automaticLoginVerified: true, consoleUserVerified: true)
  }

  private func verifyFreshOwnerAfterCreation(
    password: String
  ) async throws -> PommeSecurityOwnerVerification {
    try phase(.verifyOwner, .intent)
    try await authenticateOwner(password: password)
    let evidence = try await collectFreshOwnerEvidence()
    let verification = try verifyOwnerEvidence(evidence: evidence, requireFullName: true)
    try phase(.verifyOwner, .receipt)
    return verification
  }

  private func authenticateOwner(password: String) async throws {
    let authCommand = PommeSecurityOwnerPTYCommand(
      executable: "/usr/bin/dscl",
      arguments: [".", "-authonly", identity.username]
    )
    let authStatus: Int32
    do {
      authStatus = try await executePrivatePTY(authCommand, password)
    } catch {
      throw PommeSecurityOwnerPreparationError.privatePTYUnavailable
    }
    guard authStatus == 0 else {
      throw PommeSecurityOwnerPreparationError.passwordVerificationFailed
    }
  }

  private func collectFreshOwnerEvidence() async throws -> PommeSecurityOwnerEvidence {
    let deadline = now() + Self.freshOwnerAPFSReobserveRetryWindow
    var retries = 0
    while true {
      try Task.checkCancellation()
      if retries > 0, now() >= deadline {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
      }
      do {
        // Every attempt refreshes local-account, startup-volume, APFS,
        // Secure Token, and administrator evidence. Nothing is carried over
        // from an earlier malformed APFS observation.
        return try collectEvidence()
      } catch let error as PommeSecurityOwnerPreparationError {
        guard case .malformedEvidence(.apfsUsers) = error else { throw error }
        let remaining = deadline - now()
        guard retries < Self.freshOwnerAPFSReobserveMaximumRetries,
          remaining > 0
        else { throw error }
        retries += 1
        try await waitForFreshOwnerAPFS(
          min(Self.freshOwnerAPFSReobserveInterval, remaining))
      }
    }
  }

  private func verifyOwnerEvidence(
    evidence: PommeSecurityOwnerEvidence,
    requireFullName: Bool
  ) throws -> PommeSecurityOwnerVerification {
    guard let target = evidence.targetUser,
      target.recordName == identity.username,
      target.isNormalLocalUser,
      // A newly created owner must receive the canonical home. An existing
      // owner is verified by its account identity and may retain a custom
      // home selected by the user or an earlier provisioning system.
      !requireFullName || target.homeDirectory == "/Users/\(identity.username)",
      !requireFullName || target.realName == identity.fullName,
      evidence.targetSecureTokenEnabled == true,
      evidence.targetIsAdministrator == true,
      evidence.startupIdentity.volumeGroupUUID == identity.expectedVolumeGroupUUID
        || identity.expectedVolumeGroupUUID == nil,
      let id = try? accountID(identity.username),
      Int64(id) == target.uniqueID,
      let apfsOwner = exactAPFSOwner(
        generatedUID: target.generatedUID,
        users: evidence.apfsUsers
      ),
      apfsOwner
    else {
      throw PommeSecurityOwnerPreparationError.ownerVerificationFailed
    }
    return .init(
      username: identity.username,
      generatedUID: target.generatedUID,
      uniqueID: id,
      passwordVerified: true,
      isAdministrator: true,
      secureTokenEnabled: true,
      isAPFSVolumeOwner: true,
      startupVolumeGroupUUID: evidence.startupIdentity.volumeGroupUUID
    )
  }

  /// Reads FileVault and managed-loginwindow restrictions. This method has
  /// no mutation and can be called by a parent coordinator before it records
  /// the configure-login intent.
  func inspectLoginRestrictions() throws -> PommeSecurityOwnerLoginRestrictions {
    try phase(.loginRestrictions, .intent)
    let fileVaultOutput = try run(
      .init(executable: "/usr/bin/fdesetup", arguments: ["status"]),
      kind: .fileVault,
      acceptedExitCodes: [0]
    )
    let fileVaultEnabled: Bool
    let fileVaultText = normalized(fileVaultOutput)
    if fileVaultText.contains("filevault is on") {
      fileVaultEnabled = true
    } else if fileVaultText.contains("filevault is off") {
      fileVaultEnabled = false
    } else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.fileVault)
    }

    let managedPreferences = try enumerateManagedPath(
      "/Library/Managed Preferences",
      findArguments: ["-mindepth", "1", "-print"]
    )
    let ownerManagedPreferences = try enumerateManagedPath(
      "/Users/\(identity.username)/Library/Managed Preferences",
      findArguments: ["-mindepth", "1", "-print"]
    )
    let enrollmentStatus = try runCombinedOutput(
      .init(
        executable: "/usr/bin/profiles",
        arguments: ["status", "-type", "enrollment"]
      ),
      kind: .managedLoginWindow,
      acceptedExitCodes: [0]
    )
    let configurationProfiles = try runCombinedOutput(
      .init(
        executable: "/usr/bin/profiles",
        arguments: ["list", "-type", "configuration"]
      ),
      kind: .managedLoginWindow,
      acceptedExitCodes: [0]
    )
    let ownerConfigurationProfiles = try runCombinedOutput(
      .init(
        executable: "/usr/bin/profiles",
        arguments: ["list", "-type", "configuration", "-user", identity.username]
      ),
      kind: .managedLoginWindow,
      acceptedExitCodes: [0]
    )
    let configurationProfileStatus = try runCombinedOutput(
      .init(
        executable: "/usr/bin/profiles",
        arguments: ["status", "-type", "configuration"]
      ),
      kind: .managedLoginWindow,
      acceptedExitCodes: [0]
    )
    let profilesManaged = try Self.profilesManaged(
      enrollmentStatus: enrollmentStatus,
      configurationList: configurationProfiles,
      configurationStatus: configurationProfileStatus,
      ownerConfigurationList: ownerConfigurationProfiles,
      expectedUsername: identity.username
    )
    let managedPathPresent =
      !managedPreferences.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !ownerManagedPreferences.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || profilesManaged

    let loginWindow = try run(
      .init(
        executable: "/usr/bin/defaults",
        arguments: ["read", "/Library/Preferences/com.apple.loginwindow"]),
      kind: .loginWindow,
      acceptedExitCodes: [0, 1]
    )
    let loginWindowText = normalized(loginWindow)
    let disableFDEAutoLogin = Self.containsTrueLoginWindowValue(
      in: loginWindowText,
      keys: ["disablefdeautologin", "disablefdeautomaticlogin"]
    )
    let managedKey =
      loginWindowText.contains("mcx")
      || loginWindowText.contains("managed")
      || loginWindowText.contains("payloaduuid")

    let restrictions = PommeSecurityOwnerLoginRestrictions(
      fileVaultEnabled: fileVaultEnabled,
      managedLoginWindow: managedPathPresent || managedKey,
      disableFileVaultAutomaticLogin: disableFDEAutoLogin
    )
    try phase(.loginRestrictions, .receipt)
    return restrictions
  }

  /// Verifies native syntax support, rejects FileVault/managed restrictions,
  /// sets autologin through private PTY, verifies loginwindow, and finishes
  /// Setup Assistant only after owner checks have succeeded.
  func configureLogin(password: String) async throws -> PommeSecurityOwnerLoginConfiguration {
    try identity.validate()
    let freshOwner =
      freshnessRequirements.creationOwnershipVerified
      && freshnessRequirements.priorProvisioningAbsent
    // A retried workflow may already have completed the native setter before
    // the host lost its phase receipt. Reconcile that exact state first. The
    // native setter and GUI-context discovery are skipped on this path; a
    // fresh owner still re-authenticates its canonical account before its
    // per-user completion preferences are touched.
    try phase(.globalAutoLoginReadback, .intent)
    let alreadyConfigured = try reconcileConfiguredAutoLogin()
    try phase(.globalAutoLoginReadback, .receipt)
    if alreadyConfigured {
      let restrictions = try verifiedLoginRestrictions()
      if freshOwner {
        guard !password.isEmpty else {
          throw PommeSecurityOwnerPreparationError.credentialRequired
        }
        let verification = try await verifyOwner(password: password, requireFullName: true)
        try phase(.configureLogin, .intent)
        try phase(.ownerCompletion, .intent)
        try await completeFreshOwnerNativeState(verification: verification)
        try phase(.ownerCompletion, .receipt)
      } else {
        try phase(.configureLogin, .intent)
      }
      try phase(.configureLogin, .receipt)
      return try finishSetupAssistant(restrictions: restrictions)
    }

    guard !password.isEmpty else { throw PommeSecurityOwnerPreparationError.credentialRequired }
    let verification = try await verifyOwner(password: password, requireFullName: freshOwner)
    let restrictions = try verifiedLoginRestrictions()

    // A retained owner may encounter a native .AppleSetupDone marker before
    // the existing Setup Assistant Aqua session disappears. In that case the
    // marker is never removed or overwritten: the exact session proof below
    // remains the only authorization for the native setter. Language Chooser
    // handoff is still restricted to the marker-absent path.
    let setupAssistantAlreadyComplete = try setupAssistantComplete()
    try verifyAutoLoginSupport()
    let context: PommeSecurityOwnerSetupAssistantContext
    do {
      context = try discoverSetupAssistantContext()
    } catch PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable {
      guard !setupAssistantAlreadyComplete else {
        throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
      }
      context = try await handoffLanguageChooserToSetupAssistant()
    }
    try phase(.configureLogin, .intent)
    let nativeCommand = PommePrivatePTYRunner.Command.sysadminctlAutologin(
      owner: identity.username, setupAssistantUserID: context.userID)
    let command = PommeSecurityOwnerPTYCommand(
      executable: nativeCommand.path, arguments: nativeCommand.arguments)
    let status: Int32
    do {
      status = try await executePrivatePTY(command, password)
    } catch let error as PommeSecurityOwnerPreparationError {
      if case .autoLoginRefused = error {
        throw error
      }
      throw PommeSecurityOwnerPreparationError.privatePTYUnavailable
    } catch {
      throw PommeSecurityOwnerPreparationError.privatePTYUnavailable
    }
    guard status == 0 else {
      throw PommeSecurityOwnerPreparationError.commandFailed(.autoLogin, exitCode: Int(status))
    }
    try phase(.globalAutoLoginReadback, .intent)
    try verifyAutoLoginStatus()
    guard try autoLoginUser() == identity.username else {
      throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed
    }
    try verifyAutoLoginArtifact()
    try phase(.globalAutoLoginReadback, .receipt)
    if freshOwner {
      try phase(.ownerCompletion, .intent)
      try await completeFreshOwnerNativeState(verification: verification)
      try phase(.ownerCompletion, .receipt)
    }
    try phase(.configureLogin, .receipt)

    return try finishSetupAssistant(restrictions: restrictions)
  }

  private func verifiedLoginRestrictions() throws -> PommeSecurityOwnerLoginRestrictions {
    let restrictions = try inspectLoginRestrictions()
    guard !restrictions.fileVaultEnabled,
      !restrictions.managedLoginWindow,
      !restrictions.disableFileVaultAutomaticLogin
    else { throw PommeSecurityOwnerPreparationError.loginRestricted }
    return restrictions
  }

  /// Reads the complete native automatic-login proof without mutating. A
  /// positive proof requires the native account-bearing status, the loginwindow
  /// preference, and root-owned 0600 artifact metadata to agree exactly.
  /// `OFF` is the only state that permits the fresh Setup Assistant path.
  private func reconcileConfiguredAutoLogin() throws -> Bool {
    switch try readAutoLoginStatus() {
    case .enabled(let username):
      guard username.caseInsensitiveCompare(identity.username) == .orderedSame,
        try autoLoginUser() == identity.username
      else { throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed }
      try verifyAutoLoginArtifact()
      return true
    case .disabled:
      return false
    }
  }

  /// Completes the two native per-user preferences that prevent a newly
  /// created owner from being sent back through MiniBuddy on its first login.
  /// This is reachable only for a host-proven fresh owner. Every preference
  /// is read and type-checked before the first write, and each changed value
  /// is read back before the owner phase receipt is recorded.
  private func completeFreshOwnerNativeState(
    verification: PommeSecurityOwnerVerification
  ) async throws {
    guard verification.username == identity.username,
      verification.uniqueID > 0,
      verification.uniqueID < UInt32.max
    else { throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed }

    let buildVersion = try nativeGuestBuildVersion()
    let existingBuild = try readOwnerStringPreference(
      domain: Self.setupAssistantPreferencesDomain,
      key: Self.lastSeenBuddyBuildVersionKey,
      kind: .setupAssistant
    )
    let existingMiniBuddyLaunch = try readOwnerBoolPreference(
      domain: Self.loginWindowPreferencesDomain,
      key: Self.miniBuddyLaunchKey,
      kind: .loginWindow
    )

    if existingBuild != buildVersion {
      try writeOwnerPreference(
        domain: Self.setupAssistantPreferencesDomain,
        key: Self.lastSeenBuddyBuildVersionKey,
        type: .string,
        value: buildVersion
      )
      guard
        try readOwnerStringPreference(
          domain: Self.setupAssistantPreferencesDomain,
          key: Self.lastSeenBuddyBuildVersionKey,
          kind: .setupAssistant
        ) == buildVersion
      else { throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed }
    }

    if existingMiniBuddyLaunch != false {
      try writeOwnerPreference(
        domain: Self.loginWindowPreferencesDomain,
        key: Self.miniBuddyLaunchKey,
        type: .boolean,
        value: "false"
      )
      guard
        try readOwnerBoolPreference(
          domain: Self.loginWindowPreferencesDomain,
          key: Self.miniBuddyLaunchKey,
          kind: .loginWindow
        ) == false
      else { throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed }
    }

    try await closeRetainedOwnerSetupAssistant(ownerUID: verification.uniqueID)
    let finalBuild = try readOwnerStringPreference(
      domain: Self.setupAssistantPreferencesDomain,
      key: Self.lastSeenBuddyBuildVersionKey,
      kind: .setupAssistant
    )
    let finalMiniBuddyLaunch = try readOwnerBoolPreference(
      domain: Self.loginWindowPreferencesDomain,
      key: Self.miniBuddyLaunchKey,
      kind: .loginWindow
    )
    guard finalBuild == buildVersion, finalMiniBuddyLaunch == false
    else { throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed }
  }

  private func nativeGuestBuildVersion() throws -> String {
    let result = try execute(
      .init(executable: "/usr/bin/sw_vers", arguments: ["-buildVersion"])
    )
    guard result.exitCode == 0,
      result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      result.stdout.utf8.count <= Self.ownerPreferenceOutputLimit
    else {
      throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
    }
    let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidAppleBuildVersion(value) else {
      throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
    }
    return value
  }

  private func readOwnerStringPreference(
    domain: String,
    key: String,
    kind: PommeSecurityOwnerCommandKind
  ) throws -> String? {
    let result = try readOwnerPreference(
      domain: domain, key: key, kind: kind, expectedType: .string)
    guard let result else { return nil }
    let value = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidAppleBuildVersion(value) else {
      throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
    }
    return value
  }

  private func readOwnerBoolPreference(
    domain: String,
    key: String,
    kind: PommeSecurityOwnerCommandKind
  ) throws -> Bool? {
    let result = try readOwnerPreference(
      domain: domain, key: key, kind: kind, expectedType: .boolean)
    guard let result else { return nil }
    let value = result.trimmingCharacters(in: .whitespacesAndNewlines)
    switch value {
    case "0": return false
    case "1": return true
    default: throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
    }
  }

  private func readOwnerPreference(
    domain: String,
    key: String,
    kind: PommeSecurityOwnerCommandKind,
    expectedType: OwnerPreferenceType
  ) throws -> String? {
    let typeCommand = PommeSecurityOwnerPTYCommand(
      executable: "/usr/bin/sudo",
      arguments: [
        "-n", "-H", "-u", identity.username,
        "/usr/bin/defaults", "read-type", domain, key,
      ])
    let typeResult = try execute(typeCommand)
    guard typeResult.output.utf8.count <= Self.ownerPreferenceOutputLimit else {
      throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
    }
    switch typeResult.exitCode {
    case 0:
      guard typeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        typeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
          == expectedType.nativeReadType
      else {
        throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
      }
    case 1:
      // `defaults read-type` uses status 1 for a missing domain/key. stdout must
      // remain empty and the observed key-specific native diagnostic must be
      // present. The diagnostic itself is never retained or rendered.
      guard typeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        Self.isMissingOwnerPreferenceDiagnostic(
          typeResult.stderr, domain: domain, key: key)
      else {
        throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
      }
      return nil
    default:
      throw PommeSecurityOwnerPreparationError.commandFailed(
        kind, exitCode: Int(typeResult.exitCode))
    }

    let readCommand = PommeSecurityOwnerPTYCommand(
      executable: "/usr/bin/sudo",
      arguments: [
        "-n", "-H", "-u", identity.username,
        "/usr/bin/defaults", "read", domain, key,
      ])
    let result = try execute(readCommand)
    guard result.output.utf8.count <= Self.ownerPreferenceOutputLimit,
      result.exitCode == 0,
      result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
    }
    return result.stdout
  }

  private static func isMissingOwnerPreferenceDiagnostic(
    _ output: String,
    domain: String,
    key: String
  ) -> Bool {
    let messages = [
      "Domain \(domain) does not exist",
      "Domain \(domain) does not exist.",
      "The domain/default pair of (\(domain), \(key)) does not exist",
      "The domain/default pair of (\(domain), \(key)) does not exist.",
    ]
    let lines = output.split(whereSeparator: \.isNewline).map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard !lines.isEmpty else { return false }
    if lines.count == 1 {
      return messages.contains(lines[0])
    }
    guard lines.count == 2,
      lines[0].range(
        of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ defaults\[\d+:\d+\]$"#,
        options: .regularExpression
      ) != nil
    else { return false }
    return messages.contains(lines[1])
  }

  private func writeOwnerPreference(
    domain: String,
    key: String,
    type: OwnerPreferenceType,
    value: String
  ) throws {
    let command = PommeSecurityOwnerPTYCommand(
      executable: "/usr/bin/sudo",
      arguments: [
        "-n", "-H", "-u", identity.username,
        "/usr/bin/defaults", "write", domain, key,
        type.nativeWriteFlag, value,
      ])
    let result = try execute(command)
    guard result.output.utf8.count <= Self.ownerPreferenceOutputLimit else {
      throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
    }
    guard result.exitCode == 0 else {
      throw PommeSecurityOwnerPreparationError.commandFailed(
        .ownerCompletion, exitCode: Int(result.exitCode))
    }
    guard result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed }
  }

  private static func isValidAppleBuildVersion(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 32 else { return false }
    return value.utf8.allSatisfy { byte in
      (byte >= 48 && byte <= 57)
        || (byte >= 65 && byte <= 90)
        || (byte >= 97 && byte <= 122)
    }
  }

  /// A previous interrupted attempt may leave Setup Assistant running as the
  /// newly created owner. Only the exact owner UID, executable path, PID, and
  /// start identity may be terminated. The native `_mbsetupuser` process and
  /// every unrelated helper are outside this cleanup boundary.
  private func closeRetainedOwnerSetupAssistant(ownerUID: UInt32) async throws {
    do {
      let listed = try run(
        .init(executable: "/bin/ps", arguments: ["-axo", "pid=,uid=,lstart=,comm="]),
        kind: .setupAssistant,
        acceptedExitCodes: [0]
      )
      let processes = try Self.parseProcessIdentities(listed)
      let candidates = processes.filter {
        $0.userID == ownerUID && $0.executablePath == Self.setupAssistantExecutablePath
      }
      guard candidates.count <= 1 else {
        throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed
      }
      guard let candidate = candidates.first else { return }

      guard let rechecked = try ownerSetupAssistantProcess(candidate.processID) else {
        return
      }
      guard rechecked == candidate else {
        throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed
      }
      let signal = try execute(
        .init(executable: "/bin/kill", arguments: ["-TERM", String(candidate.processID)])
      )
      guard signal.output.utf8.count <= Self.ownerPreferenceOutputLimit,
        signal.exitCode == 0 || signal.exitCode == 1
      else { throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed }

      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(Self.ownerSetupAssistantCleanupTimeout))
      while clock.now < deadline {
        guard let current = try ownerSetupAssistantProcess(candidate.processID) else { return }
        guard current == candidate else {
          throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed
        }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(100))
      }
      throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed
    } catch let error as PommeSecurityOwnerPreparationError {
      if case .setupAssistantProcessCleanupFailed = error { throw error }
      throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed
    } catch {
      throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed
    }
  }

  private func ownerSetupAssistantProcess(_ processID: Int32) throws
    -> SetupAssistantProcessIdentity?
  {
    let result = try execute(
      .init(
        executable: "/bin/ps",
        arguments: ["-p", String(processID), "-o", "pid=,uid=,lstart=,comm="])
    )
    guard result.output.utf8.count <= Self.ownerPreferenceOutputLimit else {
      throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed
    }
    if result.exitCode == 1,
      result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return nil
    }
    guard result.exitCode == 0,
      result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed }
    let processes = try Self.parseProcessIdentities(result.stdout)
    guard processes.count == 1, let process = processes.first,
      process.processID == processID
    else { throw PommeSecurityOwnerPreparationError.setupAssistantProcessCleanupFailed }
    return process
  }

  private func finishSetupAssistant(
    restrictions: PommeSecurityOwnerLoginRestrictions
  ) throws -> PommeSecurityOwnerLoginConfiguration {
    try phase(.finishSetupAssistant, .intent)
    let setupDone = try readSetupMarker(
      path: Self.setupDonePath,
      allowedModes: ["0400", "400", "0644", "644"],
      // Native and product markers are empty. Keep root-owned 0644 only for
      // the legacy product marker; newly created markers are 0400.
      requireEmpty: true,
      kind: .finishSetupAssistant
    )
    let diagnostics = try readSetupMarker(
      path: Self.diagnosticsSetupDonePath,
      allowedModes: ["0400", "400"],
      requireEmpty: true,
      kind: .finishSetupAssistant
    )
    let terms = try readSetupMarker(
      path: Self.setupTermsOfServicePath,
      allowedModes: ["0400", "400"],
      requireEmpty: true,
      kind: .finishSetupAssistant
    )

    if case .absent = diagnostics {
      try createSetupMarker(Self.diagnosticsSetupDonePath)
      guard
        case .present = try readSetupMarker(
          path: Self.diagnosticsSetupDonePath,
          allowedModes: ["0400", "400"],
          requireEmpty: true,
          kind: .finishSetupAssistant
        )
      else {
        throw PommeSecurityOwnerPreparationError.ownerVerificationFailed
      }
    }

    if case .present = terms {
      let remove = try runStatus(
        .init(executable: "/bin/rm", arguments: ["-f", Self.setupTermsOfServicePath]),
        kind: .finishSetupAssistant,
        acceptedExitCodes: [0]
      )
      guard remove == 0 else {
        throw PommeSecurityOwnerPreparationError.commandFailed(
          .finishSetupAssistant, exitCode: Int(remove))
      }
      guard
        case .absent = try readSetupMarker(
          path: Self.setupTermsOfServicePath,
          allowedModes: ["0400", "400"],
          requireEmpty: true,
          kind: .finishSetupAssistant
        )
      else {
        throw PommeSecurityOwnerPreparationError.ownerVerificationFailed
      }
    }

    if case .absent = setupDone {
      try createSetupMarker(Self.setupDonePath)
      guard
        case .present = try readSetupMarker(
          path: Self.setupDonePath,
          allowedModes: ["0400", "400"],
          requireEmpty: true,
          kind: .finishSetupAssistant
        )
      else {
        throw PommeSecurityOwnerPreparationError.ownerVerificationFailed
      }
    }

    // Flush all completion-marker writes before the durable receipt. The
    // parent journal still treats this phase as resumable until its post-boot
    // console check succeeds.
    _ = try runStatus(
      .init(executable: "/bin/sync", arguments: []),
      kind: .finishSetupAssistant,
      acceptedExitCodes: [0]
    )
    guard
      case .present = try readSetupMarker(
        path: Self.setupDonePath,
        allowedModes: ["0400", "400", "0644", "644"],
        requireEmpty: true,
        kind: .finishSetupAssistant
      ),
      case .present = try readSetupMarker(
        path: Self.diagnosticsSetupDonePath,
        allowedModes: ["0400", "400"],
        requireEmpty: true,
        kind: .finishSetupAssistant
      ),
      case .absent = try readSetupMarker(
        path: Self.setupTermsOfServicePath,
        allowedModes: ["0400", "400"],
        requireEmpty: true,
        kind: .finishSetupAssistant
      )
    else {
      throw PommeSecurityOwnerPreparationError.ownerVerificationFailed
    }
    try phase(.finishSetupAssistant, .receipt)

    return .init(
      username: identity.username,
      restrictions: restrictions,
      autoLoginConfigured: true,
      setupAssistantFinished: true
    )
  }

  private func createSetupMarker(_ path: String) throws {
    // BSD install creates the marker with its final ownership and mode in one
    // operation. That leaves a valid resumable receipt if the process is
    // interrupted after creation; a separate touch/chmod pair could leave a
    // world-readable partial marker that the strict validator must reject.
    let install = try runStatus(
      .init(
        executable: "/usr/bin/install",
        arguments: ["-S", "-m", "0400", "-o", "root", "-g", "wheel", "/dev/null", path]
      ),
      kind: .finishSetupAssistant,
      acceptedExitCodes: [0]
    )
    guard install == 0 else {
      throw PommeSecurityOwnerPreparationError.commandFailed(
        .finishSetupAssistant, exitCode: Int(install))
    }
  }

  private func readSetupMarker(
    path: String,
    allowedModes: Set<String>,
    requireEmpty: Bool,
    kind: PommeSecurityOwnerCommandKind
  ) throws -> SetupMarkerState {
    let symlink = try runStatus(
      .init(executable: "/bin/test", arguments: ["-L", path]),
      kind: kind,
      acceptedExitCodes: [0, 1]
    )
    guard symlink == 1 else {
      throw PommeSecurityOwnerPreparationError.ownerVerificationFailed
    }

    let exists = try runStatus(
      .init(executable: "/bin/test", arguments: ["-e", path]),
      kind: kind,
      acceptedExitCodes: [0, 1]
    )
    if exists == 1 {
      return .absent
    }

    let regular = try runStatus(
      .init(executable: "/bin/test", arguments: ["-f", path]),
      kind: kind,
      acceptedExitCodes: [0, 1]
    )
    guard regular == 0 else {
      throw PommeSecurityOwnerPreparationError.ownerVerificationFailed
    }
    let metadata = try run(
      .init(executable: "/usr/bin/stat", arguments: ["-f", "%u:%g:%Lp:%z", path]),
      kind: kind,
      acceptedExitCodes: [0]
    )
    guard let parsed = Self.parseSetupMarkerMetadata(metadata),
      parsed.uid == 0,
      parsed.gid == 0,
      allowedModes.contains(parsed.mode),
      !requireEmpty || parsed.size == 0
    else {
      throw PommeSecurityOwnerPreparationError.ownerVerificationFailed
    }
    return .present(parsed)
  }

  private static func parseSetupMarkerMetadata(_ output: String) -> SetupMarkerMetadata? {
    let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = value.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 4,
      fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
      let uid = UInt32(fields[0]),
      let gid = UInt32(fields[1]),
      let size = UInt64(fields[3]),
      fields[2] == "400" || fields[2] == "0400"
        || fields[2] == "644" || fields[2] == "0644"
    else {
      return nil
    }
    let mode =
      fields[2] == "0400"
      ? "0400"
      : fields[2] == "0644" ? "0644" : String(fields[2])
    return .init(uid: uid, gid: gid, mode: mode, size: size)
  }

  private func setupAssistantComplete() throws -> Bool {
    if case .present = try readSetupMarker(
      path: Self.setupDonePath,
      allowedModes: ["0400", "400", "0644", "644"],
      // Preserve the legacy product marker's 0644 mode, but still require its
      // native empty content before treating Setup Assistant as complete.
      requireEmpty: true,
      kind: .setupAssistant
    ) {
      return true
    }
    return false
  }

  /// Finds and rechecks exactly one running Setup Assistant process, then
  /// verifies its Aqua launchd and audit-session identity. The returned
  /// context contains only closed identity facts.
  private func discoverSetupAssistantContext() throws
    -> PommeSecurityOwnerSetupAssistantContext
  {
    do {
      guard
        try consoleIdentity()
          == "\(Self.setupAssistantRecordName):\(Self.setupAssistantUID)"
      else {
        throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
      }
      let setupUser = try setupAssistantUser()
      guard setupUser.uniqueID == Int64(Self.setupAssistantUID),
        setupUser.homeDirectory == "/var/setup",
        Self.isDeterministicSystemGeneratedUID(
          setupUser.generatedUID, uniqueID: setupUser.uniqueID)
      else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }

      let listed = try run(
        .init(
          executable: "/bin/ps",
          arguments: ["-axo", "pid=,uid=,lstart=,comm="]),
        kind: .setupAssistant,
        acceptedExitCodes: [0]
      )
      let candidates = try Self.parseSetupAssistantProcesses(listed)
      guard candidates.count == 1, let candidate = candidates.first,
        candidate.userID == Self.setupAssistantUID,
        candidate.executablePath == Self.setupAssistantExecutablePath
      else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }

      let firstRecheck = try setupAssistantProcess(candidate.processID)
      guard firstRecheck == candidate else {
        throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
      }

      let guiOutput = try run(
        .init(
          executable: "/bin/launchctl",
          arguments: ["print", "gui/\(Self.setupAssistantUID)"]),
        kind: .setupAssistant,
        acceptedExitCodes: [0]
      )
      let guiContext = try Self.parseSetupAssistantGUIDomain(
        guiOutput, expectedUID: Self.setupAssistantUID)
      let processOutput = try run(
        .init(
          executable: "/bin/launchctl",
          arguments: ["print", "pid/\(candidate.processID)"]),
        kind: .setupAssistant,
        acceptedExitCodes: [0]
      )
      let processContext = try Self.parseSetupAssistantPIDDomain(
        processOutput,
        expectedPID: candidate.processID,
        expectedOriginator: Self.setupAssistantOriginatorPath
      )
      guard guiContext.sessionType == "Aqua",
        guiContext.userID == Self.setupAssistantUID,
        guiContext.handle == guiContext.auditSessionID,
        processContext.userID == Self.setupAssistantUID,
        guiContext.auditSessionID == processContext.auditSessionID,
        processContext.handle == UInt64(candidate.processID),
        let processContextUID = UInt32(exactly: processContext.userID)
      else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }

      let managerName = try asuserOutput(
        userID: processContextUID,
        executable: "/bin/launchctl",
        arguments: ["managername"]
      )
      let managerUID = try asuserOutput(
        userID: processContextUID,
        executable: "/bin/launchctl",
        arguments: ["manageruid"]
      )
      let callerUID = try asuserOutput(
        userID: processContextUID,
        executable: "/usr/bin/id",
        arguments: ["-u"]
      )
      guard managerName == guiContext.sessionType,
        managerUID == String(processContextUID),
        callerUID == "0"
      else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }

      let finalRecheck = try setupAssistantProcess(candidate.processID)
      guard finalRecheck == candidate,
        try consoleIdentity()
          == "\(Self.setupAssistantRecordName):\(Self.setupAssistantUID)"
      else {
        throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
      }
      return .init(
        processID: candidate.processID,
        userID: candidate.userID,
        executablePath: candidate.executablePath,
        startIdentity: candidate.startIdentity,
        sessionType: guiContext.sessionType,
        auditSessionID: guiContext.auditSessionID,
        processContextUID: processContextUID
      )
    } catch let error as PommeSecurityOwnerPreparationError {
      if case .setupAssistantContextUnavailable = error { throw error }
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    } catch {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
  }

  /// The pristine native flow can still be at Language Chooser after the
  /// owner has been verified. This handoff uses only the documented native
  /// language tool and the observed completion notification; it never fakes a
  /// GUI event or writes Setup Assistant state directly.
  private func handoffLanguageChooserToSetupAssistant() async throws
    -> PommeSecurityOwnerSetupAssistantContext
  {
    try phase(.setupAssistantHandoff, .intent)
    guard try !setupAssistantComplete() else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    let languageChooser = try discoverLanguageChooserContext()
    let languageOutput = try run(
      .init(executable: "/usr/sbin/languagesetup", arguments: ["-langspec", "en"]),
      kind: .setupAssistant,
      acceptedExitCodes: [0]
    )
    guard normalized(languageOutput) == "system language set to: en" else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    let languageReadback = try run(
      .init(
        executable: "/usr/bin/defaults",
        arguments: ["read", "/Library/Preferences/.GlobalPreferences", "AppleLanguages"]
      ),
      kind: .setupAssistant,
      acceptedExitCodes: [0]
    )
    guard Self.isEnglishLanguageReadback(languageReadback) else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    let afterLanguage = try discoverLanguageChooserContext()
    guard afterLanguage == languageChooser else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    _ = try runStatus(
      .init(executable: "/usr/bin/notifyutil", arguments: ["-p", "com.apple.lca.done"]),
      kind: .setupAssistant,
      acceptedExitCodes: [0]
    )
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(Self.languageHandoffTimeout))
    while clock.now < deadline {
      do {
        let context = try discoverSetupAssistantContext()
        try phase(.setupAssistantHandoff, .receipt)
        return context
      } catch PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(100))
      }
    }
    throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
  }

  private func discoverLanguageChooserContext() throws -> SetupAssistantProcessIdentity {
    do {
      guard try consoleIdentity() == Self.consoleWindowServerIdentity else {
        throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
      }
      let listed = try run(
        .init(
          executable: "/bin/ps",
          arguments: ["-axo", "pid=,uid=,lstart=,comm="]),
        kind: .setupAssistant,
        acceptedExitCodes: [0]
      )
      let processes = try Self.parseProcessIdentities(listed)
      let setupAssistantCandidates = processes.filter {
        $0.executablePath == Self.setupAssistantExecutablePath
      }
      guard setupAssistantCandidates.isEmpty else {
        throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
      }
      let candidates = processes.filter {
        $0.executablePath == Self.languageChooserExecutablePath
      }
      guard candidates.count == 1, let candidate = candidates.first,
        candidate.userID == 0
      else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }
      let recheck = try languageChooserProcess(candidate.processID)
      guard recheck == candidate, try consoleIdentity() == Self.consoleWindowServerIdentity else {
        throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
      }
      return candidate
    } catch let error as PommeSecurityOwnerPreparationError {
      if case .setupAssistantContextUnavailable = error { throw error }
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    } catch {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
  }

  private func languageChooserProcess(_ processID: Int32) throws
    -> SetupAssistantProcessIdentity
  {
    let output = try run(
      .init(
        executable: "/bin/ps",
        arguments: ["-p", String(processID), "-o", "pid=,uid=,lstart=,comm="]),
      kind: .setupAssistant,
      acceptedExitCodes: [0]
    )
    let processes = try Self.parseProcessIdentities(output)
    guard processes.count == 1, let process = processes.first,
      process.processID == processID,
      process.userID == 0,
      process.executablePath == Self.languageChooserExecutablePath
    else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }
    return process
  }

  private func consoleIdentity() throws -> String {
    try run(
      .init(executable: "/usr/bin/stat", arguments: ["-f", "%Su:%u", "/dev/console"]),
      kind: .setupAssistant,
      acceptedExitCodes: [0]
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func setupAssistantUser() throws -> PommeSecurityOwnerLocalUser {
    let output = try run(
      .init(
        executable: "/usr/bin/dscl",
        arguments: [
          ".", "-read", "/Users/\(Self.setupAssistantRecordName)",
          "RecordName", "RealName", "GeneratedUID", "UniqueID", "NFSHomeDirectory",
        ]),
      kind: .readLocalUser,
      acceptedExitCodes: [0]
    )
    let record = try Self.parseLocalUser(
      output, expectedName: Self.setupAssistantRecordName)
    guard record.uniqueID == Int64(Self.setupAssistantUID),
      record.homeDirectory == "/var/setup",
      Self.isDeterministicSystemGeneratedUID(record.generatedUID, uniqueID: record.uniqueID)
    else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }
    return record
  }

  private func setupAssistantProcess(_ processID: Int32) throws
    -> SetupAssistantProcessIdentity
  {
    let output = try run(
      .init(
        executable: "/bin/ps",
        arguments: ["-p", String(processID), "-o", "pid=,uid=,lstart=,comm="]),
      kind: .setupAssistant,
      acceptedExitCodes: [0]
    )
    let processes = try Self.parseSetupAssistantProcesses(output)
    guard processes.count == 1, let process = processes.first,
      process.processID == processID
    else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }
    return process
  }

  private func asuserOutput(
    userID: UInt32, executable: String, arguments: [String]
  ) throws -> String {
    try run(
      .init(
        executable: "/bin/launchctl",
        arguments: ["asuser", String(userID), executable] + arguments),
      kind: .setupAssistant,
      acceptedExitCodes: [0]
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Evidence collection

  private func collectEvidence() throws -> PommeSecurityOwnerEvidence {
    let setupAssistantComplete = try setupAssistantComplete()

    let usersOutput = try run(
      .init(executable: "/usr/bin/dscl", arguments: [".", "-list", "/Users", "UniqueID"]),
      kind: .listLocalUsers,
      acceptedExitCodes: [0]
    )
    let names = try Self.parseUserNames(usersOutput)
    let generatedOutput = try run(
      .init(executable: "/usr/bin/dscl", arguments: [".", "-list", "/Users", "GeneratedUID"]),
      kind: .listLocalUsers,
      acceptedExitCodes: [0]
    )
    let generatedUIDs = try Self.parseGeneratedUIDs(generatedOutput)
    guard Set(names.map { $0.name }) == Set(generatedUIDs.keys) else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)
    }
    var users: [PommeSecurityOwnerLocalUser] = []
    users.reserveCapacity(names.count)
    for (name, uniqueID) in names {
      guard let listedGeneratedUID = generatedUIDs[name] else {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)
      }

      let deterministicSystemIdentity =
        uniqueID.map {
          ($0 == -2 && name == "nobody"
            && Self.isDeterministicSystemGeneratedUID(listedGeneratedUID, uniqueID: $0))
            || ($0 >= 0 && $0 < 500
              && Self.isDeterministicSystemGeneratedUID(
                listedGeneratedUID, uniqueID: $0
              ))
        } ?? false
      let knownStockIdentity =
        uniqueID.map {
          PommeSecurityStockAccountIdentity.matches(
            recordName: name, uid: $0, generatedUID: listedGeneratedUID)
        } ?? false
      let isTarget = name == identity.username

      // `_mbsetupuser` is the one stock record whose exact native identity
      // anchors the pristine Setup Assistant context. Read it before applying
      // the stock-account filter so an unexpected UID, home, or GeneratedUID
      // cannot be silently discarded.
      if !isTarget,
        knownStockIdentity,
        name != Self.setupAssistantRecordName
      {
        continue
      }

      let output = try run(
        .init(
          executable: "/usr/bin/dscl",
          arguments: [
            ".", "-read", "/Users/\(name)",
            "RecordName", "RealName", "GeneratedUID", "UniqueID", "NFSHomeDirectory",
          ]
        ),
        kind: .readLocalUser,
        acceptedExitCodes: [0]
      )
      let record = try Self.parseLocalUser(
        output,
        expectedName: name,
        expectedGeneratedUID: listedGeneratedUID,
        isKnownSystemAccount: knownStockIdentity && name != Self.setupAssistantRecordName
      )
      if let uniqueID, record.uniqueID != uniqueID {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUserRecord)
      }

      if name == Self.setupAssistantRecordName,
        !isTarget,
        !setupAssistantComplete,
        record.uniqueID == Int64(Self.setupAssistantUID),
        record.homeDirectory == "/var/setup",
        deterministicSystemIdentity
      {
        continue
      }
      users.append(record)
    }

    let startupIdentity = try startupIdentity()
    let apfsOutput = try run(
      .init(executable: "/usr/sbin/diskutil", arguments: ["apfs", "listUsers", "/"]),
      kind: .apfsUsers,
      acceptedExitCodes: [0]
    )
    let apfsUsers = try Self.parseAPFSUsers(
      apfsOutput,
      expectedDevice: startupIdentity.rootDevice
    )

    let target = users.first(where: { $0.recordName == identity.username })
    let targetSecureTokenEnabled: Bool?
    let targetIsAdministrator: Bool?
    if target != nil {
      targetSecureTokenEnabled = try secureTokenStatus(identity.username)
      targetIsAdministrator = try administratorStatus(identity.username)
    } else {
      targetSecureTokenEnabled = nil
      targetIsAdministrator = nil
    }

    return .init(
      targetUsername: identity.username,
      setupAssistantComplete: setupAssistantComplete,
      localUsers: users,
      startupIdentity: startupIdentity,
      apfsUsers: apfsUsers,
      targetSecureTokenEnabled: targetSecureTokenEnabled,
      targetIsAdministrator: targetIsAdministrator
    )
  }

  private func startupIdentity() throws -> PommeSecurityOwnerStartupIdentity {
    let groups = try run(
      .init(executable: "/usr/sbin/diskutil", arguments: ["apfs", "listVolumeGroups", "-plist"]),
      kind: .startupVolumeGroups,
      acceptedExitCodes: [0]
    )
    let selected: PommeRecoveryDataVolumeResolver.Volume
    do {
      selected = try PommeRecoveryDataVolumeResolver.resolveDataVolume(
        from: Data(groups.utf8),
        expectedVolumeGroupUUID: identity.expectedVolumeGroupUUID
      )
    } catch {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.startupVolume)
    }

    let info = try run(
      .init(executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", "/"]),
      kind: .startupVolumeInfo,
      acceptedExitCodes: [0]
    )
    guard
      let root = try? PropertyListSerialization.propertyList(from: Data(info.utf8), format: nil)
        as? [String: Any],
      let rawGroup = (root["APFSVolumeGroupID"] as? String)
        ?? (root["APFSVolumeGroupUUID"] as? String),
      let group = UUID(uuidString: rawGroup),
      group == selected.volumeGroupUUID,
      let rawRootUUID = (root["VolumeUUID"] as? String) ?? (root["APFSVolumeUUID"] as? String),
      let rootUUID = UUID(uuidString: rawRootUUID),
      let rootDevice = root["DeviceIdentifier"] as? String,
      Self.validDevice(rootDevice),
      (root["FilesystemType"] as? String)?.caseInsensitiveCompare("apfs") == .orderedSame,
      (root["MountPoint"] as? String) == "/"
    else { throw PommeSecurityOwnerPreparationError.malformedEvidence(.startupVolume) }

    return .init(
      volumeGroupUUID: group,
      rootVolumeUUID: rootUUID,
      rootDevice: rootDevice,
      systemDevice: selected.systemDevice,
      dataDevice: selected.dataDevice
    )
  }

  private func secureTokenStatus(_ username: String) throws -> Bool {
    let output = try runCombinedOutput(
      .init(executable: "/usr/sbin/sysadminctl", arguments: ["-secureTokenStatus", username]),
      kind: .secureToken,
      acceptedExitCodes: [0, 1]
    )
    let text = normalized(output)
    let enabled = text.contains("secure token is enabled") || text.contains("securetoken is enabled")
    let disabled = text.contains("secure token is disabled") || text.contains("securetoken is disabled")
    guard enabled != disabled else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.secureToken)
    }
    return enabled
  }

  private func administratorStatus(_ username: String) throws -> Bool {
    let output = try run(
      .init(
        executable: "/usr/bin/dsmemberutil",
        arguments: ["checkmembership", "-U", username, "-G", "admin"]),
      kind: .administratorMembership,
      acceptedExitCodes: [0, 1]
    )
    let text = normalized(output)
    if text.contains("is a member") && !text.contains("is not a member") {
      return true
    }
    if text.contains("is not a member") {
      return false
    }
    throw PommeSecurityOwnerPreparationError.malformedEvidence(.administratorMembership)
  }

  private func accountID(_ username: String) throws -> UInt32 {
    let output = try run(
      .init(executable: "/usr/bin/id", arguments: ["-u", username]),
      kind: .accountID,
      acceptedExitCodes: [0]
    )
    guard let value = UInt32(normalized(output).trimmingCharacters(in: .whitespacesAndNewlines)),
      value > 0
    else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.accountIdentity)
    }
    return value
  }

  private func exactAPFSOwner(generatedUID: UUID, users: [PommeSecurityOwnerAPFSUser]) -> Bool? {
    let matches = users.filter {
      $0.kind == .localOpenDirectoryUser && $0.volumeOwner && $0.generatedUID == generatedUID
    }
    guard matches.count == 1 else { return nil }
    return true
  }

  // MARK: - Login configuration

  private func verifyAutoLoginSupport() throws {
    let output = try runCombinedOutput(
      .init(executable: "/usr/sbin/sysadminctl", arguments: ["-help"]),
      kind: .autoLoginSupport,
      acceptedExitCodes: [0, 1]
    )
    let text = normalized(output)
    guard text.range(of: #"-autologin\s+set\b"#, options: .regularExpression) != nil,
      text.contains("-username"),
      text.contains("-password"),
      text.contains("-adminuser"),
      text.contains("-adminpassword")
    else { throw PommeSecurityOwnerPreparationError.autoLoginUnsupported }
  }

  private func verifyAutoLoginStatus() throws {
    guard case .enabled(let username) = try readAutoLoginStatus(),
      username.caseInsensitiveCompare(identity.username) == .orderedSame
    else { throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed }
  }

  private func readAutoLoginStatus() throws -> AutoLoginStatus {
    let output = try runCombinedOutput(
      .init(
        executable: "/usr/sbin/sysadminctl",
        arguments: ["-autologin", "status"]
      ),
      kind: .autoLogin,
      acceptedExitCodes: [0]
    )
    let lines = output.split(whereSeparator: \.isNewline).map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard lines.count == 1, let line = lines.first else {
      throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed
    }

    let lowercased = line.lowercased()
    let offPattern =
      #"^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ sysadminctl\[\d+:\d+\] )?automatic login is off\.$"#
    if lowercased.range(of: offPattern, options: .regularExpression) != nil {
      return .disabled
    }

    let onPattern =
      #"^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ sysadminctl\[\d+:\d+\] )?automatic login user:\s*([a-z_][a-z0-9_.-]*)$"#
    guard let regex = try? NSRegularExpression(pattern: onPattern),
      let match = regex.firstMatch(
        in: lowercased,
        range: NSRange(lowercased.startIndex..<lowercased.endIndex, in: lowercased)
      ),
      let range = Range(match.range(at: 1), in: lowercased)
    else { throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed }
    return .enabled(username: String(lowercased[range]))
  }

  private func autoLoginUser() throws -> String {
    let output = try run(
      .init(
        executable: "/usr/bin/defaults",
        arguments: ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"]
      ),
      kind: .loginWindow,
      acceptedExitCodes: [0]
    )
    let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains("\n") else {
      throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed
    }
    return value
  }

  /// `find` returns status 1 for an absent starting path on macOS. Establish
  /// that the exact starting path is absent before treating that result as a
  /// clear managed-login probe. Existing paths must be real readable
  /// directories and must enumerate successfully; symlinks, non-directories,
  /// and probe errors all fail closed.
  private func enumerateManagedPath(_ path: String, findArguments: [String]) throws -> String {
    let isSymlink = try runStatus(
      .init(executable: "/bin/test", arguments: ["-L", path]),
      kind: .managedLoginWindow,
      acceptedExitCodes: [0, 1]
    )
    guard isSymlink == 1 else { throw PommeSecurityOwnerPreparationError.loginRestricted }

    let exists = try runStatus(
      .init(executable: "/bin/test", arguments: ["-e", path]),
      kind: .managedLoginWindow,
      acceptedExitCodes: [0, 1]
    )
    let isDirectory = try runStatus(
      .init(executable: "/bin/test", arguments: ["-d", path]),
      kind: .managedLoginWindow,
      acceptedExitCodes: [0, 1]
    )

    if exists == 1 {
      guard isDirectory == 1 else { throw PommeSecurityOwnerPreparationError.loginRestricted }
      return ""
    }
    guard isDirectory == 0 else { throw PommeSecurityOwnerPreparationError.loginRestricted }

    return try runStdout(
      .init(executable: "/usr/bin/find", arguments: [path] + findArguments),
      kind: .managedLoginWindow,
      acceptedExitCodes: [0]
    )
  }

  /// `sysadminctl -autologin` may create `/etc/kcpassword` on supported
  /// systems. Inspect metadata only; the secret-derived contents never
  /// enter a command result, error, or phase journal.
  private func verifyAutoLoginArtifact() throws {
    let exists = try runStatus(
      .init(executable: "/bin/test", arguments: ["-f", "/etc/kcpassword"]),
      kind: .loginWindow,
      acceptedExitCodes: [0, 1]
    )
    guard exists == 0 else {
      throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed
    }

    let metadata = try run(
      .init(
        executable: "/usr/bin/stat",
        arguments: [
          "-f", "%u:%g:%Lp", "/etc/kcpassword",
        ]),
      kind: .loginWindow,
      acceptedExitCodes: [0]
    )
    guard normalized(metadata) == "0:0:600" else {
      throw PommeSecurityOwnerPreparationError.autoLoginVerificationFailed
    }
  }

  private static func containsTrueLoginWindowValue(in text: String, keys: [String]) -> Bool {
    for key in keys {
      guard let range = text.range(of: key) else { continue }
      let tail = text[range.upperBound...]
      if tail.prefix(80).contains("= 1") || tail.prefix(80).contains("= true") {
        return true
      }
    }
    return false
  }

  private static func profilesManaged(
    enrollmentStatus: String,
    configurationList: String,
    configurationStatus: String,
    ownerConfigurationList: String,
    expectedUsername: String
  ) throws -> Bool {
    var enrolledViaDEPNo = false
    var mdmEnrollmentNo = false
    for rawLine in enrollmentStatus.split(whereSeparator: \.isNewline) {
      let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !line.isEmpty else { continue }
      if line == "enrolled via dep: no" {
        enrolledViaDEPNo = true
      } else if line == "mdm enrollment: no" {
        mdmEnrollmentNo = true
      } else if line.hasPrefix("enrolled via dep: yes")
        || line.hasPrefix("mdm enrollment: yes")
      {
        return true
      } else if line.hasPrefix("mdm server:") {
        continue
      } else {
        throw PommeSecurityOwnerPreparationError.loginRestricted
      }
    }
    guard enrolledViaDEPNo, mdmEnrollmentNo else {
      throw PommeSecurityOwnerPreparationError.loginRestricted
    }

    let noProfilesOutputs = [
      "there are no configuration profiles installed in the system domain",
      "there are no configuration profiles installed on this system",
    ]
    let list = normalized(configurationList)
    let status = normalized(configurationStatus)
    guard noProfilesOutputs.contains(list), noProfilesOutputs.contains(status) else {
      // Any other native output may describe a profile or an unsupported
      // format. Both must block automatic-login preparation.
      return true
    }

    let ownerOutput = normalized(ownerConfigurationList)
    let ownerPrefix = "there are no configuration profiles installed for user '"
    guard ownerOutput.hasPrefix(ownerPrefix), ownerOutput.hasSuffix("'") else {
      return true
    }
    let ownerName = String(ownerOutput.dropFirst(ownerPrefix.count).dropLast())
    guard ownerName == expectedUsername.lowercased(), Self.validAccount(ownerName) else {
      return true
    }
    return false
  }

  // MARK: - Command and parser helpers

  private func runStatus(
    _ command: PommeSecurityOwnerPTYCommand,
    kind: PommeSecurityOwnerCommandKind,
    acceptedExitCodes: Set<Int32>
  ) throws -> Int32 {
    let result = try execute(command)
    guard acceptedExitCodes.contains(result.exitCode) else {
      throw PommeSecurityOwnerPreparationError.commandFailed(kind, exitCode: Int(result.exitCode))
    }
    return result.exitCode
  }

  private func phase(
    _ phase: PommeSecurityOwnerPreparationPhase,
    _ event: PommeSecurityOwnerPreparationEvent
  ) throws {
    do {
      try reportPhase(phase, event)
    } catch {
      // A parent callback is allowed to use its own journal error type,
      // but this boundary must never forward arbitrary text alongside a
      // credential-bearing operation.
      throw PommeSecurityOwnerPreparationError.phaseCallbackFailed
    }
  }

  private func run(
    _ command: PommeSecurityOwnerPTYCommand,
    kind: PommeSecurityOwnerCommandKind,
    acceptedExitCodes: Set<Int32>
  ) throws -> String {
    let result = try execute(command)
    guard acceptedExitCodes.contains(result.exitCode) else {
      throw PommeSecurityOwnerPreparationError.commandFailed(kind, exitCode: Int(result.exitCode))
    }
    guard result.stdout.utf8.count <= 4 * 1024 * 1024 else {
      throw PommeSecurityOwnerPreparationError.evidenceUnavailable(kind.evidenceKind)
    }
    return result.stdout
  }

  /// A small number of native tools report their human-readable diagnostic on
  /// stderr even when the command succeeds. Only those callers use this
  /// combined stream; structured plist and record probes continue to parse
  /// stdout alone.
  private func runCombinedOutput(
    _ command: PommeSecurityOwnerPTYCommand,
    kind: PommeSecurityOwnerCommandKind,
    acceptedExitCodes: Set<Int32>
  ) throws -> String {
    let result = try execute(command)
    guard acceptedExitCodes.contains(result.exitCode) else {
      throw PommeSecurityOwnerPreparationError.commandFailed(kind, exitCode: Int(result.exitCode))
    }
    guard result.output.utf8.count <= 4 * 1024 * 1024 else {
      throw PommeSecurityOwnerPreparationError.evidenceUnavailable(kind.evidenceKind)
    }
    return result.output
  }

  private func runStdout(
    _ command: PommeSecurityOwnerPTYCommand,
    kind: PommeSecurityOwnerCommandKind,
    acceptedExitCodes: Set<Int32>
  ) throws -> String {
    let result = try execute(command)
    guard acceptedExitCodes.contains(result.exitCode) else {
      throw PommeSecurityOwnerPreparationError.commandFailed(kind, exitCode: Int(result.exitCode))
    }
    guard result.output.utf8.count <= 4 * 1024 * 1024 else {
      throw PommeSecurityOwnerPreparationError.evidenceUnavailable(kind.evidenceKind)
    }
    return result.stdout
  }

  private func execute(_ command: PommeSecurityOwnerPTYCommand) throws -> (
    exitCode: Int32,
    output: String,
    stdout: String,
    stderr: String
  ) {
    let request = GuestCommandRequest(
      path: command.executable,
      arguments: command.arguments,
      timeout: Self.commandTimeout
    )
    let result: GuestCommandResult
    do {
      result = try executeGuest(request)
    } catch {
      throw PommeSecurityOwnerPreparationError.evidenceUnavailable(command.kind.evidenceKind)
    }
    guard !result.detached, result.exited, !result.timedOut,
      result.signal == nil,
      !result.stdoutTruncated,
      !result.stderrTruncated,
      let rawExitCode = result.exitCode,
      let exitCode = Int32(exactly: rawExitCode)
    else {
      throw PommeSecurityOwnerPreparationError.evidenceUnavailable(command.kind.evidenceKind)
    }
    return (
      exitCode,
      String(decoding: result.stdout + result.stderr, as: UTF8.self),
      String(decoding: result.stdout, as: UTF8.self),
      String(decoding: result.stderr, as: UTF8.self)
    )
  }

  private static func parseProcessIdentities(
    _ output: String
  ) throws -> [SetupAssistantProcessIdentity] {
    var processes: [SetupAssistantProcessIdentity] = []
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      let fields = line.split(maxSplits: 7, whereSeparator: \.isWhitespace)
      guard fields.count == 8,
        let rawPID = Int64(String(fields[0])),
        fields[0].utf8.count <= 10,
        let processID = Int32(exactly: rawPID),
        processID > 0,
        String(processID) == String(fields[0]),
        let rawUID = UInt64(String(fields[1])),
        rawUID <= UInt64(UInt32.max),
        let userID = UInt32(exactly: rawUID)
      else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }

      let startIdentity = fields[2...6].map(String.init).joined(separator: " ")
      let executablePath = String(fields[7]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !startIdentity.isEmpty,
        !executablePath.isEmpty
      else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }
      processes.append(
        .init(
          processID: processID,
          userID: userID,
          executablePath: executablePath,
          startIdentity: startIdentity))
    }
    guard !processes.isEmpty else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    return processes
  }

  private static func parseSetupAssistantProcesses(
    _ output: String
  ) throws -> [SetupAssistantProcessIdentity] {
    let processes = try parseProcessIdentities(output)
    let candidates = processes.filter { $0.executablePath == setupAssistantExecutablePath }
    guard candidates.count == 1 else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    return candidates
  }

  private static func isEnglishLanguageReadback(_ output: String) -> Bool {
    let lines = output.split(whereSeparator: \.isNewline).map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard lines.count == 3, lines[0] == "(", lines[2] == ")" else { return false }
    return lines[1] == "en"
  }

  private static func parseSetupAssistantGUIDomain(
    _ output: String, expectedUID: UInt32
  ) throws -> SetupAssistantLaunchdContext {
    let lines = try launchdPrintLines(output)
    let header = try launchdDomainHeaderLines(lines)
    let handle = try exactlyOneUnsignedField(header, key: "handle")
    let security = try exactlyOneSecurityContext(lines)
    guard header.first == "gui/\(expectedUID) = {",
      exactlyOne(header, equals: "type = login"),
      exactlyOne(header, equals: "session = Aqua"),
      security.userID == expectedUID
    else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }
    return .init(
      handle: handle,
      sessionType: "Aqua",
      userID: security.userID,
      auditSessionID: security.auditSessionID
    )
  }

  private static func parseSetupAssistantPIDDomain(
    _ output: String, expectedPID: Int32, expectedOriginator: String
  ) throws -> SetupAssistantLaunchdContext {
    let lines = try launchdPrintLines(output)
    let header = try launchdDomainHeaderLines(lines)
    let handle = try exactlyOneUnsignedField(header, key: "handle")
    let creatorUID = try exactlyOneUnsignedField(header, key: "creator euid")
    let uniqueID = try exactlyOneUnsignedField(header, key: "uniqueid")
    let security = try exactlyOneSecurityContext(lines)
    guard header.first == "pid/\(expectedPID) = {",
      exactlyOne(header, equals: "type = pid"),
      handle == UInt64(expectedPID),
      exactlyOne(header, equals: "originator = \(expectedOriginator)"),
      creatorUID == Self.setupAssistantUID,
      uniqueID == UInt64(expectedPID),
      security.userID == Self.setupAssistantUID
    else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }
    return .init(
      handle: handle,
      sessionType: "",
      userID: security.userID,
      auditSessionID: security.auditSessionID
    )
  }

  private static func launchdPrintLines(_ output: String) throws -> [String] {
    guard output.utf8.count <= 1024 * 1024 else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    let lines = output.split(whereSeparator: \.isNewline).map { rawLine in
      rawLine.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    guard !lines.isEmpty, lines.last == "}" else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    return lines
  }

  private static func launchdDomainHeaderLines(_ lines: [String]) throws -> [String] {
    guard let securityIndex = lines.firstIndex(of: "security context = {") else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    guard securityIndex > 0 else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    return Array(lines[..<securityIndex])
  }

  private static func exactlyOne(_ lines: [String], equals expected: String) -> Bool {
    lines.lazy.filter { $0 == expected }.count == 1
  }

  private static func exactlyOneUnsignedField(
    _ lines: [String], key: String
  ) throws -> UInt64 {
    let prefix = "\(key) = "
    let matchingLines = lines.filter { $0.hasPrefix(prefix) }
    guard matchingLines.count == 1, let line = matchingLines.first else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    let rawValue = String(line.dropFirst(prefix.count))
    guard rawValue.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
      let value = UInt64(rawValue)
    else {
      throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable
    }
    return value
  }

  private static func exactlyOneSecurityContext(
    _ lines: [String]
  ) throws -> (userID: UInt32, auditSessionID: UInt64) {
    let starts = lines.indices.filter { lines[$0] == "security context = {" }
    guard starts.count == 1, let index = starts.first,
      index + 3 < lines.count,
      lines[index + 3] == "}"
    else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }
    let uidLine = lines[index + 1]
    let asidLine = lines[index + 2]
    guard uidLine.hasPrefix("uid = "), asidLine.hasPrefix("asid = "),
      let rawUID = UInt64(uidLine.dropFirst("uid = ".count)),
      rawUID <= UInt64(UInt32.max),
      let userID = UInt32(exactly: rawUID),
      let auditSessionID = UInt64(asidLine.dropFirst("asid = ".count)),
      auditSessionID > 0
    else { throw PommeSecurityOwnerPreparationError.setupAssistantContextUnavailable }
    return (userID, auditSessionID)
  }

  private static func parseUserNames(_ output: String) throws -> [(name: String, uniqueID: Int64?)]
  {
    var names: [(name: String, uniqueID: Int64?)] = []
    var seen = Set<String>()
    var seenIDs = Set<Int64>()
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      guard let name = line.split(whereSeparator: \.isWhitespace).first.map(String.init),
        validAccount(name),
        !seen.contains(name)
      else { throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers) }
      let fields = line.split(whereSeparator: \.isWhitespace)
      let uniqueID: Int64?
      if fields.count == 1 {
        uniqueID = nil
      } else {
        guard fields.count == 2 else {
          throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)
        }
        let rawID = String(fields[1])
        if rawID == "-2" {
          guard name == "nobody" else {
            throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)
          }
          uniqueID = -2
        } else {
          guard rawID.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
            let value = UInt32(rawID)
          else {
            throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)
          }
          uniqueID = Int64(value)
        }
      }
      if let uniqueID, !seenIDs.insert(uniqueID).inserted {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)
      }
      seen.insert(name)
      names.append((name, uniqueID))
    }
    guard !names.isEmpty else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)
    }
    return names
  }

  private static func parseGeneratedUIDs(_ output: String) throws -> [String: UUID] {
    var generatedUIDs: [String: UUID] = [:]
    var seenUUIDs = Set<UUID>()
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count == 2,
        let name = fields.first.map(String.init),
        validAccount(name),
        generatedUIDs[name] == nil,
        let generatedUID = UUID(uuidString: String(fields[1])),
        seenUUIDs.insert(generatedUID).inserted
      else { throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers) }
      generatedUIDs[name] = generatedUID
    }
    guard !generatedUIDs.isEmpty else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)
    }
    return generatedUIDs
  }

  private static func isDeterministicSystemGeneratedUID(
    _ generatedUID: UUID,
    uniqueID: Int64
  ) -> Bool {
    let unsignedID: UInt32
    if uniqueID == -2 {
      unsignedID = UInt32.max - 1
    } else {
      guard uniqueID >= 0, uniqueID < 500,
        let value = UInt32(exactly: uniqueID)
      else { return false }
      unsignedID = value
    }
    let expected = String(
      format: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA%08X",
      unsignedID
    )
    return generatedUID.uuidString.caseInsensitiveCompare(expected) == .orderedSame
  }

  private static func parseLocalUser(
    _ output: String,
    expectedName: String,
    expectedGeneratedUID: UUID? = nil,
    isKnownSystemAccount: Bool = false
  ) throws -> PommeSecurityOwnerLocalUser {
    var fields: [String: String] = [:]
    var currentKey: String?
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      if let separator = line.firstIndex(of: ":") {
        let key = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, fields[key] == nil else {
          throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUserRecord)
        }
        fields[key] = value
        currentKey = key
      } else if let currentKey {
        fields[currentKey, default: ""] += " " + line
      } else {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUserRecord)
      }
    }

    guard let recordName = fields["RecordName"],
      recordName == expectedName,
      let realName = fields["RealName"],
      !realName.isEmpty,
      let generated = fields["GeneratedUID"],
      generated.split(whereSeparator: \.isWhitespace).count == 1,
      let generatedUID = UUID(uuidString: generated),
      expectedGeneratedUID == nil || generatedUID == expectedGeneratedUID,
      let rawID = fields["UniqueID"],
      rawID.split(whereSeparator: \.isWhitespace).count == 1,
      let home = fields["NFSHomeDirectory"],
      home.hasPrefix("/"),
      !home.contains("\0"),
      URL(fileURLWithPath: home).standardizedFileURL.path == home
    else { throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUserRecord) }

    let uniqueID: Int64
    if rawID == "-2" {
      guard recordName == "nobody" else {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUserRecord)
      }
      uniqueID = -2
    } else {
      guard rawID.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
        let value = UInt32(rawID)
      else {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUserRecord)
      }
      uniqueID = Int64(value)
    }

    return .init(
      recordName: recordName,
      realName: realName,
      generatedUID: generatedUID,
      uniqueID: uniqueID,
      homeDirectory: home,
      isKnownSystemAccount: isKnownSystemAccount
    )
  }

  private static func parseAPFSUsers(
    _ output: String,
    expectedDevice: String? = nil
  ) throws -> [PommeSecurityOwnerAPFSUser] {
    let data = Data(output.utf8)
    if let object = try? PropertyListSerialization.propertyList(from: data, format: nil) {
      return try parseAPFSUsersPropertyList(object)
    }

    let lines = output.split(whereSeparator: \.isNewline).map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let header = lines.first?.lowercased() else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
    }

    if let device = parseAPFSNoUsersDevice(from: header) {
      guard lines.count == 1,
        expectedDevice == nil || device == expectedDevice
      else { throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers) }
      return []
    }

    guard let (device, declaredCount) = parseAPFSUsersHeader(from: header),
      expectedDevice == nil || device == expectedDevice
    else { throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers) }

    let uuidRegex = try! NSRegularExpression(
      pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )
    var users: [PommeSecurityOwnerAPFSUser] = []
    var seen = Set<UUID>()
    var index = 1
    if declaredCount == 0 {
      guard lines.dropFirst().allSatisfy(\.isEmpty) else {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
      }
      return []
    }
    while index < lines.count {
      let line = lines[index]
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      guard let match = uuidRegex.firstMatch(in: line, range: range),
        let matchRange = Range(match.range, in: line),
        let uuid = UUID(uuidString: String(line[matchRange]))
      else {
        index += 1
        continue
      }
      guard seen.insert(uuid).inserted else {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
      }
      var type: String?
      var volumeOwner: Bool?
      var next = index + 1
      while next < lines.count {
        let candidate = lines[next]
        if uuidRegex.firstMatch(
          in: candidate,
          range: NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        ) != nil {
          break
        }
        if let field = parseAPFSField(candidate),
          field.key.caseInsensitiveCompare("type") == .orderedSame
        {
          guard type == nil else {
            throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
          }
          type = field.value
        } else if let field = parseAPFSField(candidate),
          field.key.caseInsensitiveCompare("volume owner") == .orderedSame
        {
          guard volumeOwner == nil else {
            throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
          }
          let value = field.value.lowercased()
          guard ["yes", "no"].contains(value) else {
            throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
          }
          volumeOwner = value == "yes"
        }
        next += 1
      }
      guard let type, !type.isEmpty, let volumeOwner else {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
      }
      users.append(
        .init(
          generatedUID: uuid,
          kind: try apfsKind(for: type),
          volumeOwner: volumeOwner
        ))
      index = next
    }

    guard users.count == declaredCount else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
    }
    return users
  }

  /// Diskutil's plist output is accepted only when one authoritative user
  /// collection is present. Recursing for arbitrary UUID-shaped dictionaries
  /// would allow an unrelated empty collection to be mistaken for proof that
  /// the startup volume has no APFS owners.
  private static func parseAPFSUsersPropertyList(_ object: Any) throws
    -> [PommeSecurityOwnerAPFSUser]
  {
    guard object is [String: Any] else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
    }

    var collections: [[Any]] = []
    var sawUnknownUserCollection = false
    func visit(_ value: Any) {
      guard let dictionary = value as? [String: Any] else {
        if let array = value as? [Any] {
          for child in array { visit(child) }
        }
        return
      }

      for (key, child) in dictionary {
        let normalizedKey = key.lowercased()
        if Self.apfsUserCollectionKeys.contains(normalizedKey) {
          guard let values = child as? [Any] else {
            sawUnknownUserCollection = true
            continue
          }
          collections.append(values)
          // User records may contain `UserType` and `UserUUID`; do
          // not interpret those scalar fields as nested collections.
          for record in values {
            if let recordDictionary = record as? [String: Any] {
              for recordChild in recordDictionary.values {
                if let recordArray = recordChild as? [Any] {
                  for nested in recordArray { visit(nested) }
                }
              }
            }
          }
        } else {
          if normalizedKey.contains("user"),
            child is [Any] || child is [String: Any]
          {
            sawUnknownUserCollection = true
          }
          visit(child)
        }
      }
    }
    visit(object)

    guard !sawUnknownUserCollection, collections.count == 1,
      let values = collections.first
    else {
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
    }

    var users: [PommeSecurityOwnerAPFSUser] = []
    var seen = Set<UUID>()
    users.reserveCapacity(values.count)
    for value in values {
      guard let dictionary = value as? [String: Any] else {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
      }
      let uuidValues = apfsStringValues(
        in: dictionary,
        keys: ["GeneratedUID", "UUID", "UserUUID"]
      )
      let typeValues = apfsStringValues(
        in: dictionary,
        keys: ["Type", "UserType"]
      )
      let volumeOwnerValues = apfsOwnerValues(in: dictionary)
      guard uuidValues.count == 1,
        let uuid = UUID(uuidString: uuidValues[0]),
        typeValues.count == 1,
        !typeValues[0].isEmpty,
        volumeOwnerValues.count == 1,
        seen.insert(uuid).inserted
      else {
        throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
      }
      users.append(
        .init(
          generatedUID: uuid,
          kind: try apfsKind(for: typeValues[0]),
          volumeOwner: volumeOwnerValues[0]
        ))
    }
    return users
  }

  private static let apfsUserCollectionKeys: Set<String> = [
    "users", "cryptousers", "apfsusers",
  ]

  private static func apfsStringValues(
    in dictionary: [String: Any],
    keys: [String]
  ) -> [String] {
    keys.compactMap { dictionary[$0] as? String }
  }

  private static func apfsOwnerValues(in dictionary: [String: Any]) -> [Bool] {
    ["VolumeOwner", "IsVolumeOwner", "Volume Owner"].compactMap { key in
      if let value = dictionary[key] as? Bool { return value }
      if let value = dictionary[key] as? NSNumber, value.intValue == 0 || value.intValue == 1 {
        return value.boolValue
      }
      if let value = dictionary[key] as? String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
        }
      }
      return nil
    }
  }

  private static func apfsKind(
    for value: String
  ) throws -> PommeSecurityOwnerAPFSUser.Kind {
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      .lowercased()
    switch normalized {
    case "local open directory user": return .localOpenDirectoryUser
    case "disk user", "icloud user", "recovery user", "institutional recovery user",
      "personal recovery user":
      return .other
    default:
      throw PommeSecurityOwnerPreparationError.malformedEvidence(.apfsUsers)
    }
  }

  private static func parseAPFSNoUsersDevice(from header: String) -> String? {
    let fields = header.split(whereSeparator: \.isWhitespace)
    guard fields.count == 5,
      fields[0] == "no",
      fields[1] == "cryptographic",
      fields[2] == "users",
      fields[3] == "for"
    else { return nil }
    let device = String(fields[4])
    return validDevice(device) ? device : nil
  }

  private static func parseAPFSField(_ line: String) -> (key: String, value: String)? {
    let content: Substring
    if line.first == "|" {
      let remainder = line.dropFirst()
      guard remainder.first == " " || remainder.first == "\t" else { return nil }
      content = remainder.drop(while: { $0 == " " || $0 == "\t" })
    } else {
      content = line.drop(while: { $0 == " " || $0 == "\t" })
    }
    guard let separator = content.firstIndex(of: ":") else { return nil }
    let key = String(content[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
    let value = String(content[content.index(after: separator)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    return (key, value)
  }

  private static func parseAPFSUsersHeader(from header: String) -> (device: String, count: Int)? {
    let pattern =
      #"^cryptographic users? for (disk[0-9]+(?:s[0-9]+)+) \((\d+)\s+(?:found|users?)\)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: header,
        range: NSRange(header.startIndex..<header.endIndex, in: header)
      ),
      let deviceRange = Range(match.range(at: 1), in: header),
      let countRange = Range(match.range(at: 2), in: header),
      let count = Int(header[countRange])
    else { return nil }
    let device = String(header[deviceRange])
    guard validDevice(device) else { return nil }
    return (device, count)
  }

  private static func validAccount(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil
  }

  private static func validDevice(_ value: String) -> Bool {
    guard value.hasPrefix("disk") else { return false }
    let suffix = value.dropFirst(4)
    let components = suffix.split(separator: "s", omittingEmptySubsequences: true)
    guard components.count >= 2 else { return false }
    return components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func normalized(_ value: String) -> String { Self.normalized(value) }
}

extension PommeSecurityOwnerCommandKind {
  fileprivate var evidenceKind: PommeSecurityOwnerEvidenceKind {
    switch self {
    case .setupAssistant, .finishSetupAssistant: .setupAssistant
    case .listLocalUsers: .localUsers
    case .readLocalUser: .localUserRecord
    case .startupVolumeGroups, .startupVolumeInfo: .startupVolume
    case .apfsUsers: .apfsUsers
    case .secureToken: .secureToken
    case .administratorMembership: .administratorMembership
    case .accountID: .accountIdentity
    case .createOwner: .accountIdentity
    case .fileVault: .fileVault
    case .ownerCompletion: .loginWindow
    case .loginWindow, .managedLoginWindow, .autoLogin: .loginWindow
    case .autoLoginSupport: .autoLoginSupport
    }
  }
}

extension PommeSecurityOwnerPTYCommand {
  fileprivate var kind: PommeSecurityOwnerCommandKind {
    switch executable {
    case "/usr/bin/fdesetup": .fileVault
    case "/bin/test":
      arguments.contains("/var/db/.AppleSetupDone")
        ? .setupAssistant
        : arguments.contains("/etc/kcpassword") ? .loginWindow : .managedLoginWindow
    case "/usr/bin/dscl": arguments.contains("-list") ? .listLocalUsers : .readLocalUser
    case "/usr/sbin/diskutil":
      arguments.contains("listVolumeGroups")
        ? .startupVolumeGroups : arguments.contains("listUsers") ? .apfsUsers : .startupVolumeInfo
    case "/usr/sbin/sysadminctl":
      arguments.contains("-help")
        ? .autoLoginSupport : arguments.contains("-secureTokenStatus") ? .secureToken : .autoLogin
    case "/usr/bin/dsmemberutil": .administratorMembership
    case "/usr/bin/id": .accountID
    case "/usr/bin/defaults": .loginWindow
    case "/usr/bin/install", "/bin/rm": .finishSetupAssistant
    case "/bin/sync": .finishSetupAssistant
    case "/bin/ps", "/bin/launchctl", "/usr/bin/sw_vers", "/bin/kill": .setupAssistant
    case "/usr/bin/sudo": .loginWindow
    case "/usr/bin/find": .managedLoginWindow
    case "/usr/bin/profiles": .managedLoginWindow
    case "/usr/bin/stat": .loginWindow
    default: .loginWindow
    }
  }
}
