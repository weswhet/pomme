import Foundation

/// Only these fixed codes may cross the private PTY failure boundary.
/// Unknown errors never contribute descriptions, arguments, or output.
enum PommeSecurityPrivatePTYDiagnostic: String, Error, CaseIterable, Sendable {
  case invalidCommand
  case invalidSecret
  case secretInCommand
  case invalidPrompt
  case invalidTimeout
  case invalidCompletion
  case unrelatedJobFrame
  case unsafePrompt
  case promptTimedOut
  case promptMissing
  case processExitedBeforePrompt
  case repeatedPrompt
  case secretEchoed
  case promptOutputLimit
  case processTimedOut
  case cancelled
  case transportFailure
  case cleanupUnverified
  case unclassified

  init(_ error: any Error) {
    if let diagnostic = error as? Self {
      self = diagnostic
      return
    }
    guard let error = error as? PommePrivatePTYRunner.Error else {
      self = .unclassified
      return
    }
    switch error {
    case .invalidCommand: self = .invalidCommand
    case .invalidSecret: self = .invalidSecret
    case .secretInCommand: self = .secretInCommand
    case .invalidPrompt: self = .invalidPrompt
    case .invalidTimeout: self = .invalidTimeout
    case .invalidCompletion: self = .invalidCompletion
    case .unrelatedJobFrame: self = .unrelatedJobFrame
    case .unsafePrompt: self = .unsafePrompt
    case .promptTimedOut: self = .promptTimedOut
    case .promptMissing: self = .promptMissing
    case .processExitedBeforePrompt: self = .processExitedBeforePrompt
    case .repeatedPrompt: self = .repeatedPrompt
    case .secretEchoed: self = .secretEchoed
    case .promptOutputLimit: self = .promptOutputLimit
    case .processTimedOut: self = .processTimedOut
    case .cancelled: self = .cancelled
    case .transportFailure: self = .transportFailure
    case .cleanupUnverified: self = .cleanupUnverified
    }
  }

  static func decode(_ value: JSONValue?) -> Self {
    guard case .string(let code)? = value else { return .unclassified }
    return Self(rawValue: code) ?? .unclassified
  }
}
