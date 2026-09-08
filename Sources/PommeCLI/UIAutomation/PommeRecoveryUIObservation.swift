import CoreGraphics
import Foundation

/// The small OCR-derived vocabulary shared by Pomme's Recovery frame
/// classifier and its terminal-proof recognizer.
///
/// This is deliberately an observation-only value. It does not retain image
/// data, invoke input, or depend on a guest transport. Callers must still
/// supply the Pomme display geometry and their own input authorization.
enum RecoveryUIScreenState: Equatable, Sendable {
  case recoveryHome
  case unknown
}

/// A closed, redacted breakdown of a non-secret Recovery Terminal proof.
/// It intentionally contains no recognized strings, screen geometry, image
/// data, or marker value.
struct RecoveryTerminalMarkerProofDiagnostic: Equatable, Sendable {
  let terminalWindow: Bool
  let exactMarker: Bool
  let freshPromptAfterMarker: Bool

  var isVerified: Bool {
    terminalWindow && exactMarker && freshPromptAfterMarker
  }
}

struct RecoveryUIObservation: Sendable {
  let lines: [SettingsAIOCRLine]

  /// Requires the Options/disk captions and a picker action. Once a tile is
  /// selected, Vision can omit the low-contrast bottom power actions. Its
  /// Continue control is an alternative only below an aligned picker caption;
  /// arbitrary Continue text elsewhere on screen cannot anchor this surface.
  var isAnchoredStartupPicker: Bool {
    let text = normalizedText
    guard let options = line(exactly: "Options"),
      let disk = line(exactly: "Macintosh HD")
    else { return false }
    if text.contains("restart") || text.contains("shut down") {
      return true
    }
    guard let action = line(exactly: "Continue"),
      options.rect.minX > disk.rect.maxX,
      abs(options.rect.midY - disk.rect.midY) <= 24
    else { return false }
    return [options, disk].contains { caption in
      abs(action.rect.midX - caption.rect.midX) <= 64
        && action.rect.minY >= caption.rect.maxY
        && action.rect.maxY <= caption.rect.maxY + 100
    }
  }

  /// Bare Language/English labels are not sufficient. Recovery must be
  /// named by one of the explicit macOS Recovery/Installer anchors.
  var hasExplicitRecoveryLanguageAnchor: Bool {
    let tokens = normalizedTokens
    guard tokens.contains("language") || tokens.contains("english") else {
      return false
    }
    return containsPhrase(["macos", "recovery"], in: tokens)
      || containsPhrase(["macos", "installer"], in: tokens)
      || containsPhrase(["macos", "installation"], in: tokens)
  }

  /// Tahoe may present a language/legal surface without repeating the
  /// Recovery title immediately after the reviewed Options activation.  It
  /// is usable only with that already-receipted context; it is never a
  /// generic English-language match.
  var isAmbiguousLanguageOrLegalSurface: Bool {
    let tokens = normalizedTokens
    return tokens.contains("language")
      && tokens.contains("english")
      && containsPhrase(["terms", "of", "the", "software", "license", "agreement"], in: tokens)
  }

  /// The first Setup Assistant page has a distinctive country/region
  /// heading and Continue control. Keep this guard local so the Recovery
  /// classifier cannot mistake that page for the startup picker.
  var isLikelySetupAssistantCountryOrRegion: Bool {
    let tokens = normalizedTokens
    guard !tokens.contains("recovery"),
      !tokens.contains("installer"),
      !tokens.contains("installation")
    else {
      return false
    }

    let continueToken = tokens.contains("continue")
    guard continueToken else { return false }

    let boundedHeading =
      containsPhrase(["select", "country", "or", "region"], in: tokens)
      || containsPhrase(["select", "your", "country", "or", "region"], in: tokens)
      || containsPhrase(["choose", "country", "or", "region"], in: tokens)
      || containsPhrase(["choose", "your", "country", "or", "region"], in: tokens)
    let splitHeading =
      tokens.contains("country")
      && tokens.contains("region")
      && containsPhrase(["accessibility", "options"], in: tokens)
    return boundedHeading || splitHeading
  }

  /// Tahoe's first normal boot may initially publish the Language page
  /// instead of Country or Region. Accept that surface only when Language and
  /// English are corroborated by both legal phrases. A visible SLA-like URL
  /// must be Apple's exact HTTPS legal/SLA URL; a different or extended URL
  /// disqualifies the observation. Recovery and Installer anchors always win.
  var isLikelySetupAssistantLanguageOrLegal: Bool {
    let tokens = normalizedTokens
    guard tokens.contains("language"),
      tokens.contains("english"),
      containsPhrase(["using", "this", "software"], in: tokens),
      containsPhrase(["license", "agreement"], in: tokens),
      !tokens.contains("recovery"),
      !tokens.contains("installer"),
      !tokens.contains("installation")
    else { return false }

    let text = lines.map(\.text).joined(separator: "\n")
    return Self.allSLAURLCandidatesAreCanonical(in: text)
  }

  var isLikelySetupAssistantReady: Bool {
    isLikelySetupAssistantCountryOrRegion
      || isLikelySetupAssistantLanguageOrLegal
  }

  /// Pomme's Recovery home screen has at least one of the stable utility
  /// labels below. Other screens remain unknown and therefore cannot be
  /// treated as the home screen by the frame classifier.
  var state: RecoveryUIScreenState {
    guard !isLikelySetupAssistantReady else { return .unknown }
    let text = normalizedText
    if text.contains("restore from time machine")
      || text.contains("reinstall macos")
      || (text.contains("disk utility") && text.contains("recovery"))
    {
      return .recoveryHome
    }
    return .unknown
  }

  /// The word Terminal also appears in the Utilities menu. Require a shell
  /// marker before allowing a caller to use this observation as terminal
  /// proof.
  var isLikelyTerminalWindow: Bool {
    let text = normalizedText
    guard text.contains("terminal") else { return false }
    if text.contains("startup security utility")
      || text.contains("recovery assistant")
      || text.contains("share disk")
    {
      return false
    }
    return text.contains("bash")
      || text.contains("zsh")
      || text.contains("sh-")
      || text.contains("sh #")
      || text.contains("sh $")
  }

  /// A marker is only complete when a fresh shell prompt appears below it.
  /// This prevents a stale prompt in terminal scrollback from being used as
  /// evidence for the current marker.
  func containsExactMarkerFollowedByShellPrompt(_ marker: String) -> Bool {
    terminalMarkerProofDiagnostic(marker).freshPromptAfterMarker
  }

  /// Splits a marker proof into a fixed set of booleans for debug diagnostics.
  /// This preserves the proof rule: Terminal must be recognized, the marker
  /// must be exact, and a shell prompt must occur below that marker.
  func terminalMarkerProofDiagnostic(_ marker: String) -> RecoveryTerminalMarkerProofDiagnostic {
    let expected = Self.normalize(marker)
    guard !expected.isEmpty else {
      return .init(
        terminalWindow: isLikelyTerminalWindow,
        exactMarker: false,
        freshPromptAfterMarker: false
      )
    }
    let compactExpected = expected.replacingOccurrences(of: " ", with: "")
    let markers = lines.filter {
      Self.isExactMarkerLine(
        $0,
        expected: expected,
        compactExpected: compactExpected
      )
    }
    let prompts = lines.filter { Self.isShellPromptLine($0.text) }
    let hasFreshPromptAfterMarker = markers.contains { markerLine in
      prompts.contains { promptLine in
        promptLine.rect.minY >= markerLine.rect.maxY - 2
      }
    }
    return .init(
      terminalWindow: isLikelyTerminalWindow,
      exactMarker: !markers.isEmpty,
      freshPromptAfterMarker: hasFreshPromptAfterMarker
    )
  }

  private var normalizedText: String {
    Self.normalize(lines.map(\.text).joined(separator: "\n"))
  }

  private var normalizedTokens: [String] {
    lines.map(\.text).joined(separator: "\n")
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }

  private func line(exactly text: String) -> SettingsAIOCRLine? {
    let expected = Self.normalize(text)
    return lines.first { Self.normalize($0.text) == expected }
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

  private static func isExactMarkerLine(
    _ line: SettingsAIOCRLine,
    expected: String,
    compactExpected: String
  ) -> Bool {
    let candidate = normalize(
      line.text
        .replacingOccurrences(of: "\u{0412}", with: "B")
        .replacingOccurrences(of: "\u{0432}", with: "b")
        .replacingOccurrences(of: "\u{041E}", with: "O")
        .replacingOccurrences(of: "\u{043E}", with: "o")
    )
    return candidate == expected
      || candidate.replacingOccurrences(of: " ", with: "") == compactExpected
  }

  private static func isShellPromptLine(_ text: String) -> Bool {
    normalize(text).range(
      of: #"^(?:-?(?:ba|z)?sh(?:-[0-9.]+)?|sh-)[[:space:]]*[#$][[:space:]]*[|]?[[:space:]]*$"#,
      options: .regularExpression
    ) != nil
  }

  /// OCR may omit the URL entirely, but every visible domain/legal/path URL
  /// must be the one exact reviewed Apple HTTPS SLA URL. Inspecting every
  /// candidate prevents one valid URL from masking a second hostile one.
  private static func allSLAURLCandidatesAreCanonical(in text: String) -> Bool {
    let folded = text.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    ).lowercased()
    // Vision can insert whitespace around URL punctuation or at a wrapped
    // URL boundary. Compact only that punctuation, then validate the whole
    // whitespace-delimited token. This prevents a canonical substring from
    // hiding a malformed scheme prefix, path suffix, query, or second URL.
    let compacted = folded.replacingOccurrences(
      of: #"\s*([:/.?#%&=+,;\[\]\\])\s*"#,
      with: "$1",
      options: .regularExpression
    )
    let candidates = compacted.components(separatedBy: .whitespacesAndNewlines)
      .filter { $0.contains("/legal/") }
    let canonical = [
      "https://www.apple.com/legal/sla",
      "https://www.apple.com/legal/sla/",
    ]
    return candidates.allSatisfy(canonical.contains)
  }

  private func containsPhrase(_ phrase: [String], in tokens: [String]) -> Bool {
    guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
    return tokens.indices.dropLast(phrase.count - 1).contains { start in
      tokens[start..<(start + phrase.count)].elementsEqual(phrase)
    }
  }
}
