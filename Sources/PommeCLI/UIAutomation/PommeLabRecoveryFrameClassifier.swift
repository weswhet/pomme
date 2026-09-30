import CoreGraphics
import Foundation

enum PommeRecoveryFrameClassifier {
  /// Tahoe OCR establishes only coarse cross-screen checkpoints.  The
  /// intervening menu-focus states are intentionally not inferred from text:
  /// the reviewed qualification trace proves those as individually receipted,
  /// deterministic keyboard transitions instead.
  static func classify(
    image: CGImage,
    lines: [SettingsAIOCRLine],
    context: PommeRecoveryFrameClassificationContext = .unproven
  ) -> PommeRecoveryFrame {
    guard image.width == Int(VirtualizationPrivateHeadlessBackend.displayWidth),
      image.height == Int(VirtualizationPrivateHeadlessBackend.displayHeight)
    else { return .unknown }
    let observation = RecoveryUIObservation(lines: lines)

    if observation.isAnchoredStartupPicker {
      return .startupOptions
    }

    let englishCandidates = exactLines("English", in: lines)
    let contextBoundLanguage =
      (context == .optionsActivated || context == .experimental27LanguageChooser)
      && observation.isAmbiguousLanguageOrLegalSurface
    let languageProven = observation.hasExplicitRecoveryLanguageAnchor || contextBoundLanguage
    let setupAssistantConflict = observation.isLikelySetupAssistantCountryOrRegion
      || (observation.isLikelySetupAssistantLanguageOrLegal && !contextBoundLanguage)
    if englishCandidates.count == 1,
      languageProven,
      !setupAssistantConflict
    {
      if context == .experimental27LanguageChooser {
        return experimentalLanguageSelection(image: image, english: englishCandidates[0], lines: lines)
      }
      return .languageEnglish
    }
    if observation.state == .recoveryHome {
      return .recoveryUtilities
    }
    if observation.isLikelyTerminalWindow {
      return .terminal
    }
    return .unknown
  }

  /// The macOS 27 chooser uses gray for an inactive selected row and
  /// blue for an active selected row. OCR alone proves neither selection nor
  /// focus. Require the English label inside the fixed first-row bounds and a
  /// substantial highlight across that row before permitting either action.
  /// Coordinates here and CGImage cropping are top-left display pixels.
  private static func experimentalLanguageSelection(
    image: CGImage, english: SettingsAIOCRLine, lines: [SettingsAIOCRLine]
  ) -> PommeRecoveryFrame {
    let row = CGRect(x: 508, y: 330, width: 246, height: 25)
    let headings = exactLines("Language", in: lines)
    guard english.confidence >= 0.5, english.rect.width > 0, english.rect.height > 0,
      row.insetBy(dx: 2, dy: 1).contains(english.rect),
      headings.count == 1,
      CGRect(x: 560, y: 270, width: 160, height: 45).contains(headings[0].rect),
      let crop = image.cropping(to: row.insetBy(dx: 4, dy: 3)),
      let context = CGContext(data: nil, width: crop.width, height: crop.height,
        bitsPerComponent: 8, bytesPerRow: crop.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = context.data
    else { return .unknown }
    context.setBlendMode(.copy)
    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var active = 0
    var inactive = 0
    let count = crop.width * crop.height
    for index in 0..<count {
      let red = Int(bytes[index * 4])
      let green = Int(bytes[index * 4 + 1])
      let blue = Int(bytes[index * 4 + 2])
      if red <= 20, (70...110).contains(green), (180...235).contains(blue) { active += 1 }
      if (58...85).contains(red), abs(red - green) <= 5, abs(red - blue) <= 5 { inactive += 1 }
    }
    if Double(active) / Double(count) >= 0.8 { return .languageEnglishActive }
    if Double(inactive) / Double(count) >= 0.8 { return .languageEnglishInactive }
    return .unknown
  }

  private static func exactLines(
    _ text: String,
    in lines: [SettingsAIOCRLine]
  ) -> [SettingsAIOCRLine] {
    let expected = normalizedWords(text)
    return lines.filter { normalizedWords($0.text) == expected }
  }

  private static func normalizedWords(_ text: String) -> [String] {
    text.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    .lowercased()
    .components(separatedBy: CharacterSet.alphanumerics.inverted)
    .filter { !$0.isEmpty }
  }

}

enum PommeRecoveryFrameClassificationContext: Equatable, Sendable {
  case unproven
  case optionsActivated
  case experimental27LanguageChooser
}
