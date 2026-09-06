import Foundation
import Testing

@Suite("Private owner PTY diagnostics")
struct PommeSecurityPrivatePTYDiagnosticTests {
  @Test("Known failures retain fixed codes across the helper boundary")
  func knownFailures() {
    let failures: [(PommePrivatePTYRunner.Error, PommeSecurityPrivatePTYDiagnostic)] = [
      (.promptMissing, .promptMissing), (.unsafePrompt, .unsafePrompt),
      (.repeatedPrompt, .repeatedPrompt), (.secretEchoed, .secretEchoed),
      (.promptTimedOut, .promptTimedOut), (.processTimedOut, .processTimedOut),
      (.cleanupUnverified, .cleanupUnverified), (.invalidCompletion, .invalidCompletion),
      (.transportFailure, .transportFailure),
    ]
    for (error, expected) in failures {
      let helper = PommeSecurityPrivatePTYDiagnostic(error)
      let parent = PommeSecurityPrivatePTYDiagnostic.decode(.string(helper.rawValue))
      #expect(parent == expected)
      #expect(PommeSecurityPrivatePTYDiagnostic(parent) == expected)
    }
  }

  @Test("Arbitrary error and wire text never becomes a diagnostic")
  func unknownErrorsAreRedacted() {
    let privateText = "fixture-password-and-private-transcript"
    let error = NSError(
      domain: privateText, code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: privateText
      ])
    #expect(PommeSecurityPrivatePTYDiagnostic(error) == .unclassified)
    let values: [JSONValue?] = [
      nil, .string(privateText), .object(["error": .string(privateText)]), .integer(1),
    ]
    for value in values {
      #expect(PommeSecurityPrivatePTYDiagnostic.decode(value) == .unclassified)
    }
    #expect(!PommeSecurityPrivatePTYDiagnostic(error).rawValue.contains(privateText))
  }
}
