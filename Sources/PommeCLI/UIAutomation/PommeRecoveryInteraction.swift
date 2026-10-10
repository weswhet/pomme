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

enum PommeRecoveryInteractionError: PommeDescribedError, Equatable, Sendable {
  case incompleteQualification
  case noInputDelivered(PommeRecoveryInteractionCleanupSignal)
  case observationTimedOut(PommeRecoveryInteractionCleanupSignal)
  case terminalProofFailed(PommeRecoveryInteractionCleanupSignal)
  case recoveryCleanupRequired(PommeRecoveryInteractionCleanupSignal)
  case alreadyComplete

  var code: PommeErrorCode {
    switch self {
    case .incompleteQualification: .uiRecoveryUnqualified
    case .noInputDelivered: .uiRecoveryNoInput
    case .observationTimedOut: .uiRecoveryTimedOut
    case .terminalProofFailed: .uiRecoveryTerminalUnverified
    case .recoveryCleanupRequired: .uiRecoveryCleanupRequired
    case .alreadyComplete: .uiRecoverySequenceInvalid
    }
  }

  var errorDescription: String? {
    switch self {
    case .incompleteQualification:
      "Recovery navigation isn't qualified for this VM's macOS build, language, display size, or ownership, so Pomme sent no input."
    case .noInputDelivered:
      "Recovery navigation stopped before Pomme sent any input to the VM."
    case .observationTimedOut(let signal):
      "Recovery didn't reach the expected screen before the time limit."
        + Self.inputNote(signal)
    case .terminalProofFailed(let signal):
      "Pomme couldn't confirm that Terminal opened in Recovery, so it didn't type a command."
        + Self.inputNote(signal)
    case .recoveryCleanupRequired:
      "An earlier Recovery action might have reached the VM, and Pomme couldn't confirm its result, so it sent no more input."
    case .alreadyComplete:
      "Recovery navigation was asked for another step after it finished. This is a bug in Pomme."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .incompleteQualification:
      "Run `pomme inspect NAME` to check the VM's macOS version."
    case .noInputDelivered:
      "Run the same command again. Add `--debug` to save a screenshot before each Recovery action."
    case .observationTimedOut(let signal), .terminalProofFailed(let signal):
      signal == .noInputDelivered
        ? "Run the same command again. Add `--debug` to save a screenshot before each Recovery action."
        : "Stop the VM with `pomme stop NAME`, then run the same command again."
    case .recoveryCleanupRequired, .alreadyComplete:
      "Stop the VM with `pomme stop NAME`, then run the same command again."
    }
  }

  private static func inputNote(_ signal: PommeRecoveryInteractionCleanupSignal) -> String {
    switch signal {
    case .noInputDelivered: " Pomme sent no input."
    case .recoveryCleanupRequired, .inputCommitted: " Some input might have reached the VM."
    case .terminalVerified: ""
    }
  }
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
  case recoveryLoading
  case utilitiesOpening
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
    let preEventFrame: PommeRecoveryFrame?
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
      preEventFrame = preEventFrames.first
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
      if let milestone = Self.milestone(before: navigationInput, preEventFrame: preEventFrame) {
        await onMilestone(milestone)
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

  /// The inputs that start a long guest transition. Recovery takes about a
  /// minute to load after Options, so each is named before it is delivered.
  static func milestone(
    before input: PommeRecoveryNavigationInput, preEventFrame: PommeRecoveryFrame?
  ) -> PommeRecoveryInteractionMilestone? {
    switch (input, preEventFrame) {
    case (.key(.return), .startupOptionsActivated?): .recoveryLoading
    case (.key(.return), .languageEnglish?), (.key(.return), .languageEnglishActive?): .utilitiesOpening
    case (.key(.shiftCommandT), _): .terminalLaunching
    default: nil
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

enum PommeDisplayOnlyNormalBootError: PommeDescribedError, Equatable, Sendable {
  case displayUnavailable
  case unqualifiedGeometry
  case cancelled

  var code: PommeErrorCode {
    switch self {
    case .displayUnavailable: .displayUnavailable
    case .unqualifiedGeometry: .displayGeometryUnsupported
    case .cancelled: .operationCancelled
    }
  }

  var errorDescription: String? {
    switch self {
    case .displayUnavailable:
      "The VM display isn't available, so Pomme can't confirm that macOS finished starting."
    case .unqualifiedGeometry:
      "The VM display isn't 1280 by 800 pixels, the only size that Pomme automates."
    case .cancelled:
      "Waiting for the VM display was cancelled."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .displayUnavailable: "Run `pomme status NAME` to check that the VM is running, then retry."
    case .unqualifiedGeometry: "Run `pomme inspect NAME` to check the VM's display configuration."
    case .cancelled: nil
    }
  }
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
