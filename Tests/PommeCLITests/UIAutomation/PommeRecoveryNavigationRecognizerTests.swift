import CoreGraphics
import Foundation
import Testing

@Suite("Pomme Recovery incremental navigation OCR")
struct PommeRecoveryNavigationRecognizerTests {
  @Test("initial full OCR seeds a cache and unchanged bands avoid OCR")
  func unchangedBandsAvoidOCR() throws {
    let probe = RecoveryOCRProbe(mode: .startup)
    let events = RecoveryRecognitionEventRecorder()
    let recognizer = PommeRecoveryNavigationRecognizer(
      ocr: { image, displaySize in
        probe.recognize(image: image, displaySize: displaySize)
      },
      onEvent: { event in events.append(event) }
    )
    let image = try makeRecoveryImage()

    #expect(try recognizer.classify(image: image) == .startupOptions)
    #expect(try recognizer.classify(image: image) == .startupOptions)
    #expect(probe.fullFrameCalls == 1)
    #expect(probe.regionalCalls == 0)
    #expect(events.values.filter { $0 == .regionCacheHit }.count == 4)
  }

  @Test("a changed band is OCRd while unchanged bands remain cached")
  func changedBandIsOCRd() throws {
    let probe = RecoveryOCRProbe(mode: .startup)
    let recognizer = PommeRecoveryNavigationRecognizer(
      ocr: { image, displaySize in
        probe.recognize(image: image, displaySize: displaySize)
      }
    )
    let baseline = try makeRecoveryImage()
    let changed = try makeRecoveryImage(changedRect: CGRect(x: 300, y: 250, width: 100, height: 50))

    #expect(try recognizer.classify(image: baseline) == .startupOptions)
    #expect(try recognizer.classify(image: changed) == .startupOptions)
    #expect(probe.fullFrameCalls == 1)
    #expect(probe.regionalCalls == 1)
  }

  @Test("changed dialog evidence forces full frame OCR")
  func changedUnexpectedDialogEvidenceIsIncluded() throws {
    let probe = RecoveryOCRProbe(mode: .startup)
    let events = RecoveryRecognitionEventRecorder()
    let recognizer = PommeRecoveryNavigationRecognizer(
      ocr: { image, displaySize in
        probe.recognize(image: image, displaySize: displaySize)
      },
      onEvent: { event in events.append(event) }
    )
    let baseline = try makeRecoveryImage()
    let changed = try makeRecoveryImage(changedRect: CGRect(x: 300, y: 250, width: 100, height: 50))

    #expect(try recognizer.classify(image: baseline) == .startupOptions)
    probe.mode = .dialog
    #expect(try recognizer.classify(image: changed) == .unknown)
    #expect(probe.regionalCalls == 1)
    #expect(probe.fullFrameCalls == 2)
    #expect(events.values.contains(.fullFrameFallback))
    #expect(probe.fullFrameText.contains("Select Country or Region"))
  }

  @Test("classification context is part of the cache identity")
  func contextIsNotReused() throws {
    let probe = RecoveryOCRProbe(mode: .startup)
    let recognizer = PommeRecoveryNavigationRecognizer(
      ocr: { image, displaySize in
        probe.recognize(image: image, displaySize: displaySize)
      }
    )
    let image = try makeRecoveryImage()

    #expect(
      try recognizer.classify(image: image, context: .unproven) == .startupOptions
    )
    #expect(
      try recognizer.classify(image: image, context: .optionsActivated) == .startupOptions
    )
    #expect(probe.fullFrameCalls == 2)
    #expect(probe.regionalCalls == 0)
  }

  @Test("text touching an overlap cut edge forces full frame OCR")
  func seamUncertaintyFallsBack() throws {
    let probe = RecoveryOCRProbe(mode: .startup)
    let events = RecoveryRecognitionEventRecorder()
    let recognizer = PommeRecoveryNavigationRecognizer(
      ocr: { image, displaySize in
        probe.recognize(image: image, displaySize: displaySize)
      },
      onEvent: { event in events.append(event) }
    )
    let baseline = try makeRecoveryImage()
    let changed = try makeRecoveryImage(changedRect: CGRect(x: 300, y: 250, width: 100, height: 50))

    #expect(try recognizer.classify(image: baseline) == .startupOptions)
    probe.mode = .seam
    #expect(try recognizer.classify(image: changed) == .startupOptions)
    #expect(probe.regionalCalls == 1)
    #expect(probe.fullFrameCalls == 2)
    #expect(events.values.contains(.fullFrameFallback))
  }

  @Test("clear removes every cached band")
  func clearEmptiesCache() throws {
    let probe = RecoveryOCRProbe(mode: .startup)
    let recognizer = PommeRecoveryNavigationRecognizer(
      ocr: { image, displaySize in
        probe.recognize(image: image, displaySize: displaySize)
      }
    )
    let image = try makeRecoveryImage()

    #expect(try recognizer.classify(image: image) == .startupOptions)
    recognizer.clear()
    #expect(try recognizer.classify(image: image) == .startupOptions)
    #expect(probe.fullFrameCalls == 2)
    #expect(probe.regionalCalls == 0)
  }

  @Test("distinct same-band labels are never deduplicated")
  func sameBandLabelsRemainDistinct() throws {
    let probe = RecoveryOCRProbe(mode: .duplicateEnglish)
    let events = RecoveryRecognitionEventRecorder()
    let recognizer = PommeRecoveryNavigationRecognizer(
      ocr: { image, displaySize in
        probe.recognize(image: image, displaySize: displaySize)
      },
      onEvent: { event in events.append(event) }
    )
    let image = try makeRecoveryImage()

    // Two exact English candidates make the closed classifier remain unknown.
    // If same-band proximity deduplication were used, one would disappear and
    // this second call could incorrectly be accepted as languageEnglish.
    #expect(try recognizer.classify(image: image) == .unknown)
    #expect(try recognizer.classify(image: image) == .unknown)
    #expect(probe.fullFrameCalls == 2)
    #expect(events.values.contains(.fullFrameFallback))
  }

  @Test("a full-frame line crossing its owner crop edge does not seed cache")
  func tallSeamLineForcesFreshFullFrame() throws {
    let probe = RecoveryOCRProbe(mode: .tallText)
    let recognizer = PommeRecoveryNavigationRecognizer(
      ocr: { image, displaySize in
        probe.recognize(image: image, displaySize: displaySize)
      }
    )
    let image = try makeRecoveryImage()

    #expect(try recognizer.classify(image: image) == .startupOptions)
    #expect(try recognizer.classify(image: image) == .startupOptions)
    #expect(probe.fullFrameCalls == 2)
    #expect(probe.regionalCalls == 0)
  }
}

private enum RecoveryOCRMode {
  case startup
  case dialog
  case seam
  case duplicateEnglish
  case tallText
}

private final class RecoveryOCRProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var regionalCallCount = 0
  private var fullFrameCallCount = 0
  private var fullFrameLines: [SettingsAIOCRLine] = []
  private var currentMode: RecoveryOCRMode

  init(mode: RecoveryOCRMode) {
    currentMode = mode
  }

  var mode: RecoveryOCRMode {
    get {
      lock.lock()
      defer { lock.unlock() }
      return currentMode
    }
    set {
      lock.lock()
      currentMode = newValue
      lock.unlock()
    }
  }

  var regionalCalls: Int {
    lock.lock()
    defer { lock.unlock() }
    return regionalCallCount
  }

  var fullFrameCalls: Int {
    lock.lock()
    defer { lock.unlock() }
    return fullFrameCallCount
  }

  var fullFrameText: String {
    lock.lock()
    defer { lock.unlock() }
    return fullFrameLines.map(\.text).joined(separator: "\n")
  }

  func recognize(image: CGImage, displaySize: CGSize) -> [SettingsAIOCRLine] {
    _ = image
    let isFullFrame = displaySize == PommeRecoveryNavigationRecognizer.displaySize
    lock.lock()
    let mode = currentMode
    if isFullFrame {
      fullFrameCallCount += 1
    } else {
      regionalCallCount += 1
    }
    lock.unlock()

    if isFullFrame {
      let lines: [SettingsAIOCRLine]
      switch mode {
      case .startup, .seam:
        lines = startupLines()
      case .dialog:
        lines = dialogLines(global: true)
      case .duplicateEnglish:
        lines = duplicateEnglishLines()
      case .tallText:
        lines = startupLines() + [
          .init(text: "tall label", confidence: 1, rect: CGRect(x: 300, y: 100, width: 100, height: 180))
        ]
      }
      lock.lock()
      fullFrameLines = lines
      lock.unlock()
      return lines
    }

    switch mode {
    case .startup, .duplicateEnglish, .tallText:
      return []
    case .dialog:
      return displaySize.height == 264 ? dialogLines(global: false) : []
    case .seam:
      return displaySize.height == 264
        ? [SettingsAIOCRLine(text: "partial", confidence: 1, rect: CGRect(x: 400, y: 0, width: 80, height: 14))]
        : []
    }
  }

  private func startupLines() -> [SettingsAIOCRLine] {
    [
      .init(text: "Macintosh HD", confidence: 1, rect: CGRect(x: 486, y: 100, width: 100, height: 14)),
      .init(text: "Options", confidence: 1, rect: CGRect(x: 730, y: 100, width: 60, height: 14)),
      .init(text: "Continue", confidence: 1, rect: CGRect(x: 724, y: 150, width: 56, height: 14)),
    ]
  }

  private func dialogLines(global: Bool) -> [SettingsAIOCRLine] {
    let y = global ? 250 : 80
    return [
      .init(text: "Select Country or Region", confidence: 1, rect: CGRect(x: 500, y: y, width: 280, height: 18)),
      .init(text: "Continue", confidence: 1, rect: CGRect(x: 620, y: y + 40, width: 56, height: 14)),
    ]
  }

  private func duplicateEnglishLines() -> [SettingsAIOCRLine] {
    [
      .init(text: "English", confidence: 1, rect: CGRect(x: 500, y: 100, width: 80, height: 14)),
      .init(text: "English", confidence: 1, rect: CGRect(x: 500, y: 115, width: 80, height: 14)),
      .init(text: "macOS Recovery", confidence: 1, rect: CGRect(x: 500, y: 145, width: 140, height: 14)),
    ]
  }
}

private final class RecoveryRecognitionEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [PommeRecoveryNavigationRecognitionEvent] = []

  func append(_ event: PommeRecoveryNavigationRecognitionEvent) {
    lock.lock()
    recorded.append(event)
    lock.unlock()
  }

  var values: [PommeRecoveryNavigationRecognitionEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

private enum RecoveryFixtureError: Error {
  case imageUnavailable
}

private func makeRecoveryImage(changedRect: CGRect? = nil) throws -> CGImage {
  guard let context = CGContext(
    data: nil,
    width: 1280,
    height: 800,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else {
    throw RecoveryFixtureError.imageUnavailable
  }
  context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
  if let changedRect {
    context.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(changedRect)
  }
  guard let image = context.makeImage() else {
    throw RecoveryFixtureError.imageUnavailable
  }
  return image
}
