import Foundation
import os

extension PommeSecurityWorkflowOperation {
  var isSIP: Bool { self == .sipEnable || self == .sipDisable }
  var requestsDisabled: Bool { self == .sipDisable || self == .amfiDisable }
  var recoveryOperation: PommeRecoveryOperation {
    switch self {
    case .sipEnable: .sip(.enable)
    case .sipDisable: .sip(.disable)
    case .amfiEnable: .amfi(.enable)
    case .amfiDisable: .amfi(.disable)
    }
  }
  var statusOperation: PommeRecoveryOperation { isSIP ? .sip(.status) : .amfi(.status) }
}

/// SIP and AMFI policy writes use request-bound authenticated Recovery. Individual
/// sessions finish stopped; the outer durable workflow owns final restoration.
struct PommeSecurityRecoveryAdapter: Sendable {
  let reference: VMReference
  let volumeGroupUUID: UUID
  let factory: PommeRecoveryIntegrationFactory

  func observe(_ operation: PommeSecurityWorkflowOperation) async throws
    -> PommeSecurityWorkflowState
  {
    let payload: JSONValue =
      operation.isSIP
      ? .object([:])
      : .object([
        "volumeGroupUUID": .string(volumeGroupUUID.uuidString.lowercased()),
        "includeWorkflowState": .bool(true),
      ])
    let value = try await execute(operation.statusOperation, payload: payload)
    return try PommeSecurityWorkflowState.decode(value, sip: operation.isSIP)
  }

  func mutate(
    _ operation: PommeSecurityWorkflowOperation, credentials: PommeGuestSecurityCredentials
  ) async throws -> JSONValue {
    var payload: [String: JSONValue] = [
      "authorizedUser": .string(credentials.username), "password": .string(credentials.password),
    ]
    payload["volumeGroupUUID"] = .string(volumeGroupUUID.uuidString.lowercased())
    if !operation.isSIP { payload["stage"] = .string("policy") }
    return try await execute(operation.recoveryOperation, payload: .object(payload))
  }

  private func execute(_ operation: PommeRecoveryOperation, payload: JSONValue) async throws
    -> JSONValue
  {
    // The payload can hold the owner's credentials, so only the operation
    // is logged.
    PommeUnifiedLog.security.notice(
      "[\(reference.displayName, privacy: .public)] running \(operation.wireName, privacy: .public) in authenticated Recovery")
    let integration = try await factory.make(reference: reference, operation: operation)
    let execution = try await integration.adapter.execute(
      operation: operation, payload: PommeProvisioningCoding.encode(payload), finalState: .stopped
    )
    guard execution.evidence.authenticated, execution.evidence.requestBound,
      execution.evidence.credentialConsumed, execution.evidence.lifecycle == .finalized,
      execution.cleanup.isComplete, execution.finalState == .stopped
    else {
      PommeUnifiedLog.security.error("""
        [\(reference.displayName, privacy: .public)] Recovery \(operation.wireName, privacy: .public) evidence rejected: \
        authenticated=\(execution.evidence.authenticated, privacy: .public) \
        requestBound=\(execution.evidence.requestBound, privacy: .public) \
        credentialConsumed=\(execution.evidence.credentialConsumed, privacy: .public) \
        lifecycle=\(execution.evidence.lifecycle.rawValue, privacy: .public) \
        cleanupComplete=\(execution.cleanup.isComplete, privacy: .public) \
        finalState=\(execution.finalState.rawValue, privacy: .public)
        """)
      throw PommeSecurityWorkflowError.restorationIncomplete()
    }
    let value = try JSONDecoder().decode(JSONValue.self, from: execution.output)
    guard value.objectValue?["verified"] == .bool(true),
      value.objectValue?["operation"] == .string(operation.wireName)
    else {
      throw PommeSecurityWorkflowError.statusUnverified
    }
    return value
  }
}
