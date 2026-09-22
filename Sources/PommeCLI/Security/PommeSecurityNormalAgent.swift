import Foundation

/// Only proof outcomes enter this diagnostic; no guest identity or output is retained.
struct PommeSecurityDesktopProofObservation: Equatable, Sendable {
  let consoleMatches: Bool
  let aquaMatches: Bool?
  let desktopMatches: Bool?

  var timeoutDiagnostic: String {
    "Normal desktop proof deadline expired: " + labels
  }

  var observationDiagnostic: String { "Normal desktop proof observation: " + labels }

  private var labels: String {
    func label(_ matched: Bool?) -> String {
      guard let matched else { return "not-checked" }
      return matched ? "matched" : "not-matched"
    }
    return "console=\(label(consoleMatches)) "
      + "aqua=\(label(aquaMatches)) desktop=\(label(desktopMatches))."
  }
}

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

/// Injectable host effects for the real desktop-readiness loop; no VM or
/// credential operation is needed to exercise its deadline and cleanup paths.
struct PommeSecurityDesktopProofHooks: Sendable {
  let execute: @Sendable (GuestCommandRequest, TimeInterval) throws -> JSONValue
  let status: @Sendable (UUID, TimeInterval) throws -> JSONValue
  var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
}

private struct PommeDesktopProofTimeout: Error {
  let response: JSONValue
  let diagnostic: PommeSecurityNormalAgentDiagnostic
}

/// Security preparation talks to the existing authenticated persistent agent.
/// No installation, update, credential replacement, or creation-record rewrite
/// is reachable from this adapter.
struct PommeSecurityNormalAgent: Sendable {
  let reference: VMReference
  let expectedExecutableDigest: String
  private let rebootHooks: PommeSecurityNormalAgentRebootHooks?
  private let desktopProofHooks: PommeSecurityDesktopProofHooks?

  init(
    reference: VMReference,
    expectedExecutableDigest: String,
    rebootHooks: PommeSecurityNormalAgentRebootHooks? = nil,
    desktopProofHooks: PommeSecurityDesktopProofHooks? = nil
  ) {
    self.reference = reference
    self.expectedExecutableDigest = expectedExecutableDigest
    self.rebootHooks = rebootHooks
    self.desktopProofHooks = desktopProofHooks
  }

  /// Native reboot is intentionally bounded even when a caller supplies a
  /// larger value. A reboot request is detached, so the host must observe the
  /// VM state and a changed boot identity rather than waiting on that process.
  static let maximumRebootTimeout: TimeInterval = 300
  private static let rebootRequestTimeout: TimeInterval = 15
  private static let bootIdentityRequestTimeout: TimeInterval = 15
  // The guest process deadline controls when PommeAgent requests termination;
  // the helper still needs a short bounded interval to deliver that terminal
  // frame across the control socket.
  private static let foregroundTransportGrace: TimeInterval =
    3 * Constants.agentRoundTripTimeout
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
  func requireAMFIWorkflowSupport(
    timeout: TimeInterval = Constants.defaultGuestCommandTimeout
  ) throws {
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
      ], bundle: reference.bundle, timeout: timeout)
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
  func performAMFI(
    operation: String,
    volumeGroupUUID: UUID,
    timeout: TimeInterval = Constants.defaultRecoveryAgentTimeout
      + 3 * Constants.agentRoundTripTimeout
  ) throws -> JSONValue {
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
      ], bundle: reference.bundle, timeout: timeout)
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
    guard timeout.isFinite, timeout > 0 else {
      throw PommeSecurityWorkflowError.agentUnverified
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    func remainingTimeout() throws -> TimeInterval {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { throw PommeSecurityWorkflowError.agentUnverified }
      return remaining
    }
    while true {
      do {
        let response = try PommeCore.sendControlObject(
          [
            "command": "agent.perform", "operation": "agent.describe",
            "payload": requirePrivateInput ? ["includePrivatePTYCapabilities": true] : [:],
          ], bundle: reference.bundle, timeout: try remainingTimeout())
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
        guard ProcessInfo.processInfo.systemUptime < deadline else {
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
  /// Returns the verified new boot identity so a caller can later recognize
  /// this exact boot without rebooting it again.
  @discardableResult
  func rebootAndAuthenticate(timeout: TimeInterval = 180) async throws -> String {
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
          if current != originalBootIdentity { return current }
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
        if current != originalBootIdentity { return current }
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
    let response = try PommeCore.sendControlObject(
      payload, bundle: reference.bundle, timeout: timeout)
    guard isVerifiedDetachedRebootStart(response) else {
      throw PommeSecurityNormalAgentError.rebootRequestFailed
    }
  }

  func execute(_ request: GuestCommandRequest) throws -> GuestCommandResult {
    guard !request.pty, request.inputData == nil, request.environment.isEmpty else {
      throw PommeSecurityWorkflowError.agentUnverified
    }
    let response = try PommeCore.sendForegroundControlObject(
      request.controlPayload,
      bundle: reference.bundle,
      timeout: request.timeout + Self.foregroundTransportGrace)
    return try Self.decodeCompletedCommand(response)
  }

  /// Executes one of the bounded desktop-proof probes and propagates only a
  /// closed diagnostic when its response envelope is rejected.
  private func execute(
    _ request: GuestCommandRequest,
    proofStage: PommeSecurityNormalAgentProofStage,
    remainingBudget: TimeInterval? = nil,
    retainDesktopTimeout: Bool = false
  ) throws -> GuestCommandResult {
    if remainingBudget != nil { try Task.checkCancellation() }
    guard !request.pty, request.inputData == nil, request.environment.isEmpty else {
      Self.log(
        .init(stage: proofStage, reason: .invalidEnvelope),
        vmName: reference.displayName)
      throw PommeSecurityWorkflowError.agentUnverified
    }

    let response: [String: Any]
    let transportTimeout = min(request.timeout + Self.foregroundTransportGrace, remainingBudget ?? .infinity)
    do {
      if let desktopProofHooks {
        guard let decoded = try desktopProofHooks.execute(
          request, transportTimeout).publicValue as? [String: Any]
        else { throw PommeSecurityWorkflowError.agentUnverified }
        response = decoded
      } else {
        response = try PommeCore.sendForegroundControlObject(
          request.controlPayload,
          bundle: reference.bundle,
          timeout: transportTimeout)
      }
    } catch {
      Self.log(
        .init(stage: proofStage, reason: .transport),
        vmName: reference.displayName)
      throw error
    }

    if remainingBudget != nil { try Task.checkCancellation() }
    if proofStage == .aqua, let summary = Self.temporaryAquaTimingSummary(response) {
      PommeCore.log(summary, vmName: reference.displayName)
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
        if retainDesktopTimeout,
          let payload = try JSONValue(any: request.agentPayload()).objectValue,
          PommeForegroundExecution.isDesktopProofPayload(payload) {
          throw PommeDesktopProofTimeout(response: try JSONValue(any: response), diagnostic: diagnostic)
        }
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

  /// Temporary scalar-only timing report; never interpolate untrusted keys,
  /// strings, paths, process identities, or command output.
  static func temporaryAquaTimingSummary(_ response: [String: Any]) -> String? {
    guard let terminal = response["result"] as? [String: Any],
      let fields = terminal[PommeForegroundExecution.aquaDebugKey] as? [String: Any]
    else { return nil }
    let numbers = PommeForegroundExecution.aquaDebugNumbers.map { key in
      guard let raw = fields[key], let decoded = try? JSONValue(any: raw),
        case .integer(let number) = decoded, number >= 0,
        key != "waitLastOutcome" || PommeAquaWaitDebug.Outcome(rawValue: number) != nil
      else { return "\(key)=unknown" }
      return "\(key)=\(number)"
    }
    let booleans = PommeForegroundExecution.aquaDebugBooleans.map { key in
      guard let raw = fields[key], let decoded = try? JSONValue(any: raw),
        case .bool(let flag) = decoded
      else { return "\(key)=unknown" }
      return "\(key)=\(flag)"
    }
    return "[DEBUG-aqua-20260922] " + (numbers + booleans).joined(separator: " ")
  }

  /// Summarizes closed process-state booleans; missing or malformed values
  /// remain unknown without exposing guest identities or output.
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
    let proofNow: @Sendable () -> ContinuousClock.Instant
    let proofSleep: @Sendable (TimeInterval) async throws -> Void
    if let desktopProofHooks {
      proofNow = desktopProofHooks.now
      proofSleep = desktopProofHooks.sleep
    } else {
      proofNow = { ContinuousClock.now }
      proofSleep = { try await Task.sleep(for: .seconds($0)) }
    }
    let deadline = proofNow().advanced(by: .seconds(min(timeout, 120)))
    var desktopStableSince: ContinuousClock.Instant?
    while true {
      try Task.checkCancellation()
      guard Self.remaining(until: deadline, now: proofNow()) >= 15 else {
        throw PommeSecurityWorkflowError.ownerLoginUnverified
      }
      do {
        let user = try execute(
          .init(path: "/usr/bin/stat", arguments: ["-f", "%Su:%u", "/dev/console"], timeout: 15),
          proofStage: .console, remainingBudget: Self.remaining(until: deadline, now: proofNow()), retainDesktopTimeout: true)
        guard proofNow() < deadline else { throw PommeSecurityWorkflowError.ownerLoginUnverified }
        let observed = String(data: user.stdout, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        let consoleMatches = !user.detached && user.exited && !user.timedOut && user.signal == nil
          && user.exitCode == 0 && !user.stdoutTruncated && !user.stderrTruncated
          && observed == "\(username):\(uniqueID)"
        var observation = PommeSecurityDesktopProofObservation(
          consoleMatches: consoleMatches, aquaMatches: nil, desktopMatches: nil)
        if consoleMatches {
          try Task.checkCancellation()
          guard Self.remaining(until: deadline, now: proofNow()) >= 15 else {
            throw PommeSecurityWorkflowError.ownerLoginUnverified
          }
          let session = try execute(aquaRequest, proofStage: .aqua,
            remainingBudget: Self.remaining(until: deadline, now: proofNow()), retainDesktopTimeout: true)
          let aquaSessionMatches = Self.isCompletedAquaSessionProof(session)
          try Task.checkCancellation()
          guard Self.remaining(until: deadline, now: proofNow()) >= 15 else {
            throw PommeSecurityWorkflowError.ownerLoginUnverified
          }
          let desktop = try execute(
            .init(path: "/bin/ps", arguments: ["-axo", "uid=,comm="], timeout: 15),
            proofStage: .processList, remainingBudget: Self.remaining(until: deadline, now: proofNow()), retainDesktopTimeout: true)
          let desktopMatches = !desktop.detached && desktop.exited && !desktop.timedOut && desktop.signal == nil
            && desktop.exitCode == 0 && !desktop.stdoutTruncated && !desktop.stderrTruncated
            && Self.parseDesktopProcessList(desktop.stdout, expectedUID: uniqueID)
          observation = .init(
            consoleMatches: true, aquaMatches: aquaSessionMatches, desktopMatches: desktopMatches)
          let now = proofNow()
          try Task.checkCancellation()
          guard now < deadline else { throw PommeSecurityWorkflowError.ownerLoginUnverified }
          PommeCore.log("[DEBUG-aqua-20260922] " + observation.observationDiagnostic, vmName: reference.displayName)
          if aquaSessionMatches && desktopMatches {
            if desktopStableSince == nil { desktopStableSince = now }
            if let stableSince = desktopStableSince,
               now < deadline,
               stableSince.duration(to: now) >= .seconds(5) {
              try Task.checkCancellation()
              guard proofNow() < deadline else { throw PommeSecurityWorkflowError.ownerLoginUnverified }
              return
            }
          } else {
            desktopStableSince = nil
          }
        } else {
          desktopStableSince = nil
          PommeCore.log("[DEBUG-aqua-20260922] " + observation.observationDiagnostic, vmName: reference.displayName)
        }
        guard proofNow() < deadline else {
          try Task.checkCancellation()
          PommeCore.log(observation.timeoutDiagnostic, vmName: reference.displayName)
          throw PommeSecurityWorkflowError.ownerLoginUnverified
        }
        try Task.checkCancellation()
        try await proofSleep(1)
      } catch let timeout as PommeDesktopProofTimeout {
        try Task.checkCancellation()
        guard try await verifyDesktopCleanup(timeout.response, deadline: deadline,
          now: proofNow, sleep: proofSleep) else { throw timeout.diagnostic }
        desktopStableSince = nil
        try Task.checkCancellation()
        guard Self.remaining(until: deadline, now: proofNow()) >= 16 else { throw timeout.diagnostic }
        try await proofSleep(1)
        continue
      }
    }
  }

  private static func remaining(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant) -> TimeInterval {
    let duration = now.duration(to: deadline).components
    return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
  }

  /// A timeout is still a failed proof. Only a separately proven reap and
  /// output drain permits the outer readiness loop to start another probe.
  private func verifyDesktopCleanup(
    _ response: JSONValue, deadline: ContinuousClock.Instant,
    now: @Sendable () -> ContinuousClock.Instant,
    sleep: @Sendable (TimeInterval) async throws -> Void
  ) async throws -> Bool {
    guard let terminal = response.objectValue?["result"]?.objectValue,
      terminal["timedOut"] == .bool(true), terminal["cancelled"] == .bool(false),
      let identity = terminal["jobID"]?.stringValue, let jobID = UUID(uuidString: identity),
      now() < deadline
    else { return false }
    if let rawReceipt = terminal[PommeForegroundExecution.desktopCleanupReceiptKey] {
      guard let receipt = rawReceipt.objectValue,
        Set(receipt.keys) == ["jobID", "reapedAndDrained"],
        let identity = receipt["jobID"]?.stringValue, UUID(uuidString: identity) == jobID,
        receipt["reapedAndDrained"] == .bool(true)
      else { return false }
      return true
    }
    let cleanupDeadline = min(deadline, now().advanced(by: .seconds(3)))
    while now() < cleanupDeadline {
      try Task.checkCancellation()
      let budget = Self.remaining(until: cleanupDeadline, now: now())
      guard budget > 0 else { return false }
      let status: JSONValue
      do {
        if let desktopProofHooks {
          status = try desktopProofHooks.status(jobID, budget)
        } else {
          status = try JSONValue(any: PommeCore.sendControlObject([
            "command": "agent.perform", "operation": "process.status",
            "payload": ["jobID": jobID.uuidString.lowercased()]
          ], bundle: reference.bundle, timeout: budget))
        }
      } catch {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        return false
      }
      try Task.checkCancellation()
      guard now() < cleanupDeadline,
        let complete = Self.desktopCleanupStatus(status, jobID: jobID)
      else { return false }
      if complete { return true }
      try await sleep(min(0.1, Self.remaining(until: cleanupDeadline, now: now())))
    }
    return false
  }

  /// nil is malformed and terminal; false is a valid same-job pending status.
  private static func desktopCleanupStatus(_ response: JSONValue, jobID: UUID) -> Bool? {
    guard let envelope = response.objectValue, envelope["ok"] == .bool(true),
      let terminal = envelope["result"]?.objectValue,
      let identity = terminal["jobID"]?.stringValue, UUID(uuidString: identity) == jobID,
      case .bool? = terminal["exited"],
      case .array(let frames)? = envelope["streamFrames"]
    else { return nil }
    var receivedExit = false
    for raw in frames {
      guard let frame = raw.objectValue,
        let identity = frame["jobID"]?.stringValue, UUID(uuidString: identity) == jobID,
        let request = frame["requestID"]?.stringValue, UUID(uuidString: request) != nil,
        let stream = frame["stream"]?.stringValue
      else { return nil }
      switch stream {
      case "stdout", "stderr":
        guard Set(frame.keys) == ["jobID", "requestID", "stream", "dataBase64"],
          let text = frame["dataBase64"]?.stringValue, let bytes = Data(base64Encoded: text),
          bytes.count <= PommeAgentProtocol.maximumStreamChunkBytes
        else { return nil }
      case "exit":
        guard Set(frame.keys).isSubset(of: ["jobID", "requestID", "stream", "signal"]),
          !receivedExit else { return nil }
        if let rawSignal = frame["signal"] {
          guard case .integer(let signal) = rawSignal, (1...127).contains(signal) else { return nil }
        }
        receivedExit = true
      default: return nil
      }
    }
    // The daemon serializes status before streamEvents may reap and drain.
    // Its same-job exit frame is the later authoritative cleanup evidence.
    // A normal exit frame has no code; signalled exits carry only `signal`.
    return receivedExit
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
    let output = String(decoding: result.stdout, as: UTF8.self)
    if sip {
      guard Self.parseSIPDisabled(output) == disabled else {
        throw PommeSecurityWorkflowError.normalBootUnverified
      }
    } else {
      guard PommeBootArguments.containsOverride(
        output.trimmingCharacters(in: .whitespacesAndNewlines)) == disabled
      else {
        throw PommeSecurityWorkflowError.normalBootUnverified
      }
    }
  }

  /// Reads the effective SIP state of the current normal boot. `csrutil
  /// status` reports the configuration the running kernel booted with, which
  /// is the state that governs normal-boot NVRAM writes and the same read that
  /// proves every SIP workflow after its final normal boot. It needs neither
  /// owner credentials nor a Recovery session.
  func observeSIPDisabled() throws -> Bool {
    let request = GuestCommandRequest(
      path: "/usr/bin/csrutil", arguments: ["status"], timeout: 30)
    let result = try execute(request)
    guard result.hostExitCode == 0,
      let disabled = Self.parseSIPDisabled(String(decoding: result.stdout, as: UTF8.self))
    else { throw PommeSecurityWorkflowError.statusUnverified }
    return disabled
  }

  /// Observes AMFI configuration and any retained transaction through the
  /// persistent agent, so a caller does not spend a Recovery session to learn
  /// a state a normal boot can report. Returns nil when this VM's pinned agent
  /// predates the contract, or when the read cannot be completed here, so the
  /// caller falls back to the authoritative Recovery observation rather than
  /// guessing. Reading the boot policy needs `bputil`, which is not always
  /// available to a normal boot, and that case defers to Recovery rather
  /// than failing.
  func observeAMFIState(
    volumeGroupUUID: UUID,
    timeout: TimeInterval = Constants.defaultGuestCommandTimeout
  ) -> PommeSecurityWorkflowState? {
    // Declining is ordinary, not a failure, but it costs the caller a whole
    // Recovery session, so say which check declined it. The reasons are a
    // closed vocabulary and carry no guest text.
    func decline(_ reason: String) -> PommeSecurityWorkflowState? {
      PommeCore.log(
        "Normal-agent AMFI status unavailable (\(reason)); observing through Recovery.",
        vmName: reference.displayName)
      return nil
    }
    guard PommeProvisioningDigest.isSHA256(expectedExecutableDigest) else {
      return decline("pinned-digest-invalid")
    }
    guard (try? PommeCore.stableVMRunState(reference: reference)) == .running(.normal) else {
      return decline("not-a-normal-boot")
    }
    guard supportsNormalAMFIStatus(timeout: timeout) else {
      return decline("agent-contract-unavailable")
    }
    guard let response = try? PommeCore.sendControlObject([
      "command": "agent.perform",
      "operation": PommeGuestRecoverySecurityOperations.normalAMFIStatusOperation,
      "payload": [
        "volumeGroupUUID": volumeGroupUUID.uuidString.lowercased(),
        "includeWorkflowState": true,
      ],
    ], bundle: reference.bundle, timeout: timeout) else {
      return decline("transport")
    }
    guard response["ok"] as? Bool == true,
      let rawResult = response["result"],
      let result = try? JSONValue(any: rawResult),
      result.objectValue?["operation"]
        == .string(PommeGuestRecoverySecurityOperations.normalAMFIStatusOperation)
    else { return decline("rejected") }
    // The decoder enforces the same internal consistency it does for a
    // Recovery observation; an inconsistent report is not downgraded to a
    // guess, it simply is not used.
    guard let state = try? PommeSecurityWorkflowState.decode(result, sip: false) else {
      return decline("report-not-verifiable")
    }
    return state
  }

  /// True when this VM's pinned agent advertises the normal-boot AMFI status
  /// contract. An agent pinned before it keeps working for the four staging
  /// operations and is never replaced.
  private func supportsNormalAMFIStatus(timeout: TimeInterval) -> Bool {
    guard let response = try? PommeCore.sendControlObject([
      "command": "agent.perform",
      "operation": "agent.describe",
      "payload": ["includeNormalAMFICapabilities": true],
    ], bundle: reference.bundle, timeout: timeout),
      response["ok"] as? Bool == true,
      let rawResult = response["result"],
      let result = try? JSONValue(any: rawResult),
      let description = result.objectValue
    else { return false }
    return Self.supportsNormalAMFIStatus(
      description.mapValues(\.publicValue), expectedExecutableDigest: expectedExecutableDigest)
  }

  /// Pure receipt check, closed against host-side numeric coercions.
  static func supportsNormalAMFIStatus(
    _ description: [String: Any], expectedExecutableDigest: String
  ) -> Bool {
    guard description["role"] as? String == "persistent",
      description["protocol"] as? String == PommeAgentProtocol.name,
      integerValue(description["version"]) == Int64(PommeAgentProtocol.version),
      description["executableSHA256"] as? String == expectedExecutableDigest,
      integerValue(description["normalAMFIStatusVersion"])
        == Int64(PommeGuestRecoverySecurityOperations.normalAMFIStatusVersion),
      let rawCapabilities = description["capabilities"] as? [Any]
    else { return false }
    return Set(rawCapabilities.compactMap { $0 as? String })
      .contains(PommeGuestRecoverySecurityOperations.normalAMFIStatusOperation)
  }

  /// Recovers the owner account's automatic-login password from the guest,
  /// for a VM whose host Keychain item is absent because it was cloned from a
  /// provisioned template. The credential is returned only over the
  /// authenticated agent session; it is never logged, journaled, or placed in
  /// a process argument, and the caller must still prove the account through
  /// the ordinary owner verification before trusting it.
  ///
  /// `account` binds the request when the host already knows which account to
  /// expect; passing nil asks the guest which account it logs in
  /// automatically, which is what a freshly cloned VM needs.
  func recoverOwnerCredential(
    account: String? = nil,
    timeout: TimeInterval = Constants.defaultGuestCommandTimeout
  ) throws -> PommeGuestSecurityCredentials {
    guard PommeProvisioningDigest.isSHA256(expectedExecutableDigest),
      expectedExecutableDigest == expectedExecutableDigest.lowercased(),
      try PommeCore.stableVMRunState(reference: reference) == .running(.normal)
    else { throw PommeSecurityWorkflowError.agentUnverified }

    var payload: [String: Any] = [:]
    if let account {
      guard PommeGuestOwnerCredentialReader.isSafeAccount(account) else {
        throw PommeSecurityWorkflowError.ownerUnavailable
      }
      payload["account"] = account
    }
    let response: [String: Any]
    do {
      response = try PommeCore.sendControlObject([
        "command": "agent.perform",
        "operation": PommeGuestOwnerCredentialReader.operation,
        "payload": payload,
      ], bundle: reference.bundle, timeout: timeout)
    } catch {
      throw PommeSecurityWorkflowError.ownerUnavailable
    }
    guard response["ok"] as? Bool == true,
      let rawResult = response["result"],
      let result = try? JSONValue(any: rawResult),
      let object = result.objectValue,
      object["verified"] == .bool(true),
      object["operation"] == .string(PommeGuestOwnerCredentialReader.operation),
      let recovered = object["account"]?.stringValue,
      let password = object["password"]?.stringValue,
      PommeGuestOwnerCredentialReader.isSafeAccount(recovered),
      account == nil || account == recovered
    else { throw PommeSecurityWorkflowError.ownerUnavailable }
    do {
      return try .init(username: recovered, password: password)
    } catch {
      throw PommeSecurityWorkflowError.ownerUnavailable
    }
  }

  /// Checks the opt-in owner-credential receipt without accepting host-side
  /// numeric coercions, so an older pinned agent is rejected before the host
  /// mistakes a missing capability for a guest with no owner.
  static func supportsOwnerCredentialRecovery(
    _ description: [String: Any], expectedExecutableDigest: String
  ) -> Bool {
    guard description["role"] as? String == "persistent",
      description["protocol"] as? String == PommeAgentProtocol.name,
      integerValue(description["version"]) == Int64(PommeAgentProtocol.version),
      description["executableSHA256"] as? String == expectedExecutableDigest,
      integerValue(description["ownerCredentialVersion"])
        == Int64(PommeGuestOwnerCredentialReader.version),
      let rawCapabilities = description["capabilities"] as? [Any]
    else { return false }
    return Set(rawCapabilities.compactMap { $0 as? String })
      .contains(PommeGuestOwnerCredentialReader.operation)
  }

  /// True when this VM's pinned agent advertises the recovery contract. A
  /// pinned agent that predates it is not replaced; the caller falls back to
  /// its ordinary credential resolution.
  func supportsOwnerCredentialRecovery(
    timeout: TimeInterval = Constants.defaultGuestCommandTimeout
  ) -> Bool {
    guard let response = try? PommeCore.sendControlObject([
      "command": "agent.perform",
      "operation": "agent.describe",
      "payload": ["includeOwnerCredentialCapabilities": true],
    ], bundle: reference.bundle, timeout: timeout),
      response["ok"] as? Bool == true,
      let rawResult = response["result"],
      let result = try? JSONValue(any: rawResult),
      let description = result.objectValue
    else { return false }
    return Self.supportsOwnerCredentialRecovery(
      description.mapValues(\.publicValue),
      expectedExecutableDigest: expectedExecutableDigest)
  }

  /// Accepts only the two exact native `csrutil status` reports. A custom
  /// configuration report or any other text is not a verified state.
  static func parseSIPDisabled(_ output: String) -> Bool? {
    switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "System Integrity Protection status: enabled.": false
    case "System Integrity Protection status: disabled.": true
    default: nil
    }
  }
}
