import Foundation

/// Status is evidence about configuration. In particular, an AMFI boot argument
/// alone does not prove that the running kernel has disabled enforcement.
struct PommeSecurityWorkflowState: Equatable, Sendable {
  let disabled: Bool
  let baselinePresent: Bool
  let reconciliationRequired: Bool
  let baselinePhase: String?

  static func decode(_ value: JSONValue, sip: Bool) throws -> Self {
    guard let object = value.objectValue,
      object["verified"] == .bool(true)
    else {
      throw PommeSecurityWorkflowError.statusUnverified
    }
    let disabled: Bool
    if sip {
      guard case .bool(let off)? = object["sipDisabled"],
        object["sipEnabled"] == .bool(!off)
      else {
        throw PommeSecurityWorkflowError.statusUnverified
      }
      disabled = off
    } else {
      guard case .bool(let off)? = object["amfiDisabled"],
        case .bool(let argument)? = object["amfiBootArgActive"],
        case .bool(let policy)? = object["bootPolicyAllowsCustomBootArgs"],
        case .bool = object["baselinePresent"],
        case .bool = object["reconciliationRequired"]
      else {
        throw PommeSecurityWorkflowError.statusUnverified
      }
      guard off == (argument && policy),
        object["reconciliationRequired"] != .bool(true) || object["baselinePresent"] == .bool(true)
      else {
        throw PommeSecurityWorkflowError.statusUnverified
      }
      let baseline = object["baselinePresent"] == .bool(true)
      let reconciliation = object["reconciliationRequired"] == .bool(true)
      guard let phase = object["baselinePhase"]?.stringValue else {
        throw PommeSecurityWorkflowError.statusUnverified
      }
      if baseline {
        guard let phase = PommeGuestAMFITransactionPhase(rawValue: phase),
          !phase.reconciliationRequired || reconciliation
        else {
          throw PommeSecurityWorkflowError.statusUnverified
        }
      } else if phase != "none" || reconciliation {
        throw PommeSecurityWorkflowError.statusUnverified
      }
      disabled = off
    }
    do {
      for key in ["baselinePresent", "reconciliationRequired"] where object[key] != nil {
        guard case .bool = object[key] else { throw PommeSecurityWorkflowError.statusUnverified }
      }
    }
    return .init(
      disabled: disabled,
      baselinePresent: object["baselinePresent"] == .bool(true),
      reconciliationRequired: object["reconciliationRequired"] == .bool(true),
      baselinePhase: object["baselinePhase"]?.stringValue)
  }
}

enum PommeSecurityWorkflowError: Error, LocalizedError, Equatable, Sendable {
  case statusUnverified
  case ownerUnavailable
  case confirmationRequired
  case confirmationDeclined
  case agentUnverified
  case commandIncomplete
  case privateInputUnsupported
  case ownerLoginUnverified
  case normalBootUnverified
  case restorationIncomplete
  case incompleteTransaction
  case missingBaseline
  case amfiRequiresSIPDisabled

  var errorDescription: String? {
    switch self {
    case .statusUnverified: "The VM security state could not be verified."
    case .ownerUnavailable:
      "Owner credentials are required. Set both POMME_AUTHORIZED_USER and POMME_AUTHORIZED_PASSWORD, restore the exact VM-scoped Keychain item, or run from an interactive terminal."
    case .confirmationRequired:
      "Creating the owner account on this verified fresh VM requires confirmation. Run from an interactive terminal or pass -f/--force."
    case .confirmationDeclined: "Owner account creation was declined; security is unchanged."
    case .agentUnverified:
      "The existing persistent Pomme agent could not be authenticated with its creation-pinned identity."
    case .commandIncomplete:
      "A guest command did not finish cleanly: it timed out, was cancelled, or its output was incomplete or truncated."
    case .privateInputUnsupported:
      "This VM's pinned agent does not support verified private password input. Owner preparation is unavailable; the agent and creation record were retained. Create a VM with this Pomme build to use this workflow."
    case .ownerLoginUnverified:
      "Automatic login as the verified owner could not be confirmed after a normal boot. Security is unchanged; the account, credentials, and progress were retained."
    case .normalBootUnverified:
      "The requested security configuration could not be verified after a normal boot; progress was retained."
    case .restorationIncomplete:
      "VM state restoration is incomplete. The account, credentials, and security journal were retained; repeat the same command after inspecting the VM."
    case .incompleteTransaction:
      "A security transaction remains unresolved; repeat its original command before starting another operation."
    case .amfiRequiresSIPDisabled:
      "AMFI changes require SIP disabled while boot arguments are written and verified. Run pomme sip disable <vm> first; restore AMFI before re-enabling SIP."
    case .missingBaseline:
      "AMFI enable requires the exact recorded baseline. No guessed LocalPolicy reset was attempted."
    }
  }
}
