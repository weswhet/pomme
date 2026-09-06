import Foundation
import Testing

@Suite("State-aware security evidence")
struct PommeSecurityWorkflowStateTests {
  @Test func sipRequiresUnambiguousStatus() throws {
    let enabled = try PommeSecurityWorkflowState.decode(
      .object([
        "verified": .bool(true), "sipEnabled": .bool(true), "sipDisabled": .bool(false),
      ]), sip: true)
    #expect(!enabled.disabled)
    #expect(throws: PommeSecurityWorkflowError.statusUnverified) {
      try PommeSecurityWorkflowState.decode(
        .object([
          "verified": .bool(true), "sipEnabled": .bool(true), "sipDisabled": .bool(true),
        ]), sip: true)
    }
  }

  @Test func bootArgumentsAloneDoNotProveAMFIState() {
    #expect(throws: PommeSecurityWorkflowError.statusUnverified) {
      try PommeSecurityWorkflowState.decode(
        .object([
          "verified": .bool(true), "amfiBootArgActive": .bool(true),
        ]), sip: false)
    }
  }

  @Test func incompleteTransactionIsSeparateFromConfiguredState() throws {
    let state = try PommeSecurityWorkflowState.decode(
      .object([
        "verified": .bool(true), "amfiBootArgActive": .bool(true),
        "amfiDisabled": .bool(true), "bootPolicyAllowsCustomBootArgs": .bool(true),
        "baselinePresent": .bool(true), "reconciliationRequired": .bool(true),
        "baselinePhase": .string("policyApplying"),
      ]), sip: false)
    #expect(state.disabled)
    #expect(state.reconciliationRequired)
  }

  @Test("Receipt-backed AMFI phases decode as retained configuration evidence")
  func receiptBackedAMFIPhasesDecode() throws {
    for (phase, disabled) in [("disabledConfigured", true), ("enabledConfigured", false)] {
      let state = try PommeSecurityWorkflowState.decode(
        .object([
          "verified": .bool(true),
          "amfiBootArgActive": .bool(disabled),
          "amfiDisabled": .bool(disabled),
          "bootPolicyAllowsCustomBootArgs": .bool(true),
          "baselinePresent": .bool(true),
          "reconciliationRequired": .bool(true),
          "baselinePhase": .string(phase),
        ]), sip: false)

      #expect(state.disabled == disabled)
      #expect(state.baselinePresent)
      #expect(state.reconciliationRequired)
      #expect(state.baselinePhase == phase)
    }
  }
}
