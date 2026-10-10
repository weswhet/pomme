import Foundation

/// Only these fixed codes may cross the private PTY failure boundary.
/// Unknown errors never contribute descriptions, arguments, or output.
enum PommeSecurityPrivatePTYDiagnostic: String, PommeDescribedError, CaseIterable, Sendable {
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

  var code: PommeErrorCode {
    switch self {
    case .cancelled: .operationCancelled
    case .promptTimedOut, .processTimedOut: .timedOut
    default: .securityPrivateInputFailed
    }
  }

  /// Each description names only the failed step; none includes command
  /// output, arguments, or the credential.
  var errorDescription: String? {
    switch self {
    case .invalidCommand: "The guest command for the private terminal isn't valid."
    case .invalidSecret: "The owner's credential is empty, too long, or contains a line break."
    case .secretInCommand: "The guest command's arguments contain the owner's credential, so Pomme didn't run it."
    case .invalidPrompt: "The expected credential prompt for the guest command isn't valid."
    case .invalidTimeout: "The private terminal time limit isn't a positive number of seconds."
    case .invalidCompletion: "The guest command didn't report a valid exit status."
    case .unrelatedJobFrame: "The guest agent sent output from a different job."
    case .unsafePrompt: "The guest command showed a prompt that Pomme doesn't answer with the owner's credential."
    case .promptTimedOut: "The guest command didn't ask for the owner's credential within the time limit."
    case .promptMissing: "The guest command finished without asking for the owner's credential."
    case .processExitedBeforePrompt: "The guest command exited before it asked for the owner's credential."
    case .repeatedPrompt: "The guest command asked for the owner's credential again, which usually means it rejected it."
    case .secretEchoed: "The guest command displayed the owner's credential, so Pomme stopped it."
    case .promptOutputLimit: "The guest command printed too much output before its credential prompt."
    case .processTimedOut: "The guest command didn't finish within the time limit."
    case .cancelled: "The guest command was cancelled."
    case .transportFailure: "The connection to the guest agent failed while the guest command ran."
    case .cleanupUnverified: "Pomme couldn't confirm that the guest command stopped."
    case .unclassified: "The private terminal request failed for a reason that Pomme doesn't classify."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .repeatedPrompt: "Check the owner's user name and credential, then retry."
    case .transportFailure, .cleanupUnverified: "Run `pomme agent status NAME`, then retry."
    default: nil
    }
  }

  static func decode(_ value: JSONValue?) -> Self {
    guard case .string(let code)? = value else { return .unclassified }
    return Self(rawValue: code) ?? .unclassified
  }
}
