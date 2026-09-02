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
      context == .optionsActivated && observation.isAmbiguousLanguageOrLegalSurface
    let languageProven = observation.hasExplicitRecoveryLanguageAnchor || contextBoundLanguage
    let setupAssistantConflict = observation.isLikelySetupAssistantCountryOrRegion
      || (observation.isLikelySetupAssistantLanguageOrLegal && !contextBoundLanguage)
    if englishCandidates.count == 1,
      languageProven,
      !setupAssistantConflict
    {
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
}
