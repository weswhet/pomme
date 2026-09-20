import Foundation
import Testing

struct PommeFrameworkOwnerWorkflowTests {
  @Test(arguments: ["password", "admin", "token", "apfs", "uid", "group", "autologin", "console", "desktop"])
  func missingProofNeverReachesRecovery(_ failure: String) async throws {
    let fixture = try FrameworkOwnerFixture()
    defer { fixture.cleanup() }
    let lease = try VMBundleMutationLease.acquire(name: fixture.identity.vmName)
    defer { lease.release() }
    let progress = try fixture.progress(lease: lease)
    let trace = FrameworkOwnerTrace()
    let preparation = fixture.preparation(trace: trace, failure: failure)
    do {
      _ = try await PommeSecurityWorkflow.run(
        progress: progress, dependencies: fixture.dependencies(preparation, trace: trace))
      Issue.record("Missing framework proof allowed a security transaction")
    } catch {
      #expect(error as? PommeSecurityOwnerPreparationError == .ownerVerificationFailed)
    }
    #expect(trace.events.contains("recovery") == false)
    #expect(progress.journal.owner?.ownerPreparation == .existing)
    #expect(progress.journal.phase == .credentialPending)
  }

  @Test(arguments: [PommeOwnerCredentialStoreError.keychainMissing,
                    .keychainLocked(status: -25308), .ownershipMismatch, .invalidReference])
  func exactCredentialFailureHasNoFallback(_ failure: PommeOwnerCredentialStoreError) async throws {
    let fixture = try FrameworkOwnerFixture()
    defer { fixture.cleanup() }
    let lease = try VMBundleMutationLease.acquire(name: fixture.identity.vmName)
    defer { lease.release() }
    let progress = try fixture.progress(lease: lease)
    let trace = FrameworkOwnerTrace()
    let preparation = fixture.preparation(trace: trace, credentialFailure: failure)
    do {
      _ = try await PommeSecurityWorkflow.run(
        progress: progress, dependencies: fixture.dependencies(preparation, trace: trace))
      Issue.record("Credential failure allowed a security transaction")
    } catch {
      #expect(error as? PommeOwnerCredentialStoreError == failure)
    }
    #expect(trace.events == ["read", "restore"])
    #expect(progress.journal.credential == fixture.credentialReference)
  }

  @Test func successUsesOneRecoveryAndNeverCreatesOrConfiguresOwner() async throws {
    let fixture = try FrameworkOwnerFixture()
    defer { fixture.cleanup() }
    let lease = try VMBundleMutationLease.acquire(name: fixture.identity.vmName)
    defer { lease.release() }
    let progress = try fixture.progress(lease: lease)
    let trace = FrameworkOwnerTrace()
    _ = try await PommeSecurityWorkflow.run(
      progress: progress,
      dependencies: fixture.dependencies(fixture.preparation(trace: trace), trace: trace))
    #expect(trace.events == ["read", "proof", "desktop", "recovery", "normal", "restore"])
    #expect(progress.journal.owner?.ownerPreparation == .existing)
    #expect(progress.journal.owner?.generatedUID == fixture.generatedUID)
    #expect(progress.journal.credential == fixture.credentialReference)
    #expect(progress.journal.phase == .restorationComplete)
    #expect(fixture.identity.volumeVUID == nil)
    #expect(progress.journal.identity.volumeVUID == fixture.rootVolumeUUID.uuidString.lowercased())
    let encoded = try JSONEncoder().encode(progress.journal)
    #expect(String(decoding: encoded, as: UTF8.self).contains("offline-framework-secret") == false)
  }

  @Test(arguments: [false, true])
  func noOpStillProvesFrameworkDesktopWithoutMutation(desktopFails: Bool) async throws {
    let fixture = try FrameworkOwnerFixture()
    defer { fixture.cleanup() }
    let lease = try VMBundleMutationLease.acquire(name: fixture.identity.vmName)
    defer { lease.release() }
    let progress = try fixture.progress(lease: lease)
    let trace = FrameworkOwnerTrace()
    let preparation = fixture.preparation(trace: trace, failure: desktopFails ? "desktop" : nil)
    do {
      _ = try await PommeSecurityWorkflow.run(
      progress: progress,
      dependencies: .init(
        observe: {
          _ = try await preparation.prepare(progress: progress, advance: false)
          return .init(disabled: true, baselinePresent: false,
                       reconciliationRequired: false, baselinePhase: nil)
        },
        prepareOwner: { try await preparation.prepare(progress: $0) },
        mutate: { _ in trace.record("recovery"); return .null },
        verifyNormalBoot: { trace.record("normal") },
        restore: { _ in trace.record("restore") }, log: { _ in }))
      #expect(desktopFails == false)
    } catch {
      #expect(desktopFails)
      #expect(error as? PommeSecurityOwnerPreparationError == .ownerVerificationFailed)
    }
    #expect(trace.events == ["read", "proof", "desktop", "restore"])
    #expect(progress.journal.noMutationNeeded == (desktopFails == false))
  }
}

private final class FrameworkOwnerTrace: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  var events: [String] { lock.withLock { values } }
  func record(_ event: String) { lock.withLock { values.append(event) } }
}

private struct FrameworkOwnerFixture: Sendable {
  let root: URL
  let identity: PommeSecurityWorkflowIdentity
  let generatedUID: UUID
  let rootVolumeUUID = UUID()
  let credentialReference: PommeOwnerCredentialReference

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-framework-owner-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    identity = try .init(
      vmName: "framework-owner-\(UUID().uuidString.lowercased())", vmUUID: UUID(),
      machineIdentifierSHA256: String(repeating: "a", count: 64),
      diskImageFileResourceID: "1:2", startupVolumeGroupUUID: UUID(), volumeVUID: nil,
      immutableProvisioningPlanDigest: String(repeating: "b", count: 64))
    generatedUID = UUID()
    credentialReference = try PommeOwnerCredentialReference(identity: identity, account: "pomme")
      .bindingGeneratedUID(generatedUID)
  }

  func progress(lease: VMBundleMutationLease) throws -> PommeSecurityWorkflowProgress {
    let store = PommeSecurityWorkflowJournalStore(bundleURL: root)
    let journal = try store.begin(operation: .sipDisable, identity: identity,
                                  originalRunState: .stopped, requestedFinalState: .stopped, lease: lease)
    return .init(journal, store: store, lease: lease)
  }

  func preparation(
    trace: FrameworkOwnerTrace, failure: String? = nil,
    credentialFailure: PommeOwnerCredentialStoreError? = nil
  ) -> PommeSecurityFrameworkOwnerPreparation {
    .init(
      credentialReference: credentialReference, generatedUID: generatedUID,
      startupVolumeGroupUUID: identity.startupVolumeGroupUUID,
      readCredential: { reference in
        trace.record("read")
        #expect(reference == credentialReference)
        if let credentialFailure { throw credentialFailure }
        return .init(reference: reference, password: "offline-framework-secret")
      },
      verifyOwner: { password, expectedUID in
        trace.record("proof")
        #expect(password == "offline-framework-secret")
        #expect(expectedUID == generatedUID)
        return .init(
          owner: .init(username: "pomme", generatedUID: failure == "uid" ? UUID() : generatedUID,
                       uniqueID: 501, passwordVerified: failure != "password",
                       isAdministrator: failure != "admin", secureTokenEnabled: failure != "token",
                       isAPFSVolumeOwner: failure != "apfs",
                       startupVolumeGroupUUID: failure == "group" ? UUID() : identity.startupVolumeGroupUUID),
          startupRootVolumeUUID: rootVolumeUUID,
          automaticLoginVerified: failure != "autologin", consoleUserVerified: failure != "console")
      },
      verifyDesktop: { username, uid in
        trace.record("desktop")
        #expect(username == "pomme")
        #expect(uid == 501)
        if failure == "desktop" { throw PommeSecurityOwnerPreparationError.ownerVerificationFailed }
      })
  }

  func dependencies(_ preparation: PommeSecurityFrameworkOwnerPreparation, trace: FrameworkOwnerTrace)
    -> PommeSecurityWorkflowDependencies
  {
    .init(
      observe: { .init(disabled: false, baselinePresent: false,
                       reconciliationRequired: false, baselinePhase: nil) },
      prepareOwner: { progress in
        let credentials = try await preparation.prepare(progress: progress)
        #expect(progress.journal.identity.volumeVUID == rootVolumeUUID.uuidString.lowercased())
        #expect(progress.journal.phase == .accountCreationVerified)
        return credentials
      },
      mutate: { credentials in
        trace.record("recovery")
        #expect(credentials.username == "pomme")
        return .object(["verified": .bool(true), "sipDisabled": .bool(true)])
      },
      verifyNormalBoot: { trace.record("normal") },
      restore: { _ in trace.record("restore") }, log: { _ in })
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
