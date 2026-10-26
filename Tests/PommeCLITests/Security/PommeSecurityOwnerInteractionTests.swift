import Foundation
import Testing

@Suite("Security owner interaction")
struct PommeSecurityOwnerInteractionTests {
  @Test func unattendedExistingOwnerIsUnavailable() {
    let interaction = PommeSecurityOwnerInteraction(isInteractive: { false })
    #expect(throws: PommeSecurityWorkflowError.ownerUnavailable()) {
      try interaction.existingOwner(vmName: "existing")
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
