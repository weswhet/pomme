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

  /// Resets the per-session classification cache and stability state without
  /// retaining any previously observed frame label.
  func clear() {
    classifications.removeAll(keepingCapacity: false)
    priorDigest = nil
    stableCaptureCount = 0
  }

  func waitForExpected(
    _ expected: PommeRecoveryFrame,
    context: PommeRecoveryFrameClassificationContext,
    timeout: TimeInterval
  ) async throws -> PommeRecoveryFrame {
    let pair = try await waitForExpectedStablePair(
      expected,
      context: context,
      timeout: timeout
    )
    return pair[1]
  }

  /// Returns the two fresh observations that authorize one input checkpoint.
  /// The classifier may run once for the pair; the closed result is repeated
  /// so callers can prove the required two-frame equality without capturing a
  /// second stable pair inside this operation.
  func waitForExpectedStablePair(
    _ expected: PommeRecoveryFrame,
    context: PommeRecoveryFrameClassificationContext,
    timeout: TimeInterval
  ) async throws -> [PommeRecoveryFrame] {
    guard !isObserving else {
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
    isObserving = true
    defer { isObserving = false }
    guard timeout.isFinite, timeout > 0 else {
      throw PommeRecoveryVirtualizationPortError.invalidObservationTimeout
    }
    // Every call represents an independent fresh checkpoint. Require two
    // captures from this call even if the same digest was already classified
    // at a previous checkpoint.
    priorDigest = nil
    stableCaptureCount = 0
    // Cooldown applies to unsuccessful retries within this checkpoint only.
    // A newly delivered input must be eligible for immediate OCR even when
    // the preceding checkpoint was classified moments ago.
    var lastClassificationAt: Date?
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
          if cached == expected { return [cached, cached] }
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
          if classified == expected { return [classified, classified] }
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
    // OCR-backed checkpoints wait for the guest to publish the new screen.
    // Only focus transitions whose labels are intentionally inferred from the
    // reviewed trace keep a short bounded dwell before that observation.
    static let inferredFocusSettleNanoseconds: UInt64 = 100_000_000
    static let terminalCommandSettleNanoseconds: UInt64 = 250_000_000
    static let markerRetryNanoseconds: UInt64 = 500_000_000
    static let markerAttempts = 3
  }

  private let backend: VirtualizationPrivateHeadlessBackend
  private let timeout: TimeInterval
  private let recognizer: SettingsAIOCRRecognizer
  private let regionalRecognizer: PommeRecoveryNavigationRecognizer
  private let readiness: PommeRecoveryObservationReadiness
  private let metrics: PommeRecoveryPerformanceMetrics
  private let log: @Sendable (String) -> Void
  private var navigationRoute: PommeRecoveryNavigationRoute = .reviewedMenus
  private var hasObservedOrDelivered = false
  private var deliveredKeys: [PommeRecoveryVirtualKey] = []

  init(
    backend: VirtualizationPrivateHeadlessBackend,
    timeout: TimeInterval,
    metrics: PommeRecoveryPerformanceMetrics = .init(),
    log: @escaping @Sendable (String) -> Void = { PommeCore.log($0) }
  ) {
    self.backend = backend
    self.timeout = timeout
    self.metrics = metrics
    self.log = log
    let recognizer = SettingsAIOCRRecognizer(
      onRecognition: { seconds in
        metrics.record(.ocr, seconds: seconds)
      }
    )
    self.recognizer = recognizer
    let regionalRecognizer = PommeRecoveryNavigationRecognizer(
      ocr: { image, displaySize in
        try recognizer.recognizeRecovery(image: image, displaySize: displaySize)
      },
      onEvent: { event in
        switch event {
        case .regionOCR:
          break
        case .regionCacheHit:
          metrics.record(.regionCacheHit)
        case .fullFrameFallback:
          metrics.record(.fullFrameFallback)
        }
      }
    )
    self.regionalRecognizer = regionalRecognizer
    self.readiness = .init(
      capture: { timeout in
        let captureStart = PommeRecoveryPerformanceMetrics.now()
        let image: CGImage
        do {
          image = try await backend.recoveryFrame(timeout: timeout)
        } catch {
          metrics.record(.capture, since: captureStart)
          throw error
        }
        metrics.record(.capture, since: captureStart)

        let hashStart = PommeRecoveryPerformanceMetrics.now()
        do {
          let captured = try PommeRecoveryFrameCapture(image: image)
          metrics.record(.hash, since: hashStart)
          return captured
        } catch {
          metrics.record(.hash, since: hashStart)
          throw error
        }
      },
      classify: { capture, context in
        let classificationStart = PommeRecoveryPerformanceMetrics.now()
        defer {
          metrics.record(.classification, since: classificationStart)
        }
        guard let image = capture.image else {
          throw PommeRecoveryVirtualizationPortError.unprovenFrame
        }
        return try regionalRecognizer.classify(
          image: image,
          context: context
        )
      },
      sleep: { nanoseconds in
        let waitStart = PommeRecoveryPerformanceMetrics.now()
        defer { metrics.record(.wait, since: waitStart) }
        try await Task.sleep(nanoseconds: nanoseconds)
      }
    )
  }

  /// Selects the immutable navigation trace before Recovery observation or
  /// input begins. Repeating the already-selected route is harmless; changing
  /// it after either effect has started is rejected so frame and key history
  /// cannot be interpreted against a different trace.
  func prepareRecoveryNavigation(route: PommeRecoveryNavigationRoute) async throws {
    guard route == navigationRoute || !hasObservedOrDelivered else {
      throw PommeRecoveryVirtualizationPortError.navigationRouteLocked
    }
    navigationRoute = route
  }

  func nextRecoveryFrame() async throws -> PommeRecoveryFrame {
    let pair = try await nextRecoveryFramePair()
    return pair[1]
  }

  func nextRecoveryFramePair() async throws -> [PommeRecoveryFrame] {
    hasObservedOrDelivered = true
    guard let expected = expectedCoarseFrame else {
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
    let context = classificationContext
    let coarsePair = try await readiness.waitForExpectedStablePair(
      expected,
      context: context,
      timeout: timeout
    )
    return try coarsePair.map { try frameFromNavigationTrace(coarse: $0) }
  }

  func deliverRecoveryKey(
    _ key: PommeRecoveryVirtualKey
  ) async throws -> PommeRecoveryDurableInputReceipt {
    hasObservedOrDelivered = true
    guard let expectedKey, key == expectedKey else {
      throw PommeRecoveryVirtualizationPortError.unexpectedKey
    }
    let inputStart = PommeRecoveryPerformanceMetrics.now()
    defer { metrics.record(.input, since: inputStart) }
    _ = try await backend.awaitInputReadiness(timeout: timeout)
    _ = try await backend.sendKey(name: Self.backendKeyName(for: key), timeout: timeout)
    let coarseFrameBeforeDelivery = expectedCoarseFrame
    deliveredKeys.append(key)
    let coarseFrameAfterDelivery = expectedCoarseFrame
    let settleNanoseconds = coarseFrameBeforeDelivery == coarseFrameAfterDelivery
      ? Timing.inferredFocusSettleNanoseconds
      : 0
    if settleNanoseconds > 0 {
      try await sleep(settleNanoseconds)
    }
    return .init(key: key, deliveredEventCount: 1)
  }

  func clearRecoveryObservations() async {
    await readiness.clear()
    regionalRecognizer.clear()
  }

  func reportRecoveryPerformance(phase: PommeRecoveryPerformancePhase) async {
    log(metrics.summary(phase: phase))
  }

  func submitTerminalLine(_ command: String) async throws {
    guard PommeRecoveryTerminalCommand.isKeyboardSafe(command) else {
      throw PommeRecoveryVirtualizationPortError.unsafeLauncher
    }
    _ = try await backend.awaitInputReadiness(timeout: timeout)
    _ = try await backend.typeText(command, replace: false, timeout: timeout)
    _ = try await backend.sendKey(name: "return", timeout: timeout)
    try await sleep(Timing.terminalCommandSettleNanoseconds)
  }

  func terminalMarkerIsVerified(_ marker: String) async throws -> Bool {
    guard PommeRecoveryTerminalCommand.isSafeMarker(marker) else {
      throw PommeRecoveryVirtualizationPortError.unsafeMarker
    }
    for attempt in 0..<Timing.markerAttempts {
      if try await recognizesTerminalMarker(marker) { return true }
      if attempt + 1 < Timing.markerAttempts {
        try await sleep(Timing.markerRetryNanoseconds)
      }
    }
    return false
  }

  func clearTerminalLine() async throws {
    _ = try await backend.awaitInputReadiness(timeout: timeout)
    _ = try await backend.sendKey(name: "control-u", timeout: timeout)
    try await sleep(Timing.terminalCommandSettleNanoseconds)
  }

  private func recognizesTerminalMarker(_ marker: String) async throws -> Bool {
    let captureStart = PommeRecoveryPerformanceMetrics.now()
    let image: CGImage
    do {
      image = try await backend.recoveryFrame(timeout: timeout)
    } catch {
      metrics.record(.capture, since: captureStart)
      throw error
    }
    metrics.record(.capture, since: captureStart)
    let lines = try recognizer.recognizeRecoveryTerminalMarker(
      image: image,
      displaySize: VirtualizationPrivateHeadlessBackend.displaySize,
      marker: marker
    )
    let observation = RecoveryUIObservation(lines: lines)
    return observation.isLikelyTerminalWindow
      && observation.containsExactMarkerFollowedByShellPrompt(marker)
  }

  private func sleep(_ nanoseconds: UInt64) async throws {
    let waitStart = PommeRecoveryPerformanceMetrics.now()
    defer { metrics.record(.wait, since: waitStart) }
    try await Task.sleep(nanoseconds: nanoseconds)
  }

  private var expectedKey: PommeRecoveryVirtualKey? {
    guard deliveredKeysMatchRoutePrefix,
      deliveredKeys.count < navigationRoute.eventTrace.count
    else { return nil }
    return navigationRoute.eventTrace[deliveredKeys.count].key
  }

  private var expectedCoarseFrame: PommeRecoveryFrame? {
    guard let logicalFrame = expectedLogicalFrame else { return nil }
    return Self.coarseFrame(for: logicalFrame)
  }

  private var expectedLogicalFrame: PommeRecoveryFrame? {
    guard deliveredKeysMatchRoutePrefix else { return nil }
    let events = navigationRoute.eventTrace
    if deliveredKeys.count < events.count {
      return events[deliveredKeys.count].preEventFrame
    }
    guard deliveredKeys.count == events.count else { return nil }
    return events.last?.postEventFrame
  }

  private var classificationContext: PommeRecoveryFrameClassificationContext {
    expectedLogicalFrame == .languageEnglish ? .optionsActivated : .unproven
  }

  private var deliveredKeysMatchRoutePrefix: Bool {
    let routeKeys = navigationRoute.keys
    guard deliveredKeys.count <= routeKeys.count else { return false }
    return routeKeys.prefix(deliveredKeys.count).elementsEqual(deliveredKeys)
  }

  private func frameFromNavigationTrace(
    coarse: PommeRecoveryFrame
  ) throws -> PommeRecoveryFrame {
    guard let logicalFrame = expectedLogicalFrame,
      coarse == Self.coarseFrame(for: logicalFrame)
    else {
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
    return logicalFrame
  }

  private static func coarseFrame(for logicalFrame: PommeRecoveryFrame) -> PommeRecoveryFrame? {
    switch logicalFrame {
    case .startupOptions, .startupIntermediate, .startupOptionsActivated:
      .startupOptions
    case .languageEnglish:
      .languageEnglish
    case .recoveryUtilities, .applicationMenu, .recoveryMenu, .fileMenu, .editMenu,
      .utilitiesMenu, .terminalMenuItem:
      .recoveryUtilities
    case .terminal:
      .terminal
    case .unknown:
      nil
    }
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
  case navigationRouteLocked
  case unprovenFrame
  case invalidObservationTimeout
  case observationTimedOut(PommeRecoveryFrame)
  case unsafeLauncher
  case unsafeMarker
}
