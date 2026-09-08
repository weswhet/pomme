import Foundation
import Testing

@Suite("Retained security workflow resume guidance")
struct PommeSecurityWorkflowResumeGuidanceTests {
  @Test("Resume commands preserve the operation and final state")
  func commandPreservesRequest() throws {
    let journal = try makeJournal(
      operation: .sipDisable, finalState: .stopped)

    #expect(
      PommeSecurityWorkflowResumeGuidance.command(for: journal)
        == "pomme sip disable 'security-vm' --final-state stopped"
    )
    #expect(
      PommeSecurityWorkflowResumeGuidance.command(
        operation: .amfiEnable, vmName: "vm'quoted", finalState: .previous
      ) == "pomme amfi enable 'vm'\"'\"'quoted' --final-state previous"
    )
  }

  @Test("A diagnostic retains the primary error and adds only safe retry guidance")
  func diagnosticPreservesFailure() throws {
    let journal = try makeJournal(
      operation: .amfiDisable, finalState: .normal)
    let diagnostic = PommeSecurityWorkflowResumeGuidance.diagnostic(
      for: PommeSecurityWorkflowJournalError.conflictingOperation,
      journal: journal
    )

    let description = try #require(diagnostic.errorDescription)
    #expect(description.hasPrefix("Another unfinished Pomme security operation owns this VM."))
    #expect(description.contains("pomme amfi disable 'security-vm' --final-state normal"))
    #expect(description.contains("resolving any reported cleanup or restoration failure"))
    #expect(!description.contains("password"))
    #expect(!description.contains("SecurityWorkflowJournal.json"))
  }

  @Test("Restoration barriers keep their warning without a retry command")
  func restorationBarriersRemainUnwrapped() throws {
    let journal = try makeJournal(
      operation: .sipDisable, finalState: .stopped)
    let errors: [any Error] = [
      PommeSecurityWorkflowError.restorationIncomplete,
      PommeRecoverySessionError.cleanupFailed,
      PommeLiveRecoveryIntegration.Error.cleanupFailed,
    ]

    for error in errors {
      let result = PommeSecurityWorkflowResumeGuidance.appendingGuidance(
        to: error, journal: journal)
      #expect(result.localizedDescription == error.localizedDescription)
      #expect(!result.localizedDescription.contains("pomme sip disable"))
    }
  }

  @Test("Only a matching nonterminal journal is eligible for guidance")
  func trustedJournalBoundary() throws {
    let fixture = try ResumeGuidanceFixture()
    defer { fixture.cleanup() }
    let lease = try VMBundleMutationLease.acquire(name: fixture.vmName)
    defer { lease.release() }
    let store = PommeSecurityWorkflowJournalStore(bundleURL: fixture.bundleURL)
    let identity = try fixture.identity()
    let pending = try store.begin(
      operation: .sipDisable,
      identity: identity,
      originalRunState: .stopped,
      requestedFinalState: .stopped,
      lease: lease
    )

    #expect(
      PommeSecurityWorkflowResumeGuidance.latestTrustedRetainedJournal(
        store: store, identity: identity, lease: lease
      ) == pending
    )

    let foreignIdentity = try fixture.identity(
      vmUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    )
    #expect(
      PommeSecurityWorkflowResumeGuidance.latestTrustedRetainedJournal(
        store: store, identity: foreignIdentity, lease: lease
      ) == nil
    )

    _ = try store.completeWithoutMutation(pending, lease: lease)
    #expect(
      PommeSecurityWorkflowResumeGuidance.latestTrustedRetainedJournal(
        store: store, identity: identity, lease: lease
      ) == nil
    )
  }

  private func makeJournal(
    operation: PommeSecurityWorkflowOperation,
    finalState: VMFinalState
  ) throws -> PommeSecurityWorkflowJournal {
    try PommeSecurityWorkflowJournal(
      generation: 1,
      identity: PommeSecurityWorkflowIdentity(
        vmName: "security-vm",
        vmUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        machineIdentifierSHA256: String(repeating: "a", count: 64),
        diskImageFileResourceID: "1:2",
        startupVolumeGroupUUID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
        immutableProvisioningPlanDigest: String(repeating: "b", count: 64)
      ),
      operation: operation,
      originalRunState: .stopped,
      requestedFinalState: finalState,
      credential: nil,
      phase: .credentialPending,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
  }
}

private struct ResumeGuidanceFixture {
  let bundleURL: URL
  let vmName: String

  init() throws {
    vmName = "resume-\(UUID().uuidString.prefix(12))"
    bundleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pomme-security-resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)
    guard chmod(bundleURL.path, 0o700) == 0 else { throw POSIXTestError() }
  }

  func identity(vmUUID: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!) throws
    -> PommeSecurityWorkflowIdentity
  {
    try PommeSecurityWorkflowIdentity(
      vmName: vmName,
      vmUUID: vmUUID,
      machineIdentifierSHA256: String(repeating: "a", count: 64),
      diskImageFileResourceID: "1:2",
      startupVolumeGroupUUID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
      volumeVUID: "vuid-1",
      immutableProvisioningPlanDigest: String(repeating: "b", count: 64)
    )
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: bundleURL)
  }
}

private struct POSIXTestError: Error {}
