import Foundation

/// The direct-Virtualization Recovery port.  Each observation stays in memory
/// only long enough for Vision to reduce it to a closed frame state.  This
/// type never writes a screenshot or exposes OCR text.
actor PommeRecoveryVirtualizationKeyboardPort: PommeRecoveryTerminalPort {
  private enum Timing {
    static let navigationSettleNanoseconds: UInt64 = 350_000_000
    static let terminalSettleNanoseconds: UInt64 = 1_500_000_000
    static let terminalCommandSettleNanoseconds: UInt64 = 250_000_000
    static let markerRetryNanoseconds: UInt64 = 500_000_000
    static let markerAttempts = 3
  }

  private let backend: VirtualizationPrivateHeadlessBackend
  private let timeout: TimeInterval
  private let recognizer = SettingsAIOCRRecognizer()
  private var deliveredKeys: [PommeRecoveryVirtualKey] = []

  init(backend: VirtualizationPrivateHeadlessBackend, timeout: TimeInterval) {
    self.backend = backend
    self.timeout = timeout
  }

  func nextRecoveryFrame() async throws -> PommeRecoveryFrame {
    let image = try await backend.recoveryFrame(timeout: timeout)
    let context: PommeRecoveryFrameClassificationContext =
      deliveredKeys == [.right, .right, .return]
      ? .optionsActivated
      : .unproven
    let lines = try recognizer.recognizeRecovery(
      image: image,
      displaySize: VirtualizationPrivateHeadlessBackend.displaySize
    )
    let coarse = PommeRecoveryFrameClassifier.classify(
      image: image,
      lines: lines,
      context: context
    )
    return try frameFromReviewedTrace(coarse: coarse)
  }

  func deliverRecoveryKey(
    _ key: PommeRecoveryVirtualKey
  ) async throws -> PommeRecoveryDurableInputReceipt {
    guard let expectedKey, key == expectedKey else {
      throw PommeRecoveryVirtualizationPortError.unexpectedKey
    }
    _ = try await backend.awaitInputReadiness(timeout: timeout)
    _ = try await backend.sendKey(name: Self.backendKeyName(for: key), timeout: timeout)
    deliveredKeys.append(key)
    try await Task.sleep(
      nanoseconds: key == .shiftCommandT
        ? Timing.terminalSettleNanoseconds
        : Timing.navigationSettleNanoseconds
    )
    return .init(key: key, deliveredEventCount: 1)
  }

  func submitTerminalLine(_ command: String) async throws {
    guard PommeRecoveryTerminalCommand.isKeyboardSafe(command) else {
      throw PommeRecoveryVirtualizationPortError.unsafeLauncher
    }
    _ = try await backend.awaitInputReadiness(timeout: timeout)
    _ = try await backend.typeText(command, replace: false, timeout: timeout)
    _ = try await backend.sendKey(name: "return", timeout: timeout)
    try await Task.sleep(nanoseconds: Timing.terminalCommandSettleNanoseconds)
  }

  func terminalMarkerIsVerified(_ marker: String) async throws -> Bool {
    guard PommeRecoveryTerminalCommand.isSafeMarker(marker) else {
      throw PommeRecoveryVirtualizationPortError.unsafeMarker
    }
    for attempt in 0..<Timing.markerAttempts {
      if try await recognizesTerminalMarker(marker) { return true }
      if attempt + 1 < Timing.markerAttempts {
        try await Task.sleep(nanoseconds: Timing.markerRetryNanoseconds)
      }
    }
    return false
  }

  func clearTerminalLine() async throws {
    _ = try await backend.awaitInputReadiness(timeout: timeout)
    _ = try await backend.sendKey(name: "control-u", timeout: timeout)
    try await Task.sleep(nanoseconds: Timing.terminalCommandSettleNanoseconds)
  }

  private func recognizesTerminalMarker(_ marker: String) async throws -> Bool {
    let image = try await backend.recoveryFrame(timeout: timeout)
    let lines = try recognizer.recognizeRecovery(
      image: image,
      displaySize: VirtualizationPrivateHeadlessBackend.displaySize,
      customWord: marker
    )
    let observation = RecoveryUIObservation(lines: lines)
    return observation.isLikelyTerminalWindow
      && observation.containsExactMarkerFollowedByShellPrompt(marker)
  }

  private var expectedKey: PommeRecoveryVirtualKey? {
    switch deliveredKeys {
    case []: .right
    case [.right]: .right
    case [.right, .right]: .return
    case [.right, .right, .return]: .return
    case [.right, .right, .return, .return]: .controlF2
    case [.right, .right, .return, .return, .controlF2],
      [.right, .right, .return, .return, .controlF2, .right],
      [.right, .right, .return, .return, .controlF2, .right, .right],
      [.right, .right, .return, .return, .controlF2, .right, .right, .right]:
      .right
    case [.right, .right, .return, .return, .controlF2, .right, .right, .right, .right]: .down
    case [.right, .right, .return, .return, .controlF2, .right, .right, .right, .right, .down]:
      .shiftCommandT
    default: nil
    }
  }

  private func frameFromReviewedTrace(
    coarse: PommeRecoveryFrame
  ) throws -> PommeRecoveryFrame {
    switch deliveredKeys {
    case []:
      return try require(coarse, .startupOptions, as: .startupOptions)
    case [.right]:
      return try require(coarse, .startupOptions, as: .startupIntermediate)
    case [.right, .right]:
      return try require(coarse, .startupOptions, as: .startupOptionsActivated)
    case [.right, .right, .return]:
      return try require(coarse, .languageEnglish, as: .languageEnglish)
    case [.right, .right, .return, .return],
      [.right, .right, .return, .return, .controlF2],
      [.right, .right, .return, .return, .controlF2, .right],
      [.right, .right, .return, .return, .controlF2, .right, .right],
      [.right, .right, .return, .return, .controlF2, .right, .right, .right],
      [.right, .right, .return, .return, .controlF2, .right, .right, .right, .right]:
      let deterministic: [PommeRecoveryFrame] = [
        .recoveryUtilities, .applicationMenu, .recoveryMenu, .fileMenu, .editMenu, .utilitiesMenu,
      ]
      guard coarse == .recoveryUtilities,
        let index = [
          [.right, .right, .return, .return],
          [.right, .right, .return, .return, .controlF2],
          [.right, .right, .return, .return, .controlF2, .right],
          [.right, .right, .return, .return, .controlF2, .right, .right],
          [.right, .right, .return, .return, .controlF2, .right, .right, .right],
          [.right, .right, .return, .return, .controlF2, .right, .right, .right, .right],
        ].firstIndex(of: deliveredKeys)
      else { throw PommeRecoveryVirtualizationPortError.unprovenFrame }
      return deterministic[index]
    case [.right, .right, .return, .return, .controlF2, .right, .right, .right, .right, .down]:
      return try require(coarse, .recoveryUtilities, as: .terminalMenuItem)
    case [
      .right, .right, .return, .return, .controlF2, .right, .right, .right, .right, .down,
      .shiftCommandT,
    ]:
      return try require(coarse, .terminal, as: .terminal)
    default:
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
  }

  private func require(
    _ actual: PommeRecoveryFrame,
    _ expected: PommeRecoveryFrame,
    as trace: PommeRecoveryFrame
  ) throws -> PommeRecoveryFrame {
    guard actual == expected else { throw PommeRecoveryVirtualizationPortError.unprovenFrame }
    return trace
  }

  private static func backendKeyName(for key: PommeRecoveryVirtualKey) -> String {
    switch key {
    case .controlF2: "ctrl-f2"
    case .right: "right"
    case .down: "down"
    case .return: "return"
    case .shiftCommandT: "shift-command-t"
    }
  }
}

enum PommeRecoveryVirtualizationPortError: Error, Equatable, Sendable {
  case unexpectedKey
  case unprovenFrame
  case unsafeLauncher
  case unsafeMarker
}
