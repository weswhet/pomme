import Foundation

/// Closed context for read-only normal-boot proof failures. The values are
/// intentionally independent of the guest response and never carry command
/// output, arguments, or transport descriptions.
enum PommeSecurityNormalAgentProofStage: String, CaseIterable, Sendable {
  case console
  case aqua
  case processList = "ps"
}

enum PommeSecurityNormalAgentFailureReason: String, CaseIterable, Sendable {
  case timedOut
  case outputTruncated
  case incomplete
  case invalidEnvelope
  case transport
}

struct PommeSecurityNormalAgentDiagnostic: Error, Equatable, LocalizedError, Sendable {
  let stage: PommeSecurityNormalAgentProofStage
  let reason: PommeSecurityNormalAgentFailureReason

  /// A stable allowlisted value suitable for a bounded log or a caller's
  /// closed diagnostic field. It contains no guest-provided text.
  var code: String {
    "normal-agent-\(stage.rawValue)-\(reason.rawValue)"
  }

  var errorDescription: String? {
    "Normal agent verification failed (\(code))."
  }
}

/// Closed failures for the credential-free normal-boot AMFI adapter. The
/// unsupported case is intentionally distinct from an authentication failure:
/// an older creation-pinned daemon must be reported as requiring an explicit
/// new VM/agent, never silently replaced.
enum PommeSecurityNormalAgentError: Error, Equatable, LocalizedError, Sendable {
  case invalidAMFIOperation
  case unsupportedAMFIWorkflow
  case unverifiedAMFIResponse
  case invalidRebootTimeout
  case bootIdentityUnavailable
  case rebootRequestFailed
  case rebootDidNotStop
  case rebootStartFailed
  case rebootBootIdentityUnchanged
  case rebootAgentUnverified

  var errorDescription: String? {
    switch self {
    case .invalidAMFIOperation:
      "The requested normal-agent AMFI operation is not supported."
    case .unsupportedAMFIWorkflow:
      "The VM's creation-pinned Pomme agent does not support the normal-boot AMFI workflow. Create a VM with a Pomme build that includes this capability; the pinned agent was not replaced."
    case .unverifiedAMFIResponse:
      "The normal-agent AMFI operation could not be verified; the security transaction was retained."
    case .invalidRebootTimeout:
      "The native reboot verification timeout is invalid or exceeds the bounded limit."
    case .bootIdentityUnavailable:
      "The normal-boot identity could not be verified; the security transaction was retained."
    case .rebootRequestFailed:
      "The native normal-boot reboot request could not be verified; the security transaction was retained."
    case .rebootDidNotStop:
      "The native reboot did not produce a verified stopped VM within the bounded window; the security transaction was retained."
    case .rebootStartFailed:
      "The VM could not be restarted in normal mode after a verified native reboot; the security transaction was retained."
    case .rebootBootIdentityUnchanged:
      "The native reboot did not produce a different verified boot identity; the security transaction was retained."
    case .rebootAgentUnverified:
      "The creation-pinned normal agent could not be reauthenticated after the native reboot; the security transaction was retained."
    }
  }
}

/// Host-only effects used by the bounded native reboot adapter. The default
/// implementation is backed by PommeCore; tests inject this seam so they can
/// prove the state machine without starting a VM. None of these closures carry
/// credentials or guest process output.
struct PommeSecurityNormalAgentRebootHooks: Sendable {
  let authenticate: @Sendable (_ timeout: TimeInterval) async throws -> Void
  let captureBootIdentity: @Sendable (_ timeout: TimeInterval) throws -> String
  let scheduleReboot: @Sendable (_ timeout: TimeInterval) throws -> Void
  let observeRunState: @Sendable () throws -> VMRunStateSnapshot
  let startNormal: @Sendable (_ timeout: TimeInterval) async throws -> Void
  let now: @Sendable () -> Date
  let sleep: @Sendable (_ interval: TimeInterval) async throws -> Void

  init(
    authenticate: @escaping @Sendable (_ timeout: TimeInterval) async throws -> Void,
    captureBootIdentity: @escaping @Sendable (_ timeout: TimeInterval) throws -> String,
    scheduleReboot: @escaping @Sendable (_ timeout: TimeInterval) throws -> Void,
    observeRunState: @escaping @Sendable () throws -> VMRunStateSnapshot,
    startNormal: @escaping @Sendable (_ timeout: TimeInterval) async throws -> Void,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (_ interval: TimeInterval) async throws -> Void = { interval in
      let milliseconds = Int64(max(1, min(interval, 60) * 1_000))
      try await Task.sleep(for: .milliseconds(milliseconds))
    }
  ) {
    self.authenticate = authenticate
    self.captureBootIdentity = captureBootIdentity
    self.scheduleReboot = scheduleReboot
    self.observeRunState = observeRunState
    self.startNormal = startNormal
    self.now = now
    self.sleep = sleep
  }
}

/// Security preparation talks to the existing authenticated persistent agent.
/// No installation, update, credential replacement, or creation-record rewrite
/// is reachable from this adapter.
struct PommeSecurityNormalAgent: Sendable {
  let reference: VMReference
  let expectedExecutableDigest: String
  private let rebootHooks: PommeSecurityNormalAgentRebootHooks?

  init(
    reference: VMReference,
    expectedExecutableDigest: String,
    rebootHooks: PommeSecurityNormalAgentRebootHooks? = nil
  ) {
    self.reference = reference
    self.expectedExecutableDigest = expectedExecutableDigest
    self.rebootHooks = rebootHooks
  }

  /// Native reboot is intentionally bounded even when a caller supplies a
  /// larger value. A reboot request is detached, so the host must observe the
  /// VM state and a changed boot identity rather than waiting on that process.
  static let maximumRebootTimeout: TimeInterval = 300
  private static let rebootRequestTimeout: TimeInterval = 15
  private static let bootIdentityRequestTimeout: TimeInterval = 15
  private static let rebootPollInterval: TimeInterval = 0.25
  private static let maximumBootIdentityBytes = 4 * 1024

  /// Host-only control payload marker. The VM helper consumes this marker
  /// while it pins and describes the authenticated normal session; it is
  /// stripped before the exact guest operation payload is sent.
  static let normalAMFIDigestMarker = "_pommeExpectedNormalAMFIExecutableSHA256"

  static let normalAMFIOperations: Set<String> = [
    "amfi.normal.disable",
    "amfi.normal.enable",
    "amfi.normal.verifyDisabled",
    "amfi.normal.verifyEnabled",
  ]

  static let normalAMFIWorkflowVersion = 1

  /// Checks the opt-in `agent.describe` receipt without accepting host-side
  /// numeric coercions or guest-controlled text. This pure seam lets callers
  /// preflight before the Recovery policy effect while `performAMFI` repeats
  /// the same check inside the helper's pinned-session transaction.
  static func supportsNormalAMFIWorkflow(
    _ description: [String: Any], expectedExecutableDigest: String
  ) -> Bool {
    guard description["role"] as? String == "persistent",
      description["protocol"] as? String == PommeAgentProtocol.name,
      integerValue(description["version"]) == Int64(PommeAgentProtocol.version),
      description["executableSHA256"] as? String == expectedExecutableDigest,
      integerValue(description["normalAMFIWorkflowVersion"]) == Int64(normalAMFIWorkflowVersion),
      let rawCapabilities = description["capabilities"] as? [Any],
      rawCapabilities.allSatisfy({ $0 is String })
    else { return false }
    let capabilities = Set(rawCapabilities.compactMap { $0 as? String })
    return capabilities.isSuperset(of: normalAMFIOperations)
  }

  /// Require support before policy mutation. A later `performAMFI` call still
  /// performs its own same-session capability and digest proof because a
  /// separate preflight request cannot pin a future connection by itself.
  func requireAMFIWorkflowSupport() throws {
    guard PommeProvisioningDigest.isSHA256(expectedExecutableDigest),
      expectedExecutableDigest == expectedExecutableDigest.lowercased(),
      try PommeCore.stableVMRunState(reference: reference) == .running(.normal)
    else { throw PommeSecurityWorkflowError.agentUnverified }

    let response: [String: Any]
    do {
      response = try PommeCore.sendControlObject([
        "command": "agent.perform",
        "operation": "agent.describe",
        "payload": ["includeNormalAMFICapabilities": true],
      ], bundle: reference.bundle)
    } catch {
      throw PommeSecurityWorkflowError.agentUnverified
    }
    guard response["ok"] as? Bool == true,
      let rawResult = response["result"],
      let result = try? JSONValue(any: rawResult),
      let description = result.objectValue
    else { throw PommeSecurityWorkflowError.agentUnverified }
    guard Self.supportsNormalAMFIWorkflow(
      description.mapValues(\.publicValue), expectedExecutableDigest: expectedExecutableDigest
    ) else {
      // The describe response was reachable but did not advertise the closed
      // operation/version. This is the actionable old-pinned-agent case.
      throw PommeSecurityNormalAgentError.unsupportedAMFIWorkflow
    }
  }

  /// Executes one credential-free normal-boot AMFI stage through the helper's
  /// authenticated pinned session. The helper must describe and verify the
  /// exact persistent role/protocol/digest/capability on that same session
  /// before forwarding the stripped payload to PommeAgent.
  func performAMFI(operation: String, volumeGroupUUID: UUID) throws -> JSONValue {
    guard Self.normalAMFIOperations.contains(operation) else {
      throw PommeSecurityNormalAgentError.invalidAMFIOperation
    }
    guard PommeProvisioningDigest.isSHA256(expectedExecutableDigest),
      expectedExecutableDigest == expectedExecutableDigest.lowercased(),
      try PommeCore.stableVMRunState(reference: reference) == .running(.normal)
    else { throw PommeSecurityWorkflowError.agentUnverified }

    let response: [String: Any]
    do {
      response = try PommeCore.sendControlObject([
        "command": "agent.perform",
        "operation": operation,
        "payload": [
          "volumeGroupUUID": volumeGroupUUID.uuidString.lowercased(),
          Self.normalAMFIDigestMarker: expectedExecutableDigest,
        ],
      ], bundle: reference.bundle)
    } catch {
      throw PommeSecurityNormalAgentError.unverifiedAMFIResponse
    }
    if response["ok"] as? Bool != true {
      if response["failureCode"] as? String == "unsupported-operation" {
        throw PommeSecurityNormalAgentError.unsupportedAMFIWorkflow
      }
      throw PommeSecurityNormalAgentError.unverifiedAMFIResponse
    }
    guard let rawResult = response["result"],
      let result = try? JSONValue(any: rawResult),
      let object = result.objectValue,
      object["verified"] == .bool(true),
      object["operation"] == .string(operation)
    else { throw PommeSecurityNormalAgentError.unverifiedAMFIResponse }
    return result
  }

  func authenticate(timeout: TimeInterval = 120, requirePrivateInput: Bool = false) async throws {
    guard try PommeCore.stableVMRunState(reference: reference) == .running(.normal) else {
      throw PommeSecurityWorkflowError.agentUnverified
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while true {
      do {
        let response = try PommeCore.sendControlObject(
          [
            "command": "agent.perform", "operation": "agent.describe",
            "payload": requirePrivateInput ? ["includePrivatePTYCapabilities": true] : [:],
          ], bundle: reference.bundle)
        guard response["ok"] as? Bool == true,
          let result = response["result"],
          let object = try JSONValue(any: result).objectValue,
          object["protocol"] == .string(PommeAgentProtocol.name),
          object["role"] == .string("persistent"),
          object["version"] == .integer(Int64(PommeAgentProtocol.version)),
          object["executableSHA256"] == .string(expectedExecutableDigest),
          case .array(let capabilities)? = object["capabilities"],
          Set(capabilities.compactMap(\.stringValue)).isSuperset(of: [
            "process.start", "process.status", "process.signal",
          ])
        else { throw PommeSecurityWorkflowError.agentUnverified }
        if requirePrivateInput, object["privatePTYInputVersion"] != .integer(1) {
          throw PommeSecurityWorkflowError.privateInputUnsupported
        }
        return
      } catch {
        if (error as? PommeSecurityWorkflowError) == .privateInputUnsupported { throw error }
        guard ContinuousClock.now < deadline else {
          throw PommeSecurityWorkflowError.agentUnverified
        }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  /// Reads the current macOS boot-session identity through the authenticated
  /// normal agent. The identity is a UUID emitted by `sysctl`; no guest output
  /// is included in a thrown error or log.
  func currentBootIdentity() throws -> String {
    if let rebootHooks {
      do {
        let identity = try rebootHooks.captureBootIdentity(Self.bootIdentityRequestTimeout)
        return try Self.validatedBootIdentity(identity)
      } catch let error as PommeSecurityNormalAgentError {
        throw error
      } catch {
        throw PommeSecurityNormalAgentError.bootIdentityUnavailable
      }
    }
    do {
      return try readBootIdentity(timeout: Self.bootIdentityRequestTimeout)
    } catch let error as PommeSecurityNormalAgentError {
      throw error
    } catch {
      throw PommeSecurityNormalAgentError.bootIdentityUnavailable
    }
  }

  /// Performs a native guest reboot and proves that the same creation-pinned
  /// normal agent returns from a different boot. The reboot process is
  /// detached intentionally: its completion is not treated as a reboot proof.
  /// Some guests keep the host helper alive while the native reboot occurs;
  /// others naturally end the helper. The adapter accepts either a running
  /// normal VM with a changed boot identity or a verified stopped VM followed
  /// by a guarded normal start. No failure path calls a stop operation.
  func rebootAndAuthenticate(timeout: TimeInterval = 180) async throws {
    guard timeout.isFinite, timeout > 0, timeout <= Self.maximumRebootTimeout else {
      throw PommeSecurityNormalAgentError.invalidRebootTimeout
    }

    let hooks = rebootHooks ?? makeDefaultRebootHooks()
    let deadline = hooks.now().addingTimeInterval(timeout)

    func remaining(_ cap: TimeInterval) throws -> TimeInterval {
      let value = min(cap, deadline.timeIntervalSince(hooks.now()))
      guard value > 0 else { throw PommeSecurityNormalAgentError.rebootDidNotStop }
      return value
    }

    do {
      try await hooks.authenticate(try remaining(120))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PommeSecurityNormalAgentError.rebootAgentUnverified
    }

    let originalBootIdentity: String
    do {
      originalBootIdentity = try Self.validatedBootIdentity(
        hooks.captureBootIdentity(try remaining(Self.bootIdentityRequestTimeout)))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PommeSecurityNormalAgentError.bootIdentityUnavailable
    }

    do {
      try hooks.scheduleReboot(try remaining(Self.rebootRequestTimeout))
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PommeSecurityNormalAgentError.rebootRequestFailed
    }

    var requiresNormalStart = false
    var sawRunningNormal = false
    var sawAuthenticatedBoot = false

    // First accept the in-place path. A running normal VM is not evidence
    // that the reboot failed: the native command can replace the guest boot
    // session without terminating the host runtime helper.
    while hooks.now() < deadline {
      try Task.checkCancellation()
      var state: VMRunStateSnapshot?
      do {
        state = try hooks.observeRunState()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A naturally exiting helper can briefly make status unavailable.
        // Keep polling within the same bounded window; no lifecycle effect is
        // attempted from this observation failure.
      }

      if state == .stopped {
        // Require two stopped observations before starting. If the helper has
        // already returned to running normal, continue through the in-place
        // proof path instead of invoking a lifecycle transition.
        do {
          let confirmation = try hooks.observeRunState()
          if confirmation == .stopped {
            requiresNormalStart = true
          } else {
            state = confirmation
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          state = nil
        }
      }

      if case .running(.normal)? = state {
        sawRunningNormal = true
        do {
          try await hooks.authenticate(try remaining(15))
          let current = try Self.validatedBootIdentity(
            hooks.captureBootIdentity(try remaining(Self.bootIdentityRequestTimeout)))
          sawAuthenticatedBoot = true
          if current != originalBootIdentity { return }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // The normal helper can need several polls after the native command
          // begins. Retry only within the original deadline.
        }
      }

      if requiresNormalStart { break }
      let interval = min(Self.rebootPollInterval, max(0, deadline.timeIntervalSince(hooks.now())))
      if interval > 0 { try await hooks.sleep(interval) }
    }

    if requiresNormalStart {
      // Recheck immediately before starting. This preserves the no-stop
      // guarantee if another lifecycle owner changed the state while polling.
      do {
        guard try hooks.observeRunState() == .stopped else {
          throw PommeSecurityNormalAgentError.rebootDidNotStop
        }
        try await hooks.startNormal(try remaining(Self.maximumRebootTimeout))
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as PommeSecurityNormalAgentError {
        throw error
      } catch {
        throw PommeSecurityNormalAgentError.rebootStartFailed
      }
    } else {
      if sawAuthenticatedBoot {
        throw PommeSecurityNormalAgentError.rebootBootIdentityUnchanged
      }
      if sawRunningNormal {
        throw PommeSecurityNormalAgentError.rebootAgentUnverified
      }
      throw PommeSecurityNormalAgentError.rebootDidNotStop
    }

    // The stopped path must reauthenticate after its guarded normal start and
    // still prove a different identity. An old identity is never accepted.
    var sawAuthenticatedAfterStart = false
    while hooks.now() < deadline {
      try Task.checkCancellation()
      do {
        try await hooks.authenticate(try remaining(15))
        let current = try Self.validatedBootIdentity(
          hooks.captureBootIdentity(try remaining(Self.bootIdentityRequestTimeout)))
        sawAuthenticatedAfterStart = true
        if current != originalBootIdentity { return }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // The normal helper can need several polls after the host starts it.
        // Keep the error closed and retry only within the original deadline.
      }
      let interval = min(Self.rebootPollInterval, max(0, deadline.timeIntervalSince(hooks.now())))
      if interval > 0 { try await hooks.sleep(interval) }
    }
    if sawAuthenticatedAfterStart || sawAuthenticatedBoot {
      throw PommeSecurityNormalAgentError.rebootBootIdentityUnchanged
    }
    throw PommeSecurityNormalAgentError.rebootAgentUnverified
  }

  /// The only process-start request that the reboot adapter can create.
  /// Callers receive a detached request with no arguments, environment, input,
  /// identity override, or shell wrapper.
  static func nativeRebootRequest(timeout: TimeInterval) -> GuestCommandRequest? {
    guard timeout.isFinite, timeout > 0 else { return nil }
    return .init(
      path: "/sbin/reboot",
      arguments: [],
      timeout: min(timeout, rebootRequestTimeout)
    )
  }

  /// Verifies only the bounded `process.start` acknowledgement for the native
  /// reboot. A detached acknowledgement is not process completion; the caller
  /// must still prove either a changed in-place identity or a stopped state
  /// followed by a changed identity after normal restart.
  static func isVerifiedDetachedRebootStart(_ response: [String: Any]) -> Bool {
    guard response["ok"] as? Bool == true,
      let rawResult = response["result"],
      let result = try? JSONValue(any: rawResult),
      let object = result.objectValue,
      object["detached"] == .bool(true),
      object["exited"] == .bool(false),
      case .integer(let pid)? = object["pid"],
      (1...Int64(Int32.max)).contains(pid),
      case .string(let jobID)? = object["jobID"],
      UUID(uuidString: jobID) != nil
    else { return false }
    return true
  }

  private func readBootIdentity(timeout: TimeInterval) throws -> String {
    let request = GuestCommandRequest(
      path: "/usr/sbin/sysctl",
      arguments: ["-n", "kern.bootsessionuuid"],
      timeout: min(max(timeout, 0.001), Self.bootIdentityRequestTimeout)
    )
    let result = try execute(request)
    guard result.exited, !result.detached, !result.timedOut,
      result.signal == nil, result.exitCode == 0,
      !result.stdoutTruncated, !result.stderrTruncated, result.stderr.isEmpty,
      let identity = Self.parseBootIdentity(result.stdout)
    else { throw PommeSecurityNormalAgentError.bootIdentityUnavailable }
    return identity
  }

  /// Strict parser for `kern.bootsessionuuid`; integer/process output and
  /// arbitrary text are never treated as a boot proof.
  static func parseBootIdentity(_ data: Data) -> String? {
    guard data.count <= maximumBootIdentityBytes,
      let raw = String(data: data, encoding: .utf8)
    else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let uuid = UUID(uuidString: value),
      value.lowercased() == uuid.uuidString.lowercased()
    else { return nil }
    return uuid.uuidString.lowercased()
  }

  private static func validatedBootIdentity(_ value: String) throws -> String {
    guard let identity = parseBootIdentity(Data(value.utf8)) else {
      throw PommeSecurityNormalAgentError.bootIdentityUnavailable
    }
    return identity
  }

  private func makeDefaultRebootHooks() -> PommeSecurityNormalAgentRebootHooks {
    let reference = self.reference
    let digest = self.expectedExecutableDigest
    return .init(
      authenticate: { timeout in
        try await Self(reference: reference, expectedExecutableDigest: digest)
          .authenticate(timeout: timeout)
      },
      captureBootIdentity: { timeout in
        try Self(reference: reference, expectedExecutableDigest: digest)
          .readBootIdentity(timeout: timeout)
      },
      scheduleReboot: { timeout in
        try Self.scheduleNativeReboot(reference: reference, timeout: timeout)
      },
      observeRunState: {
        try PommeCore.stableVMRunState(reference: reference)
      },
      startNormal: { _ in
        // This guard is deliberately repeated inside the start effect. The
        // adapter never invokes a host stop operation; if a concurrent
        // lifecycle owner made the VM running again, the start is rejected.
        // PommeCore's existing start bridge has its own bounded
        // `Constants.defaultRecoveryAgentTimeout` (300 seconds); callers that
        // need the tighter remaining-budget cap can inject this hook with a
        // timeout-aware lifecycle bridge.
        guard try PommeCore.stableVMRunState(reference: reference) == .stopped else {
          throw PommeSecurityNormalAgentError.rebootDidNotStop
        }
        try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
      }
    )
  }

  private static func scheduleNativeReboot(reference: VMReference, timeout: TimeInterval) throws {
    guard let request = nativeRebootRequest(timeout: timeout) else {
      throw PommeSecurityNormalAgentError.invalidRebootTimeout
    }
    let payload = try request.validatedControlPayload(detached: true)
    let response = try PommeCore.sendControlObject(payload, bundle: reference.bundle)
    guard isVerifiedDetachedRebootStart(response) else {
      throw PommeSecurityNormalAgentError.rebootRequestFailed
    }
  }

  func execute(_ request: GuestCommandRequest) throws -> GuestCommandResult {
    guard !request.pty, request.inputData == nil, request.environment.isEmpty else {
      throw PommeSecurityWorkflowError.agentUnverified
    }
    let response = try PommeCore.sendForegroundControlObject(
      request.controlPayload, bundle: reference.bundle)
    return try Self.decodeCompletedCommand(response)
  }

  /// Executes one of the bounded desktop-proof probes and propagates only a
  /// closed diagnostic when its response envelope is rejected.
  private func execute(
    _ request: GuestCommandRequest,
    proofStage: PommeSecurityNormalAgentProofStage
  ) throws -> GuestCommandResult {
    guard !request.pty, request.inputData == nil, request.environment.isEmpty else {
      Self.log(
        .init(stage: proofStage, reason: .invalidEnvelope),
        vmName: reference.displayName)
      throw PommeSecurityWorkflowError.agentUnverified
    }

    let response: [String: Any]
    do {
      response = try PommeCore.sendForegroundControlObject(
        request.controlPayload, bundle: reference.bundle)
    } catch {
      Self.log(
        .init(stage: proofStage, reason: .transport),
        vmName: reference.displayName)
      throw error
    }

    switch Self.decodeProofResponse(response, stage: proofStage) {
    case .success(let result):
      return result
    case .failure(let diagnostic):
      Self.log(diagnostic, vmName: reference.displayName)
      if diagnostic.reason == .timedOut {
        PommeCore.log(
          Self.timeoutStateSummary(for: response, stage: proofStage),
          vmName: reference.displayName)
      }
      throw diagnostic
    }
  }

  /// Decodes a desktop-proof response and preserves the closed diagnostic
  /// derived from the same rejected envelope. The result keeps this boundary
  /// independent from the host transport while ensuring callers cannot fall
  /// back to an unrelated generic workflow error.
  static func decodeProofResponse(
    _ response: [String: Any],
    stage: PommeSecurityNormalAgentProofStage
  ) -> Result<GuestCommandResult, PommeSecurityNormalAgentDiagnostic> {
    do {
      return .success(try decodeCompletedCommand(response))
    } catch {
      return .failure(
        diagnostic(for: response, stage: stage)
          ?? .init(stage: stage, reason: .invalidEnvelope)
      )
    }
  }

  /// Returns only an allowlisted diagnostic for a response rejected by
  /// `decodeCompletedCommand`. A successful response returns `nil`; callers
  /// must still run the decoder because this classifier is diagnostic-only.
  static func diagnostic(
    for response: [String: Any],
    stage: PommeSecurityNormalAgentProofStage
  ) -> PommeSecurityNormalAgentDiagnostic? {
    guard let terminal = response["result"] as? [String: Any] else {
      // The helper wraps a failed foreground exchange as an inner `ok:false`
      // object. Its error text is intentionally ignored and never enters the
      // closed diagnostic.
      if response["ok"] as? Bool == false {
        return .init(stage: stage, reason: .transport)
      }
      return .init(stage: stage, reason: .invalidEnvelope)
    }
    if terminal["timedOut"] as? Bool == true || terminal["cancelled"] as? Bool == true {
      return .init(stage: stage, reason: .timedOut)
    }
    if terminal["stdoutTruncated"] as? Bool == true
      || terminal["stderrTruncated"] as? Bool == true
    {
      return .init(stage: stage, reason: .outputTruncated)
    }
    guard terminal["exited"] as? Bool == true,
      terminal["outputComplete"] as? Bool == true
    else {
      return .init(stage: stage, reason: .incomplete)
    }
    guard let rawCode = integerValue(terminal["exitCode"]),
      (0...255).contains(rawCode),
      Int(exactly: rawCode) != nil,
      terminal["signal"] == nil,
      let frames = response["streamFrames"] as? [[String: Any]]
    else {
      return .init(stage: stage, reason: .invalidEnvelope)
    }
    for frame in frames {
      guard let kind = frame["stream"] as? String,
        let encoded = frame["dataBase64"] as? String,
        Data(base64Encoded: encoded) != nil,
        kind == "stdout" || kind == "stderr"
      else {
        return .init(stage: stage, reason: .invalidEnvelope)
      }
    }
    return nil
  }

  static func transportDiagnostic(
    stage: PommeSecurityNormalAgentProofStage
  ) -> PommeSecurityNormalAgentDiagnostic {
    .init(stage: stage, reason: .transport)
  }

  /// Summarizes only the closed process-state booleans needed to distinguish a
  /// running timed-out job from one that exited without a complete output
  /// receipt. Missing or wrongly typed fields remain explicitly unknown; no
  /// guest-provided process identity or output crosses this boundary.
  static func timeoutStateSummary(
    for response: [String: Any],
    stage: PommeSecurityNormalAgentProofStage
  ) -> String {
    let terminal = response["result"] as? [String: Any] ?? [:]

    func boolean(_ key: String) -> String {
      guard let value = terminal[key],
        let decoded = try? JSONValue(any: value),
        case .bool(let value) = decoded
      else { return "unknown" }
      return value ? "true" : "false"
    }

    return "Normal desktop proof timeout state: stage=\(stage.rawValue), "
      + "exited=\(boolean("exited")), "
      + "outputComplete=\(boolean("outputComplete")), "
      + "terminationRequested=\(boolean("terminationRequested"))."
  }

  private static func log(
    _ diagnostic: PommeSecurityNormalAgentDiagnostic,
    vmName: String
  ) {
    PommeCore.log(
      "Normal desktop proof diagnostic: \(diagnostic.code).",
      vmName: vmName)
  }

  /// Looks for the process-bound native diagnostic emitted when sysadminctl
  /// cannot obtain the GUI login SessionAgent. This is deliberately a
  /// best-effort read-only probe after the PTY command has completed: a
  /// missing log, a nonzero log command, or malformed/oversized output is
  /// absence of diagnostic evidence rather than a new owner-preparation
  /// failure. The command contains no credential or native output.
  func autologinSessionRefusal(processID: Int64) throws -> PommeSecurityOwnerAutologinRefusal? {
    guard Self.validProcessID(processID) else { return nil }

    let predicate =
      "process == 'sysadminctl' AND (subsystem == 'com.apple.login' OR subsystem == 'com.apple.login.default') AND eventMessage CONTAINS 'Unable to get the SessionAgent endpoint'"
    let request = GuestCommandRequest(
      path: "/usr/bin/log",
      arguments: [
        "show", "--style", "json", "--info", "--debug", "--last", "1m",
        "--process", String(processID), "--predicate", predicate,
      ],
      timeout: 15
    )
    let result = try execute(request)
    guard result.exited,
      result.exitCode == 0,
      result.signal == nil,
      !result.timedOut,
      !result.stdoutTruncated,
      !result.stderrTruncated,
      result.stdout.count <= Self.maximumSessionDiagnosticBytes,
      result.stderr.count <= Self.maximumSessionDiagnosticBytes
    else { return nil }
    return Self.classifyAutologinSessionDiagnostic(
      result.stdout, expectedProcessID: processID)
  }

  /// Classifies only the bounded JSON records returned by the native log
  /// command. JSONValue preserves integer-vs-number-vs-string distinctions,
  /// so a process ID represented as a Boolean, fraction, or string cannot
  /// satisfy the process binding. The return value is a closed enum and never
  /// contains native log text.
  static func classifyAutologinSessionDiagnostic(
    _ data: Data, expectedProcessID: Int64
  ) -> PommeSecurityOwnerAutologinRefusal? {
    guard data.count <= maximumSessionDiagnosticBytes,
      validProcessID(expectedProcessID),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .array(let records) = value
    else { return nil }

    for record in records {
      guard case .object(let fields) = record,
        case .integer(let processID)? = fields["processID"],
        processID == expectedProcessID,
        case .string(let subsystem)? = fields["subsystem"],
        subsystem == "com.apple.login" || subsystem == "com.apple.login.default",
        case .string(let eventMessage)? = fields["eventMessage"],
        isKnownSessionUnavailableMessage(eventMessage)
      else { continue }
      return .sessionUnavailable
    }
    return nil
  }

  private static let maximumSessionDiagnosticBytes = 1 * 1024 * 1024

  private static func validProcessID(_ processID: Int64) -> Bool {
    (1...Int64(Int32.max)).contains(processID)
  }

  private static func isKnownSessionUnavailableMessage(_ message: String) -> Bool {
    let suffixes = [
      "ERROR: Unable to get the SessionAgent endpoint, result = 2",
      "ERROR: Unable to get the SessionAgent endpoint, endpoint is nil",
    ]
    for suffix in suffixes {
      if message == suffix { return true }
      let separator = " "
      guard message.hasSuffix(separator + suffix) else { continue }
      let prefix = String(message.dropLast(separator.count + suffix.count))
      guard prefix.range(
        of: #"^[A-Za-z_][A-Za-z0-9_]*:[0-9]{1,6}:$"#,
        options: .regularExpression
      ) != nil,
        let line = prefix.split(separator: ":").last,
        let lineNumber = Int(line), lineNumber > 0
      else { continue }
      return true
    }
    return false
  }

  /// Decodes the response returned by `sendForegroundControlObject` without
  /// relying on Swift's numeric casts. `JSONValue.publicValue` represents
  /// integer fields as `Int64`, while a JSONSerialization round trip may
  /// represent the same field as an integer NSNumber. Both are accepted only
  /// after `JSONValue` has confirmed that the value is an integer, so Boolean,
  /// string, and fractional exit statuses fail closed.
  static func decodeCompletedCommand(_ response: [String: Any]) throws -> GuestCommandResult {
    guard let terminal = response["result"] as? [String: Any],
      terminal["exited"] as? Bool == true,
      terminal["outputComplete"] as? Bool == true,
      terminal["timedOut"] as? Bool != true,
      terminal["cancelled"] as? Bool != true,
      terminal["stdoutTruncated"] as? Bool != true,
      terminal["stderrTruncated"] as? Bool != true,
      let rawCode = integerValue(terminal["exitCode"]),
      rawCode >= 0, rawCode <= 255,
      let code = Int(exactly: rawCode),
      terminal["signal"] == nil,
      let frames = response["streamFrames"] as? [[String: Any]]
    else {
      throw PommeSecurityWorkflowError.agentUnverified
    }
    var stdout = Data()
    var stderr = Data()
    for frame in frames {
      guard let kind = frame["stream"] as? String,
        let encoded = frame["dataBase64"] as? String,
        let bytes = Data(base64Encoded: encoded)
      else {
        throw PommeSecurityWorkflowError.agentUnverified
      }
      switch kind {
      case "stdout": stdout.append(bytes)
      case "stderr": stderr.append(bytes)
      default: throw PommeSecurityWorkflowError.agentUnverified
      }
    }
    return .init(
      exitCode: code, signal: nil, stdout: stdout, stderr: stderr,
      stdoutTruncated: false, stderrTruncated: false, exited: true)
  }

  private static func integerValue(_ value: Any?) -> Int64? {
    guard let value, let decoded = try? JSONValue(any: value) else { return nil }
    guard case .integer(let integer) = decoded else { return nil }
    return integer
  }

  func verifyConsoleLogin(username: String, uniqueID: UInt32, timeout: TimeInterval = 120)
    async throws
  {
    guard let aquaRequest = Self.aquaSessionProofRequest(uniqueID: uniqueID),
      timeout.isFinite, timeout > 0
    else {
      throw PommeSecurityWorkflowError.ownerLoginUnverified
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    var desktopStableSince: ContinuousClock.Instant?
    while true {
      let user = try execute(
        .init(path: "/usr/bin/stat", arguments: ["-f", "%Su:%u", "/dev/console"], timeout: 15),
        proofStage: .console)
      let observed = String(data: user.stdout, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      let consoleMatches = !user.detached && user.exited && !user.timedOut && user.signal == nil
        && user.exitCode == 0 && !user.stdoutTruncated && !user.stderrTruncated
        && observed == "\(username):\(uniqueID)"
      if consoleMatches {
        let session = try execute(aquaRequest, proofStage: .aqua)
        let aquaSessionMatches = Self.isCompletedAquaSessionProof(session)
        let desktop = try execute(
          .init(path: "/bin/ps", arguments: ["-axo", "uid=,comm="], timeout: 15),
          proofStage: .processList)
        let desktopMatches = !desktop.detached && desktop.exited && !desktop.timedOut && desktop.signal == nil
          && desktop.exitCode == 0 && !desktop.stdoutTruncated && !desktop.stderrTruncated
          && Self.parseDesktopProcessList(desktop.stdout, expectedUID: uniqueID)
        let now = ContinuousClock.now
        if aquaSessionMatches && desktopMatches {
          if desktopStableSince == nil { desktopStableSince = now }
          if let stableSince = desktopStableSince,
             now < deadline,
             stableSince.duration(to: now) >= .seconds(5) {
            return
          }
        } else {
          desktopStableSince = nil
        }
      } else {
        desktopStableSince = nil
      }
      guard ContinuousClock.now < deadline else {
        throw PommeSecurityWorkflowError.ownerLoginUnverified
      }
      try Task.checkCancellation()
      try await Task.sleep(for: .seconds(1))
    }
  }

  /// Keeps the large `launchctl print` body out of the bounded foreground
  /// result. The UID is passed as a positional argument, never interpolated
  /// into shell source; zero is not a valid Aqua login UID for this proof.
  static func aquaSessionProofRequest(uniqueID: UInt32) -> GuestCommandRequest? {
    guard uniqueID > 0 else { return nil }
    return .init(
      path: "/bin/sh",
      arguments: [
        "-c", "exec /bin/launchctl print \"gui/$1\" >/dev/null",
        "pomme-aqua-proof", String(uniqueID),
      ],
      timeout: 15
    )
  }

  static func isCompletedAquaSessionProof(_ result: GuestCommandResult) -> Bool {
    !result.detached && result.exited && !result.timedOut && result.signal == nil
      && result.exitCode == 0
      && !result.stdoutTruncated && !result.stderrTruncated
      && result.stdout.isEmpty && result.stderr.isEmpty
  }

  /// Parses the native `/bin/ps -axo uid=,comm=` output used to prove that
  /// the requested owner has reached the Aqua desktop. The UID is the first
  /// whitespace-delimited field and the remainder is the command path, so
  /// unrelated process names containing spaces remain a single field. Only
  /// the exact Dock path is accepted for the owner; the exact Setup Assistant
  /// executable blocks completion for every UID while it is still present.
  static func parseDesktopProcessList(_ data: Data, expectedUID: UInt32) -> Bool {
    guard expectedUID > 0,
      data.count <= maximumDesktopProcessListBytes,
      let text = String(data: data, encoding: .utf8),
      !text.contains("\0")
    else { return false }

    var ownerDockCount = 0
    var sawRecord = false
    for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let fields = rawLine.split(
        maxSplits: 1,
        omittingEmptySubsequences: true,
        whereSeparator: { $0 == " " || $0 == "\t" }
      )
      if fields.isEmpty { continue }
      guard fields.count == 2 else { return false }

      let rawUID = String(fields[0])
      guard rawUID == "0" || !rawUID.hasPrefix("0"),
        rawUID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        let parsedUID = UInt64(rawUID),
        let uid = UInt32(exactly: parsedUID),
        String(uid) == rawUID
      else { return false }

      let command = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else { return false }
      sawRecord = true
      if command == setupAssistantExecutablePath { return false }
      if uid == expectedUID && command == dockExecutablePath {
        ownerDockCount += 1
        guard ownerDockCount == 1 else { return false }
      }
    }
    return sawRecord && ownerDockCount == 1
  }

  private static let maximumDesktopProcessListBytes = 1 * 1024 * 1024
  private static let dockExecutablePath =
    "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
  private static let setupAssistantExecutablePath =
    "/System/Library/CoreServices/Setup Assistant.app/Contents/MacOS/Setup Assistant"

  func verifyNormalSecurity(sip: Bool, disabled: Bool) throws {
    let request = GuestCommandRequest(
      path: sip ? "/usr/bin/csrutil" : "/usr/sbin/sysctl",
      arguments: sip ? ["status"] : ["-n", "kern.bootargs"], timeout: 30
    )
    let result = try execute(request)
    guard result.hostExitCode == 0 else { throw PommeSecurityWorkflowError.normalBootUnverified }
    let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    if sip {
      let expected = "System Integrity Protection status: \(disabled ? "disabled" : "enabled")."
      guard output == expected else { throw PommeSecurityWorkflowError.normalBootUnverified }
    } else {
      guard PommeBootArguments.containsOverride(output) == disabled else {
        throw PommeSecurityWorkflowError.normalBootUnverified
      }
    }
  }
}
