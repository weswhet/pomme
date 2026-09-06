import CoreGraphics
import Foundation

/// A framebuffer capture retains only the image long enough for one
/// classification. The digest is used as an in-memory cache key so OCR is not
/// repeated for identical frames; no image or OCR text leaves this module.
struct PommeRecoveryFrameCapture: @unchecked Sendable {
  let digest: String
  let image: CGImage?

  init(image: CGImage) throws {
    self.digest = try Self.digest(of: image)
    self.image = image
  }

  /// Test seam for exercising readiness without constructing a Virtualization
  /// VM or storing screenshots. Production captures always include an image.
  init(digest: String) {
    self.digest = digest
    self.image = nil
  }

  private static func digest(of image: CGImage) throws -> String {
    guard let providerData = image.dataProvider?.data,
      CFDataGetLength(providerData) > 0,
      let bytes = CFDataGetBytePtr(providerData)
    else { throw PommeRecoveryVirtualizationPortError.unprovenFrame }
    var material = Data(
      "\(image.width)x\(image.height):\(image.bitsPerComponent):\(image.bitsPerPixel):\(image.bytesPerRow)\n".utf8
    )
    material.append(Data(bytes: bytes, count: CFDataGetLength(providerData)))
    return PommeProvisioningDigest.sha256(material)
  }
}

/// Waits for a specific, already-authorized Recovery checkpoint to become
/// observable. It retries only transient display publication/blank-frame
/// failures and unknown or mismatching classifications; malformed frames and
/// ABI failures are propagated immediately. Two identical captures are
/// required before invoking the classifier, and each digest/context pair is
/// classified at most once per session.
actor PommeRecoveryObservationReadiness {
  typealias Capture = @Sendable (TimeInterval) async throws -> PommeRecoveryFrameCapture
  typealias Classify = @Sendable (
    PommeRecoveryFrameCapture,
    PommeRecoveryFrameClassificationContext
  ) throws -> PommeRecoveryFrame
  typealias Sleep = @Sendable (UInt64) async throws -> Void
  typealias Clock = @Sendable () -> Date

  private struct CacheKey: Hashable, Sendable {
    let digest: String
    let context: String
  }

  private let capture: Capture
  private let classify: Classify
  private let sleep: Sleep
  private let clock: Clock
  private let pollNanoseconds: UInt64
  private var classifications: [CacheKey: PommeRecoveryFrame] = [:]
  private var priorDigest: String?
  private var stableCaptureCount = 0
  private var isObserving = false
  private var lastClassificationAt: Date?

  init(
    capture: @escaping Capture,
    classify: @escaping Classify,
    sleep: @escaping Sleep = { nanoseconds in
      try await Task.sleep(nanoseconds: nanoseconds)
    },
    clock: @escaping Clock = Date.init,
    pollNanoseconds: UInt64 = 100_000_000
  ) {
    self.capture = capture
    self.classify = classify
    self.sleep = sleep
    self.clock = clock
    self.pollNanoseconds = max(1, pollNanoseconds)
  }

  func waitForExpected(
    _ expected: PommeRecoveryFrame,
    context: PommeRecoveryFrameClassificationContext,
    timeout: TimeInterval
  ) async throws -> PommeRecoveryFrame {
    guard !isObserving else {
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
    isObserving = true
    defer { isObserving = false }
    guard timeout.isFinite, timeout > 0 else {
      throw PommeRecoveryVirtualizationPortError.invalidObservationTimeout
    }
    // Every call represents a new checkpoint after exactly one delivered
    // input. Require two captures from this call even if the same digest was
    // already classified at the previous checkpoint.
    priorDigest = nil
    stableCaptureCount = 0
    let deadline = clock().addingTimeInterval(timeout)
    while true {
      try Task.checkCancellation()
      let remaining = deadline.timeIntervalSince(clock())
      guard remaining > 0 else {
        throw PommeRecoveryVirtualizationPortError.observationTimedOut(expected)
      }

      do {
        let captureTimeout = max(0.1, min(timeout, remaining))
        let captured = try await capture(captureTimeout)
        if priorDigest == captured.digest {
          stableCaptureCount += 1
        } else {
          priorDigest = captured.digest
          stableCaptureCount = 1
        }

        let key = CacheKey(
          digest: captured.digest,
          context: context.cacheKey
        )
        if stableCaptureCount >= 2, let cached = classifications[key] {
          if cached == expected { return cached }
        } else if stableCaptureCount >= 2,
          lastClassificationAt.map({ clock().timeIntervalSince($0) >= 2 }) ?? true
        {
          let classified = try classify(captured, context)
          lastClassificationAt = clock()
          if classifications.count >= 128,
             let oldest = classifications.keys.first
          {
            classifications.removeValue(forKey: oldest)
          }
          classifications[key] = classified
          if classified == expected { return classified }
        }
      } catch let error as VirtualizationPrivateHeadlessError
        where VirtualizationPrivateHeadlessBackend.isTransientRecoveryCaptureFailure(error)
      {
        // A blank/provisional framebuffer cannot authorize input. Reset the
        // cheap stability gate and ask for another observation instead.
        priorDigest = nil
        stableCaptureCount = 0
      }

      let afterCapture = deadline.timeIntervalSince(clock())
      guard afterCapture > 0 else {
        throw PommeRecoveryVirtualizationPortError.observationTimedOut(expected)
      }
      let sleepNanoseconds = min(
        pollNanoseconds,
        max(1, UInt64(afterCapture * 1_000_000_000))
      )
      try await sleep(sleepNanoseconds)
    }
  }
}

private extension PommeRecoveryFrameClassificationContext {
  var cacheKey: String {
    switch self {
    case .unproven: "unproven"
    case .optionsActivated: "options-activated"
    }
  }
}

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
  private let readiness: PommeRecoveryObservationReadiness
  private var deliveredKeys: [PommeRecoveryVirtualKey] = []

  init(backend: VirtualizationPrivateHeadlessBackend, timeout: TimeInterval) {
    self.backend = backend
    self.timeout = timeout
    let recognizer = SettingsAIOCRRecognizer()
    self.readiness = .init(
      capture: { timeout in
        try .init(image: await backend.recoveryFrame(timeout: timeout))
      },
      classify: { capture, context in
        guard let image = capture.image else {
          throw PommeRecoveryVirtualizationPortError.unprovenFrame
        }
        let lines = try recognizer.recognizeRecovery(
          image: image,
          displaySize: VirtualizationPrivateHeadlessBackend.displaySize
        )
        return PommeRecoveryFrameClassifier.classify(
          image: image,
          lines: lines,
          context: context
        )
      }
    )
  }

  func nextRecoveryFrame() async throws -> PommeRecoveryFrame {
    guard let expected = expectedCoarseFrame else {
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
    let context: PommeRecoveryFrameClassificationContext =
      deliveredKeys == [.right, .right, .return]
      ? .optionsActivated
      : .unproven
    let coarse = try await readiness.waitForExpected(
      expected,
      context: context,
      timeout: timeout
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

  private var expectedCoarseFrame: PommeRecoveryFrame? {
    switch deliveredKeys {
    case [], [.right], [.right, .right]:
      .startupOptions
    case [.right, .right, .return]:
      .languageEnglish
    case [.right, .right, .return, .return],
      [.right, .right, .return, .return, .controlF2],
      [.right, .right, .return, .return, .controlF2, .right],
      [.right, .right, .return, .return, .controlF2, .right, .right],
      [.right, .right, .return, .return, .controlF2, .right, .right, .right],
      [.right, .right, .return, .return, .controlF2, .right, .right, .right, .right],
      [.right, .right, .return, .return, .controlF2, .right, .right, .right, .right, .down]:
      .recoveryUtilities
    case [
      .right, .right, .return, .return, .controlF2, .right, .right, .right, .right, .down,
      .shiftCommandT,
    ]:
      .terminal
    default:
      nil
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
  case invalidObservationTimeout
  case observationTimedOut(PommeRecoveryFrame)
  case unsafeLauncher
  case unsafeMarker
}
