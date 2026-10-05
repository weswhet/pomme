import Foundation
import Testing

@Suite("Security owner confirmation")
struct PommeSecurityOwnerInteractionTests {
  @Test func unattendedCreationRequiresForce() throws {
    let interaction = PommeSecurityOwnerInteraction(
      isInteractive: { false },
      confirm: { _ in
        Issue.record("Noninteractive confirmation was called")
        return false
      })
    #expect(throws: PommeSecurityWorkflowError.confirmationRequired) {
      try interaction.authorizeFreshOwner(vmName: "fresh", force: false)
    }
    #expect(PommeSecurityWorkflowError.confirmationRequired.errorDescription?
      .hasSuffix("Run from an interactive terminal or pass -f/--force.") == true)
    try interaction.authorizeFreshOwner(vmName: "fresh", force: true)
    #expect(throws: PommeSecurityWorkflowError.ownerUnavailable) {
      try interaction.existingOwner(vmName: "existing")
    }
  }

  @Test func confirmationMayBeDeclined() {
    let interaction = PommeSecurityOwnerInteraction(
      isInteractive: { true }, confirm: { _ in false })
    #expect(throws: PommeSecurityWorkflowError.confirmationDeclined) {
      try interaction.authorizeFreshOwner(vmName: "fresh", force: false)
    }
  }

  @Test func partialEnvironmentPairDoesNotFallBack() throws {
    #expect(try PommeSecurityOwnerInteraction.environmentOwner([:]) == nil)
    #expect(throws: (any Error).self) {
      try PommeSecurityOwnerInteraction.environmentOwner(["POMME_AUTHORIZED_USER": "alice"])
    }
    #expect(throws: (any Error).self) {
      try PommeSecurityOwnerInteraction.environmentOwner([
        "POMME_AUTHORIZED_PASSWORD": "private-fixture"
      ])
    }
    let credential = try PommeSecurityOwnerInteraction.environmentOwner([
      "POMME_AUTHORIZED_USER": "alice", "POMME_AUTHORIZED_PASSWORD": "private-fixture",
    ])
    #expect(credential?.username == "alice")
  }
}
