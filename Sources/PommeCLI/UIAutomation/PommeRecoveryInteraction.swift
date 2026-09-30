import Foundation

/// The only effectful boundary required by Tahoe Recovery navigation.  The
/// implementation returns one receipt for one closed guest HID effect. The
/// sole pointer effect is an exact experimental LanguageChooser activation;
/// callers cannot supply coordinates or affect host focus/display state.
protocol PommeRecoveryKeyboardPort: Sendable {
  func prepareRecoveryNavigation(route: PommeRecoveryNavigationRoute) async throws
  func nextRecoveryFrame() async throws -> PommeRecoveryFrame
  /// Returns the two fresh observations that form one Recovery checkpoint.
  ///
  /// Production ports should capture this pair as one stability operation so
  /// the interaction driver does not nest an already-stable observation
  /// inside another pair request. The default keeps older test and adapter
  /// ports source-compatible while they migrate to the explicit operation.
  func nextRecoveryFramePair() async throws -> [PommeRecoveryFrame]
  func deliverRecoveryKey(
    _ key: PommeRecoveryVirtualKey
  ) async throws -> PommeRecoveryDurableInputReceipt
  func deliverRecoveryInput(
    _ input: PommeRecoveryNavigationInput
  ) async throws -> PommeRecoveryDurableInputReceipt
}

extension PommeRecoveryKeyboardPort {
  /// Existing key-only adapters fail closed for the new bounded pointer effect.
  func deliverRecoveryInput(
    _ input: PommeRecoveryNavigationInput
  ) async throws -> PommeRecoveryDurableInputReceipt {
    guard case .key(let key) = input else {
      throw PommeRecoveryVirtualizationPortError.unexpectedKey
    }
    return try await deliverRecoveryKey(key)
  }
  func prepareRecoveryNavigation(route: PommeRecoveryNavigationRoute) async throws {}

  func nextRecoveryFramePair() async throws -> [PommeRecoveryFrame] {
    try Task.checkCancellation()
    let first = try await nextRecoveryFrame()
    try Task.checkCancellation()
    let second = try await nextRecoveryFrame()
    try Task.checkCancellation()
    return [first, second]
  }
}

/// Extends the bounded navigation port only after Terminal has been proven by
/// the selected trace. The launcher text and marker are caller-supplied;
/// neither is returned or recorded by this UI layer.
protocol PommeRecoveryTerminalPort: PommeRecoveryKeyboardPort {
  func submitTerminalLine(_ command: String) async throws
  func terminalMarkerIsVerified(_ marker: String) async throws -> Bool
  func clearTerminalLine() async throws
  func clearRecoveryObservations() async
  func reportRecoveryPerformance(phase: PommeRecoveryPerformancePhase) async
}

extension PommeRecoveryTerminalPort {
  func clearRecoveryObservations() async {}
  func reportRecoveryPerformance(phase: PommeRecoveryPerformancePhase) async {}
}

/// A closed signal for a caller that owns the surrounding Recovery session.
/// In particular, a delivery error is conservatively treated as possibly
/// having reached the guest; callers must clean up that bounded session before
/// attempting any later Recovery work.
enum PommeRecoveryInteractionCleanupSignal: Equatable, Sendable {
  case noInputDelivered
  case recoveryCleanupRequired
  case inputCommitted
  case terminalVerified
}

enum PommeRecoveryInteractionError: Error, Equatable, Sendable {
  case incompleteQualification
  case noInputDelivered(PommeRecoveryInteractionCleanupSignal)
  case observationTimedOut(PommeRecoveryInteractionCleanupSignal)
  case terminalProofFailed(PommeRecoveryInteractionCleanupSignal)
  case recoveryCleanupRequired(PommeRecoveryInteractionCleanupSignal)
  case alreadyComplete
}

enum PommeRecoveryTerminalLaunchDisposition: Equatable, Sendable {
  case terminalLauncherSubmitted
  case noInputDelivered
  case observationTimedOut
  case terminalProofFailed
  case recoveryCleanupRequired
}

/// Closed, redaction-safe progress emitted by the Recovery interaction.  No
/// request identifiers, commands, paths, credentials, or OCR text cross this
/// boundary.
enum PommeRecoveryInteractionMilestone: String, Equatable, Sendable {
  case navigationStarted
  case terminalLaunching
  case terminalVerified
  case capabilityProbeSubmitted
  case capabilityProbeVerified
  case capabilityProbeRejected
  case launcherAuthorizationRejected
  case launcherSubmitted
}

/// A production-facing Recovery interaction driver. The driver starts only
/// from the closed reviewed or experimental qualification contract, gathers
/// exactly two pre-event and two post-event frame classifications for every
/// single input receipt, and refuses to dispatch a replacement input after an
/// uncertain delivery.
///
/// It intentionally exposes neither the framebuffer nor a pointer API.  That
/// makes this safe for create, repair, SIP, and AMFI owners to call through a
/// request-bound Recovery session without changing host focus or display state.
struct PommeTahoeRecoveryInteraction: Sendable {
  private var input: PommeTahoeReviewedInput
  private var cleanupRequired = false
  private var navigationPrepared = false

  init(evidence: PommeRecoveryProfileEvidence) throws {
    do {
      input = try PommeRecoveryProfileSelector.inputForAttempt(for: evidence)
    } catch {
      throw PommeRecoveryInteractionError.incompleteQualification
    }
  }

  var isComplete: Bool { input.isComplete }

  /// Advances one and only one navigation receipt. A caller repeats this
  /// until `isComplete` is true.  Errors always carry a closed cleanup
  /// disposition and never expose frame contents or input details.
  @discardableResult
  mutating func advance(
    using port: some PommeRecoveryKeyboardPort,
    onMilestone: @escaping @Sendable (PommeRecoveryInteractionMilestone) async -> Void = { _ in }
  ) async throws -> PommeRecoveryInteractionCleanupSignal {
    guard !cleanupRequired else {
      throw PommeRecoveryInteractionError.recoveryCleanupRequired(.recoveryCleanupRequired)
    }
    guard !input.isComplete else {
      throw PommeRecoveryInteractionError.alreadyComplete
    }

    let navigationInput: PommeRecoveryNavigationInput
    do {
      try Task.checkCancellation()
      if !navigationPrepared {
        try await port.prepareRecoveryNavigation(route: input.route)
        navigationPrepared = true
      }
      try Task.checkCancellation()
      let preEventFrames = try await port.nextRecoveryFramePair()
      try Task.checkCancellation()
      navigationInput = try input.authorizeInput(preEventFrames: preEventFrames)
    } catch {
      if Self.isObservationTimeout(error) {
        throw PommeRecoveryInteractionError.observationTimedOut(.noInputDelivered)
      }
      throw PommeRecoveryInteractionError.noInputDelivered(.noInputDelivered)
    }

    // `authorizeInput` leaves an input outstanding. From this point onward no
    // retry is safe: a failed send may still have reached the guest.
    let receipt: PommeRecoveryDurableInputReceipt
    do {
      try Task.checkCancellation()
      if navigationInput == .key(.shiftCommandT) {
        await onMilestone(.terminalLaunching)
      }
      receipt = try await port.deliverRecoveryInput(navigationInput)
    } catch {
      cleanupRequired = true
      if Self.isObservationTimeout(error) {
        throw PommeRecoveryInteractionError.observationTimedOut(.recoveryCleanupRequired)
      }
      throw PommeRecoveryInteractionError.recoveryCleanupRequired(.recoveryCleanupRequired)
    }

    do {
      try Task.checkCancellation()
      let postEventFrames = try await port.nextRecoveryFramePair()
      try Task.checkCancellation()
      try input.commit(receipt, postEventFrames: postEventFrames)
    } catch {
      cleanupRequired = true
      if Self.isObservationTimeout(error) {
        throw PommeRecoveryInteractionError.observationTimedOut(.recoveryCleanupRequired)
      }
      throw PommeRecoveryInteractionError.recoveryCleanupRequired(.recoveryCleanupRequired)
    }
    return input.isComplete ? .terminalVerified : .inputCommitted
  }

  /// Drives only the existing bounded Recovery trace, proves the non-secret
  /// VirtioFS capabilities at a fresh shell prompt, then submits the supplied
  /// launcher exactly once. Authentication is deliberately owned by the
  /// surrounding request-bound Recovery runtime; no framebuffer is captured
  /// and no input is retried after the mutating launcher is submitted.
  mutating func driveToTerminalAndLaunch(
    using port: some PommeRecoveryTerminalPort,
    capabilityProbes: [PommeRecoveryVirtioFSCapabilityProbe],
    launcherCommand: String,
    authorizeLauncherSubmission: @escaping @Sendable () throws -> Void = {},
    onMilestone: @escaping @Sendable (PommeRecoveryInteractionMilestone) async -> Void = { _ in }
  ) async -> PommeRecoveryTerminalLaunchDisposition {
    guard !capabilityProbes.isEmpty,
      capabilityProbes.allSatisfy({
        PommeRecoveryTerminalCommand.isKeyboardSafe($0.command)
          && PommeRecoveryTerminalCommand.isSafeMarker($0.marker)
      }),
      PommeRecoveryTerminalCommand.isKeyboardSafe(launcherCommand)
    else {
      return .noInputDelivered
    }

    await onMilestone(.navigationStarted)
    while !isComplete {
      do {
        _ = try await advance(using: port, onMilestone: onMilestone)
      } catch let error as PommeRecoveryInteractionError {
        switch error {
        case .noInputDelivered:
          return .noInputDelivered
        case .observationTimedOut:
          return .observationTimedOut
        case .terminalProofFailed:
          return .terminalProofFailed
        case .incompleteQualification, .recoveryCleanupRequired, .alreadyComplete:
          return .recoveryCleanupRequired
        }
      } catch {
        return .recoveryCleanupRequired
      }
    }

    await onMilestone(.terminalVerified)
    await port.reportRecoveryPerformance(phase: .navigation)
    do {
      for probe in capabilityProbes {
        try await port.submitTerminalLine(probe.command)
        await onMilestone(.capabilityProbeSubmitted)
        let markerVerified: Bool
        do {
          markerVerified = try await port.terminalMarkerIsVerified(probe.marker)
        } catch {
          if Self.isObservationTimeout(error) {
            return .observationTimedOut
          }
          return .terminalProofFailed
        }
        guard markerVerified else {
          await onMilestone(.capabilityProbeRejected)
          return .terminalProofFailed
        }
        try await port.clearTerminalLine()
        await onMilestone(.capabilityProbeVerified)
      }

      // Crossing this boundary may mutate the guest. Never capture another
      // frame, submit another line, or retry Return after this succeeds or
      // throws: a delivery error can mean the command reached Recovery.
      await port.clearRecoveryObservations()
      do {
        try authorizeLauncherSubmission()
      } catch {
        await onMilestone(.launcherAuthorizationRejected)
        return .recoveryCleanupRequired
      }
      try await port.submitTerminalLine(launcherCommand)
      await port.reportRecoveryPerformance(phase: .bootstrap)
      await onMilestone(.launcherSubmitted)
      return .terminalLauncherSubmitted
    } catch {
      if Self.isObservationTimeout(error) {
        return .observationTimedOut
      }
      return .recoveryCleanupRequired
    }
  }

  /// The underlying timeout carries the expected frame for internal control
  /// flow only. Never copy that associated value across this redacted UI
  /// boundary; callers receive only a closed category and cleanup signal.
  private static func isObservationTimeout(_ error: Error) -> Bool {
    guard let error = error as? PommeRecoveryVirtualizationPortError else {
      return false
    }
    if case .observationTimedOut = error { return true }
    return false
  }
}

enum PommeRecoveryTerminalCommand {
  static func isKeyboardSafe(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 4096 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.value >= 0x20 && scalar.value <= 0x7E
        && HostDisplayKey.lookup(character: Character(String(scalar))) != nil
    }
  }

  static func isSafeMarker(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 256 else { return false }
    return value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
  }
}

/// A display observation has no input or host-window side effect.  It is the
/// sole UIAutomation value accepted by the first-normal-boot readiness gate.
enum PommeDisplayOnlyNormalBootFrame: Equatable, Sendable {
  case present(width: Int, height: Int)
  case unavailable
}

struct PommeDisplayOnlyNormalBootReceipt: Equatable, Sendable {
  let width: Int
  let height: Int
}

enum PommeDisplayOnlyNormalBootError: Error, Equatable, Sendable {
  case displayUnavailable
  case unqualifiedGeometry
  case cancelled
}

/// Requires two consecutive 1280x800 display observations before normal boot
/// is ready for the next provisioning phase.  It has no keyboard or pointer
/// methods, so using it cannot front an app, move the host pointer, or wake a
/// display.
struct PommeDisplayOnlyNormalBootGate: Sendable {
  private var priorReadyFrame = false

  mutating func observe(
    _ frame: PommeDisplayOnlyNormalBootFrame
  ) throws -> PommeDisplayOnlyNormalBootReceipt? {
    do { try Task.checkCancellation() } catch { throw PommeDisplayOnlyNormalBootError.cancelled }
    guard case .present(let width, let height) = frame else {
      priorReadyFrame = false
      throw PommeDisplayOnlyNormalBootError.displayUnavailable
    }
    guard width == VirtualizationPrivateHeadlessBackend.displayWidth,
      height == VirtualizationPrivateHeadlessBackend.displayHeight
    else {
      priorReadyFrame = false
      throw PommeDisplayOnlyNormalBootError.unqualifiedGeometry
    }
    defer { priorReadyFrame = true }
    guard priorReadyFrame else { return nil }
    return .init(width: width, height: height)
  }
}
