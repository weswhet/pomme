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

enum PommeSecurityWorkflowError: PommeDescribedError, Equatable, Sendable {
  case statusUnverified
  case ownerUnavailable(PommeRetainedCause = .init())
  case agentUnverified
  case commandIncomplete
  case privateInputUnsupported
  case ownerLoginUnverified
  case normalBootUnverified
  case restorationIncomplete(PommeRetainedCause = .init())
  case incompleteTransaction
  case missingBaseline
  case amfiRequiresSIPDisabled

  var code: PommeErrorCode {
    switch self {
    case .statusUnverified: .securityStatusUnverified
    case .ownerUnavailable: .credentialUnavailable
    case .agentUnverified: .securityAgentUnverified
    case .commandIncomplete: .securityCommandIncomplete
    case .privateInputUnsupported: .securityAgentUnsupported
    case .ownerLoginUnverified: .securityOwnerLoginUnverified
    case .normalBootUnverified: .securityChangeUnverified
    case .restorationIncomplete: .securityRestorationIncomplete
    case .incompleteTransaction: .securityOperationPending
    case .missingBaseline: .amfiBaselineMissing
    case .amfiRequiresSIPDisabled: .amfiRequiresSIPDisabled
    }
  }

  /// A restoration failure caused by `error`, or `error` itself when it
  /// already is one.
  static func restorationIncomplete(after error: any Error) -> Self {
    if let workflow = error as? Self, case .restorationIncomplete = workflow { return workflow }
    return .restorationIncomplete(PommeRetainedCause(error))
  }

  var underlying: (any Error)? {
    switch self {
    case .ownerUnavailable(let cause), .restorationIncomplete(let cause): cause.underlying
    default: nil
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .statusUnverified: "Run `pomme agent status NAME` to check that the guest agent is connected, then retry."
    case .agentUnverified: "Run `pomme agent status NAME`. If the agent is damaged, run `pomme agent repair NAME`."
    case .privateInputUnsupported: "Run `pomme agent update NAME` to install the current agent, then retry."
    case .commandIncomplete, .ownerLoginUnverified, .normalBootUnverified:
      "Repeat the same command with the same `--final-state` value to resume."
    case .missingBaseline: "Run `pomme amfi status NAME` to see the VM's AMFI state."
    default: nil
    }
  }

  var errorDescription: String? {
    switch self {
    case .statusUnverified: "Pomme couldn't verify the VM's SIP or AMFI state from the guest's reply."
    case .ownerUnavailable(let cause):
      cause.describing(
        "Owner credentials are required.",
        then: "Set both POMME_AUTHORIZED_USER and POMME_AUTHORIZED_PASSWORD, restore the exact VM-scoped Keychain item, or run from an interactive terminal.")
    case .agentUnverified:
      "Pomme couldn't authenticate the VM's guest agent with the identity that it recorded when it created the VM."
    case .commandIncomplete:
      "A guest command didn't finish cleanly: it timed out, was cancelled, or its output was incomplete. Pomme kept the operation's progress."
    case .privateInputUnsupported:
      "The VM's guest agent can't pass the owner's credential to guest commands privately, so Pomme can't prepare the owner account. Pomme didn't change the agent."
    case .ownerLoginUnverified:
      "Pomme couldn't confirm that the owner signed in automatically after a normal boot. Security is unchanged; Pomme kept the account, its credential, and the operation's progress."
    case .normalBootUnverified:
      "Pomme couldn't verify the requested SIP or AMFI setting after a normal boot. Pomme kept the operation's progress."
    case .restorationIncomplete(let cause):
      cause.describing(
        "VM state restoration is incomplete.",
        then: "The account, credentials, and security journal were retained; repeat the same command after inspecting the VM.")
    case .incompleteTransaction:
      "An earlier SIP or AMFI operation on this VM is unfinished. Repeat its original command before you start another operation."
    case .amfiRequiresSIPDisabled:
      "Changing AMFI requires SIP to be off while Pomme writes and verifies boot arguments. Run `pomme sip disable NAME` first, and restore AMFI before you turn SIP on again."
    case .missingBaseline:
      "Pomme has no recorded AMFI baseline for this VM, so it can't restore AMFI. Pomme didn't change the boot policy."
    }
  }
}
