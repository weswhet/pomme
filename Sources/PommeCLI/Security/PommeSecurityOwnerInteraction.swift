import Darwin
import Foundation

/// Confirmation authorizes one fresh-account effect. It conveys no authority
/// to skip credentials, management restrictions, or ownership verification.
struct PommeSecurityOwnerInteraction: Sendable {
  var isInteractive: @Sendable () -> Bool = { isatty(STDIN_FILENO) == 1 }
  var confirm: @Sendable (String) -> Bool = { message in
    let progress = PommeProgressContext.sink
    progress?.pause()
    defer { progress?.resume() }
    fputs(message + " [y/N] ", stderr)
    fflush(stderr)
    return ["y", "yes"].contains(
      readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
  }
  var readPrivate: @Sendable (String) -> String? = { prompt in
    let progress = PommeProgressContext.sink
    progress?.pause()
    defer { progress?.resume() }
    return readSecureLine(prompt: prompt)
  }

  func authorizeFreshOwner(vmName: String, force: Bool) throws {
    if force { return }
    guard isInteractive() else { throw PommeSecurityWorkflowError.confirmationRequired }
    guard confirm("Create administrator pomme and enable persistent automatic login on \(vmName)?")
    else {
      throw PommeSecurityWorkflowError.confirmationDeclined
    }
  }

  func existingOwner(vmName: String) throws -> PommeGuestSecurityCredentials {
    guard isInteractive(),
      let user = readPrivate("Owner account for \(vmName): "),
      (try? validateGuestAccountName(user, flag: "owner account")) != nil,
      let password = readPrivate("Password for \(user) on \(vmName): ")
    else {
      throw PommeSecurityWorkflowError.ownerUnavailable
    }
    return try .init(username: user, password: password)
  }

  func shouldSaveOwner(vmName: String) -> Bool {
    isInteractive()
      && confirm("Save this exact VM owner credential for \(vmName) in the login Keychain?")
  }

  static func environmentOwner(_ environment: [String: String]) throws
    -> PommeGuestSecurityCredentials?
  {
    let user = environment["POMME_AUTHORIZED_USER"]
    let password = environment["POMME_AUTHORIZED_PASSWORD"]
    guard user != nil || password != nil else { return nil }
    guard let user, let password,
      (try? validateGuestAccountName(user, flag: "POMME_AUTHORIZED_USER")) != nil
    else {
      throw PommeSecurityWorkflowError.ownerUnavailable
    }
    return try .init(username: user, password: password)
  }
}
