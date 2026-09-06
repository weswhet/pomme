import Foundation

/// LocalPolicy can be changed only in authenticated Recovery. NVRAM changes
/// require a normal boot with SIP disabled. Each injected stage owns its
/// durable intent and receipt, so repeating this order resumes partial work.
struct PommeSecurityAMFIStages: Sendable {
  let operation: PommeSecurityWorkflowOperation
  let changePolicy: @Sendable (PommeGuestSecurityCredentials) async throws -> JSONValue
  let changeBootArguments: @Sendable () async throws -> JSONValue

  func mutate(credentials: PommeGuestSecurityCredentials) async throws -> JSONValue {
    guard !operation.isSIP else {
      throw PommeSecurityWorkflowError.statusUnverified
    }
    let final: JSONValue
    if operation.requestsDisabled {
      let policy = try await changePolicy(credentials)
      try requireVerified(policy)
      final = try await changeBootArguments()
    } else {
      let nvram = try await changeBootArguments()
      try requireVerified(nvram)
      final = try await changePolicy(credentials)
    }
    try requireVerified(final)
    guard final.objectValue?["amfiDisabled"] == .bool(operation.requestsDisabled) else {
      throw PommeSecurityWorkflowError.statusUnverified
    }
    return final
  }

  private func requireVerified(_ value: JSONValue) throws {
    guard value.objectValue?["verified"] == .bool(true) else {
      throw PommeSecurityWorkflowError.statusUnverified
    }
  }
}
