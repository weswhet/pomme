import CoreGraphics
import Foundation

/// Coarse events emitted by ``PommeRecoveryNavigationRecognizer``.  Events
/// contain no OCR text, image data, or other screen content, so callers can
/// use them for timing without expanding the Recovery observation boundary.
enum PommeRecoveryNavigationRecognitionEvent: Equatable, Sendable {
  case regionOCR
  case regionCacheHit
  case fullFrameFallback
}

/// Incremental OCR for the fixed Recovery display.
///
/// Recovery still requires the caller to capture and compare two fresh,
/// identical full frames around every input.  This helper only changes how a
/// single already-captured frame is reduced to a closed frame label: it OCRs
/// four overlapping, full-width horizontal bands and reuses the previous
/// digest-plus-lines value for an unchanged band.  It never retains a
/// framebuffer.
///
/// The class is deliberately synchronous and serializes all mutable state
/// with its lock.  That makes it usable from the existing actor and from
/// synchronous classifier closures without requiring a second actor hop.
final class PommeRecoveryNavigationRecognizer: @unchecked Sendable {
  typealias OCR = @Sendable (CGImage, CGSize) throws -> [SettingsAIOCRLine]
  typealias EventHandler = @Sendable (PommeRecoveryNavigationRecognitionEvent) -> Void

  static let displaySize = CGSize(width: 1280, height: 800)

  private struct Band: Sendable {
    let crop: CGRect
    let core: CGRect
  }

  private struct BandState: Sendable {
    let digest: String
    /// OCR coordinates are local to the band's crop.  Keeping only these
    /// values and the digest avoids retaining the CGImage or its backing data.
    let lines: [SettingsAIOCRLine]
  }

  private struct ContextCache: Sendable {
    let contextKey: String
    let bands: [BandState]
  }

  private struct Surface {
    let image: CGImage
    let digest: String
  }

  private struct Candidate {
    let line: SettingsAIOCRLine
    let sourceBand: Int
    let ownerBand: Int?
  }

  private let ocr: OCR
  private let eventHandler: EventHandler
  private let bands: [Band]
  private let lock = NSLock()
  private var cache: ContextCache?

  /// Creates a recognizer for the reviewed 1280x800 Recovery display.
  ///
  /// ``bandCount`` controls the number of non-overlapping ownership cores.
  /// ``overlap`` adds pixels on both sides of each interior core boundary so
  /// text near that boundary is visible to both OCR requests.  The default
  /// four 200-pixel cores with a 32-pixel overlap keep each OCR request small
  /// while retaining the complete display in the union of the bands.
  init(
    ocr: @escaping OCR,
    onEvent: EventHandler? = nil,
    bandCount: Int = 4,
    overlap: Int = 32
  ) {
    self.ocr = ocr
    self.eventHandler = onEvent ?? { _ in }
    self.bands = Self.makeBands(count: bandCount, overlap: overlap)
  }

  /// Drops all cached digests and OCR lines.  The next frame is regional-OCR
  /// qualified from scratch.  The Recovery launcher should call this before
  /// beginning a sensitive Terminal command so prior screen text cannot be
  /// carried into that observation.
  func clear() {
    lock.lock()
    cache = nil
    lock.unlock()
  }

  /// Alias kept explicit for callers that describe the operation as a reset.
  func reset() {
    clear()
  }

  /// Classifies one captured frame while preserving the existing closed
  /// Recovery classifier and its negative/conflict anchors.
  ///
  /// Regional OCR is accepted only when the classifier recognizes a reviewed
  /// frame.  Unknown or conflicting regional evidence, invalid geometry, and
  /// OCR text touching a band cut edge all force one full-frame OCR pass.
  func classify(
    image: CGImage,
    context: PommeRecoveryFrameClassificationContext = .unproven
  ) throws -> PommeRecoveryFrame {
    lock.lock()
    var events: [PommeRecoveryNavigationRecognitionEvent] = []
    let result: Result<PommeRecoveryFrame, Error>
    do {
      result = .success(try classifyLocked(image: image, context: context, events: &events))
    } catch {
      result = .failure(error)
    }
    lock.unlock()

    // Never invoke arbitrary caller code while holding the state lock.  This
    // also lets a metrics callback clear the recognizer without deadlocking.
    for event in events {
      eventHandler(event)
    }
    return try result.get()
  }

  private func classifyLocked(
    image: CGImage,
    context: PommeRecoveryFrameClassificationContext,
    events: inout [PommeRecoveryNavigationRecognitionEvent]
  ) throws -> PommeRecoveryFrame {
    let validGeometry = image.width == Int(Self.displaySize.width)
      && image.height == Int(Self.displaySize.height)
    guard validGeometry, !bands.isEmpty else {
      cache = nil
      return try classifyFullFrame(
        image: image,
        context: context,
        bands: [],
        events: &events
      )
    }

    let contextKey = Self.cacheKey(for: context)
    // Context is part of the cache identity.  A context change invalidates the
    // previous regional reduction instead of carrying a result across the
    // Options-activated language surface.
    if cache?.contextKey != contextKey {
      cache = nil
    }

    // Establish a complete, conflict-aware baseline before attempting any
    // incremental reduction.  Besides being cheaper than four model calls on
    // the first frame, this gives the cache a full-scene seed rather than
    // asking regional OCR to establish a security-relevant screen identity.
    if cache == nil {
      return try classifyFullFrame(
        image: image,
        context: context,
        bands: bands,
        events: &events
      )
    }

    var states: [BandState] = []
    var candidates: [Candidate] = []
    var seamUncertain = false

    for (index, band) in bands.enumerated() {
      guard let surface = Self.makeSurface(from: image, crop: band.crop) else {
        return try classifyFullFrame(
          image: image,
          context: context,
          bands: bands,
          events: &events
        )
      }

      let lines: [SettingsAIOCRLine]
      if let prior = cache?.bands[safe: index], prior.digest == surface.digest {
        lines = prior.lines
        events.append(.regionCacheHit)
      } else {
        lines = try ocr(surface.image, band.crop.size)
        events.append(.regionOCR)
      }
      states.append(.init(digest: surface.digest, lines: lines))

      if lines.contains(where: { Self.touchesCropCutEdge($0.rect, cropSize: band.crop.size) }) {
        seamUncertain = true
      }
      candidates.append(contentsOf: lines.map { line in
        let mapped = line.withRect(line.rect.offsetBy(dx: band.crop.minX, dy: band.crop.minY))
        return Candidate(
          line: mapped,
          sourceBand: index,
          ownerBand: Self.ownerBand(for: mapped.rect.midY, bands: bands)
        )
      })
    }

    let lines = Self.merge(candidates)
    let regional = PommeRecoveryFrameClassifier.classify(
      image: image,
      lines: lines,
      context: context
    )
    let observation = RecoveryUIObservation(lines: lines)
    let hasSetupAssistantConflict = observation.isLikelySetupAssistantCountryOrRegion
      || observation.isLikelySetupAssistantLanguageOrLegal
    guard !seamUncertain, !hasSetupAssistantConflict, regional != .unknown else {
      return try classifyFullFrame(
        image: image,
        context: context,
        bands: bands,
        events: &events
      )
    }

    cache = .init(contextKey: contextKey, bands: states)
    return regional
  }

  private func classifyFullFrame(
    image: CGImage,
    context: PommeRecoveryFrameClassificationContext,
    bands: [Band],
    events: inout [PommeRecoveryNavigationRecognitionEvent]
  ) throws -> PommeRecoveryFrame {
    events.append(.fullFrameFallback)
    let displaySize = CGSize(width: image.width, height: image.height)
    let lines = try ocr(image, displaySize)
    let frame = PommeRecoveryFrameClassifier.classify(
      image: image,
      lines: lines,
      context: context
    )

    // Full-frame OCR is also a trustworthy way to seed the next regional
    // reduction.  Only digest-plus-lines values are kept, and only for the
    // current context.  Invalid geometry cannot seed a cache because the
    // closed classifier rejected it.
    if !bands.isEmpty,
       image.width == Int(Self.displaySize.width),
       image.height == Int(Self.displaySize.height)
    {
      if let seededStates = Self.cacheStates(
        fromFullFrame: lines,
        image: image,
        bands: bands
      ) {
        cache = .init(
          contextKey: Self.cacheKey(for: context),
          bands: seededStates
        )
      } else {
        cache = nil
      }
    } else {
      cache = nil
    }
    return frame
  }

  private static func makeBands(count: Int, overlap: Int) -> [Band] {
    let width = Int(displaySize.width)
    let height = Int(displaySize.height)
    guard count >= 2, overlap >= 0 else { return [] }

    var result: [Band] = []
    result.reserveCapacity(count)
    for index in 0..<count {
      let coreMinY = (index * height) / count
      let coreMaxY = ((index + 1) * height) / count
      let cropMinY = max(0, coreMinY - overlap)
      let cropMaxY = min(height, coreMaxY + overlap)
      guard coreMaxY > coreMinY, cropMaxY > cropMinY else { return [] }
      result.append(
        .init(
          crop: CGRect(
            x: 0,
            y: cropMinY,
            width: width,
            height: cropMaxY - cropMinY
          ),
          core: CGRect(
            x: 0,
            y: coreMinY,
            width: width,
            height: coreMaxY - coreMinY
          )
        )
      )
    }
    return result
  }

  private static func makeSurface(from image: CGImage, crop: CGRect) -> Surface? {
    guard let cropped = image.cropping(to: crop.integral),
          let context = CGContext(
            data: nil,
            width: Int(crop.width),
            height: Int(crop.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(crop.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    context.interpolationQuality = .none
    context.setBlendMode(.copy)
    context.draw(
      cropped,
      in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
    )
    guard let surface = context.makeImage(),
          let data = surface.dataProvider?.data,
          CFDataGetLength(data) > 0,
          let bytes = CFDataGetBytePtr(data)
    else { return nil }

    var material = Data(
      "\(surface.width)x\(surface.height):\(surface.bitsPerComponent):\(surface.bitsPerPixel):\(surface.bytesPerRow)\n".utf8
    )
    material.append(Data(bytes: bytes, count: CFDataGetLength(data)))
    return .init(image: surface, digest: PommeProvisioningDigest.sha256(material))
  }

  private static func touchesCropCutEdge(_ rect: CGRect, cropSize: CGSize) -> Bool {
    // One point is intentionally conservative at a crop boundary.  A line
    // clipped by either adjacent OCR request must be re-read from the whole
    // frame before it can influence a closed screen classification.
    let tolerance: CGFloat = 1
    return rect.minY <= tolerance
      || rect.maxY >= cropSize.height - tolerance
  }

  private static func ownerBand(for centerY: CGFloat, bands: [Band]) -> Int? {
    for (index, band) in bands.enumerated() {
      let isLast = index == bands.count - 1
      if centerY >= band.core.minY
        && (centerY < band.core.maxY || (isLast && centerY <= band.core.maxY))
      {
        return index
      }
    }
    return nil
  }

  private static func cacheStates(
    fromFullFrame lines: [SettingsAIOCRLine],
    image: CGImage,
    bands: [Band]
  ) -> [BandState]? {
    let surfaces = bands.compactMap { band in
      makeSurface(from: image, crop: band.crop)
    }
    guard surfaces.count == bands.count else { return nil }

    // A full-frame line that crosses its owning crop edge is evidence that a
    // regional request could have clipped it.  Refuse to seed that state so
    // the next observation performs full-frame OCR again instead of allowing
    // a tall or seam-crossing label to enter the incremental cache.
    for line in lines {
      guard let owner = ownerBand(for: line.rect.midY, bands: bands),
            bands[owner].crop.insetBy(dx: 1, dy: 1).contains(line.rect)
      else { return nil }
    }

    return bands.enumerated().map { index, band in
      let localLines = lines.compactMap { line -> SettingsAIOCRLine? in
        guard let owner = ownerBand(for: line.rect.midY, bands: bands),
              index == owner
        else { return nil }
        return line.withRect(line.rect.offsetBy(dx: -band.crop.minX, dy: -band.crop.minY))
      }
      return .init(digest: surfaces[index].digest, lines: localLines)
    }
  }

  private static func merge(_ candidates: [Candidate]) -> [SettingsAIOCRLine] {
    // Prefer the OCR result from the core that owns a line's center.  Keep a
    // non-owning candidate when its owner did not recognize that line, so an
    // unchanged neighboring overlap cannot erase screen/conflict evidence.
    let ordered = candidates.sorted { lhs, rhs in
      let lhsOwned = lhs.ownerBand == lhs.sourceBand
      let rhsOwned = rhs.ownerBand == rhs.sourceBand
      if lhsOwned != rhsOwned { return lhsOwned && !rhsOwned }
      return lhs.sourceBand < rhs.sourceBand
    }

    var merged: [Candidate] = []
    for candidate in ordered {
      guard !merged.contains(where: { Self.isDuplicate($0, candidate) }) else {
        continue
      }
      merged.append(candidate)
    }
    return merged.map(\.line).sorted(by: Self.readingOrder)
  }

  private static func isDuplicate(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    // A single OCR request is authoritative for all lines it returned.  Never
    // deduplicate within that request: repeated labels are meaningful evidence
    // to the closed classifier (for example, two English candidates).  Across
    // overlapping bands, require the same normalized text and a substantial
    // rectangle intersection; center proximity alone can collapse distinct
    // controls that happen to be near one another.
    guard lhs.sourceBand != rhs.sourceBand,
          normalize(lhs.line.text) == normalize(rhs.line.text)
    else { return false }
    let intersection = lhs.line.rect.intersection(rhs.line.rect)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
      return false
    }
    let lhsArea = lhs.line.rect.width * lhs.line.rect.height
    let rhsArea = rhs.line.rect.width * rhs.line.rect.height
    let smallerArea = min(lhsArea, rhsArea)
    guard smallerArea > 0 else { return false }
    let overlapRatio = (intersection.width * intersection.height) / smallerArea
    return overlapRatio >= 0.5
  }

  private static func readingOrder(
    _ lhs: SettingsAIOCRLine,
    _ rhs: SettingsAIOCRLine
  ) -> Bool {
    if abs(lhs.rect.minY - rhs.rect.minY) > 8 {
      return lhs.rect.minY < rhs.rect.minY
    }
    return lhs.rect.minX < rhs.rect.minX
  }

  private static func normalize(_ text: String) -> String {
    text.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    .lowercased()
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func cacheKey(for context: PommeRecoveryFrameClassificationContext) -> String {
    switch context {
    case .unproven: "unproven"
    case .optionsActivated: "options-activated"
    case .experimental27LanguageChooser: "experimental-27-language-chooser"
    }
  }
}

private extension SettingsAIOCRLine {
  func withRect(_ rect: CGRect) -> SettingsAIOCRLine {
    .init(text: text, confidence: confidence, rect: rect)
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
