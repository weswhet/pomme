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
  /// Minimum spacing between OCR classifications of a still-changing screen
  /// within one checkpoint. Region OCR is cached, so a short cool-down keeps
  /// a new screen from waiting up to two seconds before it is recognised.
  static let classificationCooldown: TimeInterval = 0.5
  private var classifications: [CacheKey: PommeRecoveryFrame] = [:]
  private var priorDigest: String?
  private var stableCaptureCount = 0
  /// This remains nil until a stable pair reaches the closed classifier.
  /// It distinguishes unstable/raw-frame timeouts from a classified
  /// `.unknown` result without retaining OCR text, image data, or a
  /// framebuffer digest beyond the active checkpoint.
  private var lastObservedFrame: PommeRecoveryFrame?
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
    lastObservedFrame = nil
  }

  /// The most recent stable, classified Recovery frame for the active
  /// checkpoint. A nil result means no stable frame reached classification;
  /// `.unknown` means the closed classifier did run and rejected the frame.
  func lastObservedFrameDiagnostic() -> PommeRecoveryFrame? {
    lastObservedFrame
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
    try await waitForExpectedStablePair(
      anyOf: [expected],
      context: context,
      timeout: timeout
    )
  }

  /// Accepts only an explicitly enumerated set of closed states. Each state
  /// still requires a fresh, stable two-frame observation before the caller
  /// can decide whether to advance its single-receipt trace.
  func waitForExpectedStablePair(
    anyOf expectedFrames: [PommeRecoveryFrame],
    context: PommeRecoveryFrameClassificationContext,
    timeout: TimeInterval
  ) async throws -> [PommeRecoveryFrame] {
    guard !isObserving else {
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
    isObserving = true
    defer { isObserving = false }
    let acceptedFrames = expectedFrames.reduce(into: [PommeRecoveryFrame]()) { unique, frame in
      if !unique.contains(frame) { unique.append(frame) }
    }
    guard !acceptedFrames.isEmpty,
          !acceptedFrames.contains(.unknown),
          timeout.isFinite,
          timeout > 0
    else {
      throw PommeRecoveryVirtualizationPortError.invalidObservationTimeout
    }
    // Every call represents an independent fresh checkpoint. Require two
    // captures from this call even if the same digest was already classified
    // at a previous checkpoint.
    priorDigest = nil
    stableCaptureCount = 0
    lastObservedFrame = nil
    // Cooldown applies to unsuccessful retries within this checkpoint only.
    // A newly delivered input must be eligible for immediate OCR even when
    // the preceding checkpoint was classified moments ago.
    var lastClassificationAt: Date?
    let deadline = clock().addingTimeInterval(timeout)
    while true {
      try Task.checkCancellation()
      let remaining = deadline.timeIntervalSince(clock())
      guard remaining > 0 else {
        throw PommeRecoveryVirtualizationPortError.observationTimedOut(acceptedFrames[0])
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
          lastObservedFrame = cached
          if acceptedFrames.contains(cached) { return [cached, cached] }
        } else if stableCaptureCount >= 2,
          lastClassificationAt.map({ clock().timeIntervalSince($0) >= Self.classificationCooldown }) ?? true
        {
          let classified = try classify(captured, context)
          lastObservedFrame = classified
          lastClassificationAt = clock()
          if classifications.count >= 128,
             let oldest = classifications.keys.first
          {
            classifications.removeValue(forKey: oldest)
          }
          classifications[key] = classified
          if acceptedFrames.contains(classified) { return [classified, classified] }
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
        throw PommeRecoveryVirtualizationPortError.observationTimedOut(acceptedFrames[0])
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
    case .experimental27LanguageChooser: "experimental-27-language-chooser"
    }
  }
}

/// The direct-Virtualization Recovery port.  Each observation stays in memory
/// only long enough for Vision to reduce it to a closed frame state.  This
/// type never writes a screenshot or exposes OCR text.
actor PommeRecoveryVirtualizationKeyboardPort: PommeRecoveryTerminalPort {
  private struct NavigationExpectation {
    let logicalFrames: [PommeRecoveryFrame]
    let coarseFrames: [PommeRecoveryFrame]
    let context: PommeRecoveryFrameClassificationContext

    func logicalFrame(for coarseFrame: PommeRecoveryFrame) -> PommeRecoveryFrame? {
      logicalFrames.first { logical in
        PommeRecoveryVirtualizationKeyboardPort.coarseFrame(for: logical) == coarseFrame
      }
    }
  }

  private enum Timing {
    // OCR-backed checkpoints wait for the guest to publish the new screen.
    // Only focus transitions whose labels are intentionally inferred from the
    // reviewed trace keep a short bounded dwell before that observation.
    static let inferredFocusSettleNanoseconds: UInt64 = 100_000_000
    static let terminalCommandSettleNanoseconds: UInt64 = 250_000_000
    static let markerRetryNanoseconds: UInt64 = 500_000_000
    /// The first command in a cold Recovery shell can take a few seconds to
    /// exec (dyld cache and binaries are read from the freshly restored or
    /// cloned image). Each attempt is one capture plus OCR, so a ten-second
    /// window costs nothing when the marker appears immediately.
    static let markerAttempts = 20
  }

  private let backend: VirtualizationPrivateHeadlessBackend
  private let timeout: TimeInterval
  private let recognizer: SettingsAIOCRRecognizer
  private let regionalRecognizer: PommeRecoveryNavigationRecognizer
  private let readiness: PommeRecoveryObservationReadiness
  private let metrics: PommeRecoveryPerformanceMetrics
  private let log: @Sendable (String) -> Void
  /// Optional and host-local only. It is deliberately not part of the
  /// navigation profile, durable receipt, or Recovery guest protocol.
  private let screenshotRecorder: PommeRecoveryNavigationScreenshotRecorder?
  private var navigationRoute: PommeRecoveryNavigationRoute = .reviewedMenus
  private var hasObservedOrDelivered = false
  private var navigationEventIndex = 0
  private var pendingPostEvent: PommeRecoveryNavigationEvent?

  init(
    backend: VirtualizationPrivateHeadlessBackend,
    timeout: TimeInterval,
    metrics: PommeRecoveryPerformanceMetrics = .init(),
    screenshotRecorder: PommeRecoveryNavigationScreenshotRecorder? = nil,
    log: @escaping @Sendable (String) -> Void = { PommeCore.log($0) }
  ) {
    self.backend = backend
    self.timeout = timeout
    self.metrics = metrics
    self.log = log
    self.screenshotRecorder = screenshotRecorder
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
    guard let expectation = navigationExpectation else {
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
    do {
      let coarsePair = try await readiness.waitForExpectedStablePair(
        anyOf: expectation.coarseFrames,
        context: expectation.context,
        timeout: timeout
      )
      guard let observedCoarse = coarsePair.first,
            let logicalFrame = expectation.logicalFrame(for: observedCoarse)
      else {
        throw PommeRecoveryVirtualizationPortError.unprovenFrame
      }
      if let pendingPostEvent {
        guard let nextIndex = pendingPostEvent.nextEventIndex(
          after: logicalFrame,
          defaultIndex: navigationEventIndex + 1
        ), nextIndex <= navigationRoute.eventTrace.count
        else { throw PommeRecoveryVirtualizationPortError.unprovenFrame }
        navigationEventIndex = nextIndex
        self.pendingPostEvent = nil
      }
      return [logicalFrame, logicalFrame]
    } catch let error as PommeRecoveryVirtualizationPortError {
      if case .observationTimedOut = error {
        try await screenshotRecorder?.captureTimeout(awaiting: expectation.logicalFrames)
        let lastObserved = await readiness.lastObservedFrameDiagnostic()
        log(
          "Recovery navigation observation timed out "
            + "[expected=\(Self.diagnosticFrameNames(expectation.logicalFrames)), "
            + "lastObserved=\(Self.diagnosticFrameName(lastObserved))]."
        )
      }
      throw error
    }
  }

  func deliverRecoveryKey(
    _ key: PommeRecoveryVirtualKey
  ) async throws -> PommeRecoveryDurableInputReceipt {
    try await deliverRecoveryInput(.key(key))
  }

  func deliverRecoveryInput(
    _ input: PommeRecoveryNavigationInput
  ) async throws -> PommeRecoveryDurableInputReceipt {
    hasObservedOrDelivered = true
    guard pendingPostEvent == nil,
          let event = currentNavigationEvent,
          input == event.input
    else {
      throw PommeRecoveryVirtualizationPortError.unexpectedKey
    }
    let inputStart = PommeRecoveryPerformanceMetrics.now()
    defer { metrics.record(.input, since: inputStart) }
    try await PommeRecoveryNavigationScreenshotRecorder.captureBeforeNavigationInput(
      recorder: screenshotRecorder,
      from: event.preEventFrame,
      input: event.input,
      expectedDestinations: event.acceptedPostEventFrames,
      awaitInputReadiness: { [backend, timeout] in
        _ = try await backend.awaitInputReadiness(timeout: timeout)
      },
      reproveAfterCapture: { [weak self, event] in
        guard let self else { throw PommeRecoveryVirtualizationPortError.unprovenFrame }
        try await self.reproveNavigationEvent(event)
      },
      deliver: { [backend, input, timeout] in
        switch input {
        case .key(let key):
          _ = try await backend.sendKey(name: Self.backendKeyName(for: key), timeout: timeout)
        case .activateLanguageChooser:
          _ = try await backend.click(x: 1006, y: 671, timeout: timeout)
        }
      }
    )
    let coarseFrameBeforeDelivery = Self.coarseFrame(for: event.preEventFrame)
    pendingPostEvent = event
    let coarseFrameAfterDelivery = event.acceptedPostEventFrames
      .compactMap(Self.coarseFrame(for:))
      .first
    let settleNanoseconds = coarseFrameBeforeDelivery == coarseFrameAfterDelivery
      ? Timing.inferredFocusSettleNanoseconds
      : 0
    if settleNanoseconds > 0 {
      try await sleep(settleNanoseconds)
    }
    return .init(input: input, deliveredEventCount: 1)
  }

  func clearRecoveryObservations() async {
    await readiness.clear()
    regionalRecognizer.clear()
  }

  func reportRecoveryPerformance(phase: PommeRecoveryPerformancePhase) async {
    log(metrics.summary(phase: phase))
  }

  /// Host-local diagnostic metadata for the invoking CLI/helper. This value
  /// is intentionally separate from Recovery receipts and guest messages.
  func recoveryDebugScreenshotDirectory() async -> URL? {
    await screenshotRecorder?.directory()
  }

  func recoveryDebugScreenshotFiles() async -> [URL] {
    await screenshotRecorder?.savedFiles() ?? []
  }

  func recoveryDebugScreenshotWarnings() async -> [String] {
    await screenshotRecorder?.warnings() ?? []
  }

  func submitTerminalLine(_ command: String) async throws {
    // No Terminal command entry, launcher submission, or resulting output is
    // part of Recovery navigation evidence.
    await screenshotRecorder?.disable()
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
      let proof = try await recognizesTerminalMarker(marker)
      log(
        "Recovery Terminal marker proof "
          + "[attempt=\(attempt + 1), terminalWindow=\(proof.terminalWindow), "
          + "exactMarker=\(proof.exactMarker), "
          + "freshPromptAfterMarker=\(proof.freshPromptAfterMarker)]."
      )
      if proof.isVerified { return true }
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

  private func recognizesTerminalMarker(
    _ marker: String
  ) async throws -> RecoveryTerminalMarkerProofDiagnostic {
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
    return observation.terminalMarkerProofDiagnostic(marker)
  }

  private func sleep(_ nanoseconds: UInt64) async throws {
    let waitStart = PommeRecoveryPerformanceMetrics.now()
    defer { metrics.record(.wait, since: waitStart) }
    try await Task.sleep(nanoseconds: nanoseconds)
  }

  private var currentNavigationEvent: PommeRecoveryNavigationEvent? {
    guard navigationEventIndex < navigationRoute.eventTrace.count else { return nil }
    return navigationRoute.eventTrace[navigationEventIndex]
  }

  /// A debug capture is deliberately bounded but may take long enough for a
  /// transient Recovery surface to change. Before the key is sent, obtain a
  /// new stable closed observation of the same authorized event.
  private func reproveNavigationEvent(_ event: PommeRecoveryNavigationEvent) async throws {
    guard let expected = Self.coarseFrame(for: event.preEventFrame) else {
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
    let context = Self.classificationContext(for: [event.preEventFrame])
    let frames: [PommeRecoveryFrame]
    do {
      frames = try await readiness.waitForExpectedStablePair(
        expected,
        context: context,
        timeout: timeout
      )
    } catch let error as PommeRecoveryVirtualizationPortError {
      if case .observationTimedOut = error {
        // This is a second, post-capture proof rather than the normal
        // navigation observer. Take one diagnostic frame directly; it does
        // not re-enter readiness and therefore cannot recurse.
        try await screenshotRecorder?.captureTimeout(awaiting: [event.preEventFrame])
      }
      throw error
    }
    guard frames.count == 2, frames.allSatisfy({ $0 == expected }) else {
      throw PommeRecoveryVirtualizationPortError.unprovenFrame
    }
  }

  private var navigationExpectation: NavigationExpectation? {
    let logicalFrames: [PommeRecoveryFrame]
    if let pendingPostEvent {
      logicalFrames = pendingPostEvent.acceptedPostEventFrames
    } else if let event = currentNavigationEvent {
      logicalFrames = [event.preEventFrame]
    } else {
      return nil
    }
    let coarseFrames = Self.uniqueFrames(logicalFrames.compactMap { Self.coarseFrame(for: $0) })
    guard !coarseFrames.isEmpty else { return nil }
    return .init(
      logicalFrames: logicalFrames,
      coarseFrames: coarseFrames,
      context: Self.classificationContext(for: logicalFrames)
    )
  }

  private static func coarseFrame(for logicalFrame: PommeRecoveryFrame) -> PommeRecoveryFrame? {
    switch logicalFrame {
    case .startupOptions, .startupIntermediate, .startupOptionsActivated:
      .startupOptions
    case .languageEnglish, .languageEnglishInactive, .languageEnglishActive:
      logicalFrame
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

  private static func classificationContext(for frames: [PommeRecoveryFrame]) -> PommeRecoveryFrameClassificationContext {
    if frames.contains(.languageEnglishInactive) || frames.contains(.languageEnglishActive) {
      return .experimental27LanguageChooser
    }
    return frames.contains(.languageEnglish) ? .optionsActivated : .unproven
  }

  private static func uniqueFrames(_ frames: [PommeRecoveryFrame]) -> [PommeRecoveryFrame] {
    frames.reduce(into: []) { unique, frame in
      if !unique.contains(frame) { unique.append(frame) }
    }
  }

  /// Keep Recovery diagnostics constrained to the fixed frame vocabulary.
  /// In particular, do not log OCR output, frame hashes, pixels, command
  /// text, or any state that could occur after launcher submission.
  private static func diagnosticFrameName(_ frame: PommeRecoveryFrame?) -> String {
    guard let frame else { return "none" }
    return switch frame {
    case .startupOptions: "startupOptions"
    case .startupIntermediate: "startupIntermediate"
    case .startupOptionsActivated: "startupOptionsActivated"
    case .languageEnglish: "languageEnglish"
    case .languageEnglishInactive: "languageEnglishInactive"
    case .languageEnglishActive: "languageEnglishActive"
    case .recoveryUtilities: "recoveryUtilities"
    case .applicationMenu: "applicationMenu"
    case .recoveryMenu: "recoveryMenu"
    case .fileMenu: "fileMenu"
    case .editMenu: "editMenu"
    case .utilitiesMenu: "utilitiesMenu"
    case .terminalMenuItem: "terminalMenuItem"
    case .terminal: "terminal"
    case .unknown: "unknown"
    }
  }

  private static func diagnosticFrameNames(_ frames: [PommeRecoveryFrame]) -> String {
    frames.map { diagnosticFrameName($0) }.joined(separator: "|")
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
