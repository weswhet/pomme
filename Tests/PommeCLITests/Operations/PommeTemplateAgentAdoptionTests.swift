import Foundation
import Security
import Testing

@Suite("Template agent adoption", .serialized)
struct PommeTemplateAgentAdoptionTests {
    private let digest = String(repeating: "d", count: 64)
    private let templateDigest = String(repeating: "e", count: 64)
    private let group = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func reference(credentialID: UUID = UUID(), digest: String? = nil) -> PommeTemplateAgentReference {
        .init(credentialID: credentialID, executableDigest: digest ?? templateDigest, startupVolumeGroupUUID: group)
    }

    private func manifest(owner: String?, retainedAgent: PommeTemplateAgentReference?) -> PommeTemplateManifest {
        .init(
            name: "mdm-ready", version: "26.6.2", build: "25G83",
            restoreImageDigest: String(repeating: "a", count: 64),
            restoreImagePath: "/images/UniversalMac.ipsw",
            diskSizeBytes: 40 << 30,
            provisionedOwnerAccount: owner,
            provisionedSecurityDisabled: owner == nil ? nil : true,
            retainedAgent: retainedAgent
        )
    }

    private func plan() throws -> PommeProvisioningPlan {
        try .init(
            vm: .init(name: "clone", uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
                      bundlePath: "/tmp/clone.macvm"),
            restore: .init(version: "26.6.0", build: "25G72", restoreImageDigest: digest),
            display: .required,
            profile: .tahoe,
            normalAgent: try .init(identifier: "com.github.weswhet.pomme.agent", executableDigest: digest, role: .normal),
            recoveryAgent: try .init(identifier: "com.github.weswhet.pomme.recovery", executableDigest: digest, role: .recovery),
            finalState: .stopped
        )
    }

    // MARK: Manifest

    @Test("A provisioned manifest that kept its agent credential validates and offers the agent")
    func retainedAgentManifest() throws {
        let kept = manifest(owner: "pomme", retainedAgent: reference())
        try kept.validate()
        #expect(kept.adoptableAgent == kept.retainedAgent)

        let legacy = manifest(owner: "pomme", retainedAgent: nil)
        try legacy.validate()
        #expect(legacy.adoptableAgent == nil)
    }

    @Test("A kept agent requires a provisioned owner and a lowercase SHA-256 digest")
    func retainedAgentValidation() {
        #expect(throws: PommeTemplateError.invalidManifest) {
            try manifest(owner: nil, retainedAgent: reference()).validate()
        }
        for bad in ["nope", String(repeating: "A", count: 64)] {
            #expect(throws: PommeTemplateError.invalidManifest) {
                try manifest(owner: "pomme", retainedAgent: reference(digest: bad)).validate()
            }
        }
    }

    @Test("The kept agent round-trips through the store encoding, and older manifests decode without one")
    func retainedAgentEncoding() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let kept = manifest(owner: "pomme", retainedAgent: reference())
        let decoded = try decoder.decode(PommeTemplateManifest.self, from: encoder.encode(kept))
        #expect(decoded.retainedAgent == kept.retainedAgent)

        let legacy = """
        {"schema":1,"name":"mdm-ready","version":"26.6.2","build":"25G83",
         "restoreImageDigest":"\(String(repeating: "a", count: 64))","restoreImagePath":"/images/UniversalMac.ipsw",
         "diskSizeBytes":42949672960,"createdAt":"2026-09-13T12:00:00Z",
         "provisionedOwnerAccount":"pomme","provisionedSecurityDisabled":true}
        """
        let old = try decoder.decode(PommeTemplateManifest.self, from: Data(legacy.utf8))
        try old.validate()
        #expect(old.isProvisioned)
        #expect(old.adoptableAgent == nil)
    }

    // MARK: Capture

    @Test("The capture copies the credential under the reference's own identifier")
    func captureRetainsCredential() throws {
        let id = UUID()
        var copied: [UUID] = []
        var warnings: [String] = []
        let kept = PommeProvisionedTemplate.retainAgent(
            credentialID: id,
            executableDigest: { templateDigest },
            startupVolumeGroup: { group },
            copyCredential: { copied.append($0) },
            warn: { warnings.append($0) }
        )
        #expect(kept == .init(credentialID: id, executableDigest: templateDigest, startupVolumeGroupUUID: group))
        #expect(copied == [id])
        #expect(warnings.isEmpty)
    }

    @Test("A capture that can't keep the credential warns and creates a template without one",
          arguments: ["group", "digest", "copy"])
    func captureDegradesToRecovery(failure: String) {
        var copied: [UUID] = []
        var warnings: [String] = []
        let kept = PommeProvisionedTemplate.retainAgent(
            executableDigest: { failure == "digest" ? "not-a-digest" : templateDigest },
            startupVolumeGroup: { failure == "group" ? nil : group },
            copyCredential: { id in
                if failure == "copy" { throw PommeAgentCredentialStore.Error.keychainLocked(status: errSecInteractionNotAllowed) }
                copied.append(id)
            },
            warn: { warnings.append($0) }
        )
        #expect(kept == nil)
        #expect(copied.isEmpty)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("through Recovery") == true)
    }

    // MARK: Keychain

    @Test("The template credential has its own account, is kept without replacement, and is removed exactly")
    func templateCredentialStore() throws {
        let fixture = try AdoptionTemporaryKeychain()
        defer { fixture.cleanup() }
        let agentStore = PommeAgentCredentialStore(keychainPath: fixture.path)
        let store = PommeTemplateAgentCredentialStore(store: agentStore)
        let id = UUID()
        let secret = String(repeating: "1", count: 64)
        let vmSecret = String(repeating: "2", count: 64)

        // A VM item that happened to share the identifier is a different item.
        _ = try agentStore.readOrCreate(vmUUID: id, account: "agent-token") { vmSecret }
        try store.retain(secret, credentialID: id)
        try store.retain(secret.uppercased(), credentialID: id)
        #expect(try store.read(credentialID: id) == secret)
        #expect(throws: PommeAgentCredentialStore.Error.unexpectedCredentialData) {
            try store.retain(String(repeating: "3", count: 64), credentialID: id)
        }
        #expect(try store.read(credentialID: id) == secret)
        #expect(throws: PommeAgentCredentialStore.Error.malformedCredential) {
            try store.retain("short", credentialID: UUID())
        }

        try store.remove(credentialID: id)
        try store.remove(credentialID: id)
        #expect(throws: PommeAgentCredentialStore.Error.credentialMissing(status: errSecItemNotFound)) {
            try store.read(credentialID: id)
        }
        #expect(try agentStore.read(vmUUID: id, account: "agent-token") == vmSecret)
    }

    @Test("Deleting a template deletes the credential it kept, then the bundle")
    func deleteRemovesCredential() throws {
        let fixture = try AdoptionTemporaryKeychain()
        defer { fixture.cleanup() }
        let store = PommeTemplateAgentCredentialStore(store: PommeAgentCredentialStore(keychainPath: fixture.path))
        let kept = reference()
        try store.retain(String(repeating: "4", count: 64), credentialID: kept.credentialID)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-template-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = BundleLayout(rootURL: root)
        try PommeTemplateStore.write(manifest(owner: "pomme", retainedAgent: kept), to: bundle)

        try PommeTemplateStore.delete(bundle: bundle, credentials: store)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(throws: PommeAgentCredentialStore.Error.credentialMissing(status: errSecItemNotFound)) {
            try store.read(credentialID: kept.credentialID)
        }
    }

    @Test("Deleting removes a pending capture's credential and fails closed on an unreadable manifest")
    func deleteFindsPendingAndFailsClosed() throws {
        let fixture = try AdoptionTemporaryKeychain()
        defer { fixture.cleanup() }
        let store = PommeTemplateAgentCredentialStore(store: PommeAgentCredentialStore(keychainPath: fixture.path))

        // A capture interrupted after the copy and before the manifest.
        let pendingID = UUID()
        let pending = try temporaryBundle()
        defer { try? FileManager.default.removeItem(at: pending.rootURL) }
        try PommeTemplateStore.markPendingCredential(pendingID, in: pending)
        try store.retain(String(repeating: "7", count: 64), credentialID: pendingID)
        try PommeTemplateStore.delete(bundle: pending, credentials: store)
        #expect(!FileManager.default.fileExists(atPath: pending.rootURL.path))
        #expect(throws: PommeAgentCredentialStore.Error.credentialMissing(status: errSecItemNotFound)) {
            try store.read(credentialID: pendingID)
        }

        // A manifest that exists but can't be read keeps both bundle and item.
        let keptID = UUID()
        let corrupt = try temporaryBundle()
        defer { try? FileManager.default.removeItem(at: corrupt.rootURL) }
        try store.retain(String(repeating: "8", count: 64), credentialID: keptID)
        try Data("{not json".utf8).write(to: PommeTemplateStore.manifestURL(for: corrupt))
        #expect(throws: PommeTemplateError.credentialUnresolved(corrupt.rootURL.path)) {
            try PommeTemplateStore.delete(bundle: corrupt, credentials: store)
        }
        #expect(FileManager.default.fileExists(atPath: corrupt.rootURL.path))
        #expect(try store.read(credentialID: keptID) == String(repeating: "8", count: 64))
        try store.remove(credentialID: keptID)
    }

    @Test("A failed capture warns and keeps the bundle when its credential can't be removed")
    func discardBundleWarnsOnFailure() throws {
        let fixture = try AdoptionTemporaryKeychain()
        defer { fixture.cleanup() }
        let store = PommeTemplateAgentCredentialStore(store: PommeAgentCredentialStore(keychainPath: fixture.path))
        let bundle = try temporaryBundle()
        defer { try? FileManager.default.removeItem(at: bundle.rootURL) }
        let id = UUID()
        try PommeTemplateStore.markPendingCredential(id, in: bundle)
        try store.retain(String(repeating: "9", count: 64), credentialID: id)
        try fixture.lock()
        var warnings: [String] = []
        #expect(!PommeProvisionedTemplate.discardBundle(bundle, templateName: "mdm-ready", credentials: store) {
            warnings.append($0)
        })
        #expect(warnings.count == 1)
        #expect(FileManager.default.fileExists(atPath: bundle.rootURL.path))
        try fixture.unlock()
        #expect(PommeProvisionedTemplate.discardBundle(bundle, templateName: "mdm-ready", credentials: store) { _ in })
        #expect(!FileManager.default.fileExists(atPath: bundle.rootURL.path))
    }

    @Test("A capture records the pending credential before copying it, and copies nothing when it can't")
    func captureMarksPendingFirst() {
        let order = Recorder()
        _ = PommeProvisionedTemplate.retainAgent(
            executableDigest: { templateDigest }, startupVolumeGroup: { group },
            markPending: { _ in order.add("mark") }, copyCredential: { _ in order.add("copy") }, warn: { _ in })
        #expect(order.events == ["mark", "copy"])

        let failed = Recorder()
        let kept = PommeProvisionedTemplate.retainAgent(
            executableDigest: { templateDigest }, startupVolumeGroup: { group },
            markPending: { _ in throw CocoaError(.fileWriteNoPermission) },
            copyCredential: { _ in failed.add("copy") }, warn: { _ in failed.add("warn") })
        #expect(kept == nil)
        #expect(failed.events == ["warn"])
    }

    // MARK: Adoption and probe ordering

    private func adoptionRun(
        _ events: Recorder, credentialExists: Bool = true, leasePresent: Bool = true,
        installFails: Bool = false, shutDownFails: Bool = false
    ) -> PommeTemplateAdoptionRun {
        .init(
            credentialExists: { credentialExists },
            withdrawLease: { events.add("withdraw"); return leasePresent },
            stopHelper: { events.add("stop") },
            prepare: { events.add("prepare") },
            writeLease: { events.add("lease") },
            install: {
                events.add("install")
                if installFails { throw PommeTemplateAgentAdoptionError.unexpectedAgent(vmName: "clone") }
            },
            recordInstalled: { events.add("record") },
            shutDown: {
                events.add("shutdown")
                if shutDownFails { throw RunnerError.virtualMachineState("stop failed") }
            },
            receipt: { events.add("receipt"); return String(repeating: "a", count: 64) },
            warn: { _ in events.add("warn") }
        )
    }

    @Test("A successful adoption withdraws the lease before it shuts the guest down")
    func adoptionSuccessOrdering() async throws {
        let events = Recorder()
        #expect(try await adoptionRun(events).run() != nil)
        #expect(events.events == ["prepare", "lease", "install", "withdraw", "record", "shutdown", "receipt"])
    }

    @Test("A failed adoption step removes the lease and stops the helper before it rethrows")
    func adoptionFailureCleansUp() async {
        let events = Recorder()
        await #expect(throws: PommeTemplateAgentAdoptionError.unexpectedAgent(vmName: "clone")) {
            _ = try await adoptionRun(events, installFails: true).run()
        }
        #expect(events.events == ["prepare", "lease", "install", "withdraw", "stop"])
    }

    @Test("A failed shutdown after the lease is withdrawn still stops the helper")
    func adoptionShutdownFailureStopsHelper() async {
        let events = Recorder()
        await #expect(throws: RunnerError.self) {
            _ = try await adoptionRun(events, shutDownFails: true).run()
        }
        #expect(events.events == ["prepare", "lease", "install", "withdraw", "record", "shutdown", "stop"])
    }

    @Test("Without the template's credential, a leftover lease is withdrawn and its helper stopped")
    func adoptionMissingCredentialStopsLeasedHelper() async throws {
        let leased = Recorder()
        #expect(try await adoptionRun(leased, credentialExists: false).run() == nil)
        #expect(leased.events == ["withdraw", "stop", "warn"])

        let clean = Recorder()
        #expect(try await adoptionRun(clean, credentialExists: false, leasePresent: false).run() == nil)
        #expect(clean.events == ["withdraw", "warn"])
    }

    private func probe(_ events: Recorder, proves: Bool, proveThrows: Bool = false) -> PommeInstalledAgentProbe {
        .init(
            withdrawLease: { events.add("withdraw"); return false },
            stopHelper: { events.add("stop") },
            prove: {
                events.add("prove")
                if proveThrows { throw RunnerError.guestAgentUnavailable }
                return proves
            },
            recordVolumeGroup: { events.add("group") },
            markProbed: { events.add("probed") },
            receipt: { String(repeating: "b", count: 64) },
            log: { _ in }
        )
    }

    @Test("The probe always stops the helper before proving, so a leased session can't prove the agent")
    func probeStartsFromStoppedHelper() async throws {
        let proven = Recorder()
        #expect(try await probe(proven, proves: true).run() != nil)
        #expect(proven.events == ["withdraw", "stop", "prove", "group"])

        let unproven = Recorder()
        #expect(try await probe(unproven, proves: false).run() == nil)
        #expect(unproven.events == ["withdraw", "stop", "prove", "probed", "stop"])

        let failed = Recorder()
        #expect(try await probe(failed, proves: false, proveThrows: true).run() == nil)
        #expect(failed.events == ["withdraw", "stop", "prove", "probed", "stop"])
    }

    private func temporaryBundle() throws -> BundleLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-template-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return BundleLayout(rootURL: root)
    }

    // MARK: Install evidence, lease, and credential rotation

    @Test("Install evidence binds to the exact plan and is probed once per dispatch")
    func dispatchEvidence() throws {
        let plan = try plan()
        let first = PommeAgentInstallDispatch(vmUUID: plan.vm.uuid, planDigest: plan.digest, method: .recovery, attempt: 1)
        #expect(first.matches(plan))
        #expect(first.awaitsProbe)
        #expect(!PommeAgentInstallDispatch(vmUUID: UUID(), planDigest: plan.digest, method: .recovery, attempt: 1).matches(plan))
        #expect(!PommeAgentInstallDispatch(vmUUID: plan.vm.uuid, planDigest: digest, method: .recovery, attempt: 1).matches(plan))

        let probed = first.probed()
        #expect(!probed.awaitsProbe)
        let redispatched = probed.dispatched(method: .template, attempt: 2)
        #expect(redispatched.awaitsProbe)
        #expect(redispatched.method == .template)
        #expect(redispatched.probedAttempt == 1)
        let decoded = try JSONDecoder().decode(
            PommeAgentInstallDispatch.self, from: PommeProvisioningCoding.encode(redispatched))
        #expect(decoded == redispatched)
    }

    @Test("The adoption lease admits only its own plan and template credential")
    func adoptionLease() throws {
        let plan = try plan()
        let template = reference()
        let lease = PommeTemplateAdoptionLease(vmUUID: plan.vm.uuid, planDigest: plan.digest, credentialID: template.credentialID)
        #expect(lease.matches(plan, template: template))
        #expect(!lease.matches(plan, template: reference()))
        #expect(!PommeTemplateAdoptionLease(vmUUID: UUID(), planDigest: plan.digest, credentialID: template.credentialID)
            .matches(plan, template: template))
    }

    @Test("Candidate credentials alternate, one per authentication attempt")
    func credentialRotation() {
        let rotation = PommeAgentCredentialRotation()
        let own = String(repeating: "5", count: 64)
        let template = String(repeating: "6", count: 64)
        #expect(rotation.next([]) == nil)
        let offered = (0..<5).compactMap { _ in rotation.next([own, template]) }
        #expect(Set(offered.prefix(2)) == [own, template])
        #expect(offered[0] != offered[1] && offered[1] != offered[2])
        #expect(rotation.next([own]) == own)
    }

    // MARK: Pure checks

    @Test("The adoption accepts the template's or the plan's build only with upload and process support")
    func acceptedAgents() throws {
        let plan = try plan()
        let template = reference()
        let capabilities = ["file.open", "file.write", "file.commit", "process.start", "agent.describe"]
        #expect(PommeTemplateAgentAdoption.accepts(digest: templateDigest, capabilities: capabilities, template: template, plan: plan))
        #expect(PommeTemplateAgentAdoption.accepts(digest: digest, capabilities: capabilities, template: template, plan: plan))
        #expect(!PommeTemplateAgentAdoption.accepts(
            digest: String(repeating: "f", count: 64), capabilities: capabilities, template: template, plan: plan))
        #expect(!PommeTemplateAgentAdoption.accepts(
            digest: templateDigest, capabilities: ["file.open", "process.start"], template: template, plan: plan))
    }

    @Test("The startup volume group must be the recorded single System and Data pair that holds the root")
    func startupVolumeGroup() throws {
        let other = UUID()
        let groups = try volumeGroupsPlist([group, other])
        #expect(PommeTemplateAgentAdoption.startupVolumeGroup(
            volumeGroups: groups, rootInfo: try rootInfoPlist(group: group), expected: group) == group)
        // The root is on another group.
        #expect(PommeTemplateAgentAdoption.startupVolumeGroup(
            volumeGroups: groups, rootInfo: try rootInfoPlist(group: other), expected: group) == nil)
        // The recorded group isn't on this disk.
        #expect(PommeTemplateAgentAdoption.startupVolumeGroup(
            volumeGroups: try volumeGroupsPlist([other]), rootInfo: try rootInfoPlist(group: group), expected: group) == nil)
        // The root isn't mounted at /.
        #expect(PommeTemplateAgentAdoption.startupVolumeGroup(
            volumeGroups: groups, rootInfo: try rootInfoPlist(group: group, mountPoint: "/Volumes/Data"), expected: group) == nil)
        #expect(PommeTemplateAgentAdoption.startupVolumeGroup(
            volumeGroups: Data("garbage".utf8), rootInfo: try rootInfoPlist(group: group), expected: group) == nil)
        // Without a recorded group, as after an interrupted Recovery
        // installation, the disk must have exactly one System and Data pair.
        #expect(PommeTemplateAgentAdoption.startupVolumeGroup(
            volumeGroups: try volumeGroupsPlist([group]), rootInfo: try rootInfoPlist(group: group), expected: nil) == group)
        #expect(PommeTemplateAgentAdoption.startupVolumeGroup(
            volumeGroups: groups, rootInfo: try rootInfoPlist(group: group), expected: nil) == nil)
    }

    // MARK: Provisioning input and disclosure

    @Test("A clone's input records the template agent only with its template, and older inputs decode without it")
    func provisioningInputTemplateAgent() throws {
        let plan = try plan()
        func input(templatePath: String?, agent: PommeTemplateAgentReference?) -> PommeProvisioningInput {
            .init(restoreImagePath: "/tmp/Restore.ipsw", memorySizeBytes: 4 << 30, diskSizeBytes: 40 << 30,
                  hardwareModelData: Data([1]), machineIdentifierData: Data([2]),
                  templateBundlePath: templatePath, templateAgent: agent)
        }
        try input(templatePath: "/tmp/Templates/mdm-ready.bundle", agent: reference()).validate(for: plan)
        #expect(throws: PommeProvisioningError.invalidPlan) {
            try input(templatePath: nil, agent: reference()).validate(for: plan)
        }
        #expect(throws: PommeProvisioningError.invalidPlan) {
            try input(templatePath: "/tmp/Templates/mdm-ready.bundle", agent: reference(digest: "bad")).validate(for: plan)
        }

        let encoded = try JSONEncoder().encode(input(templatePath: "/tmp/Templates/base.bundle", agent: nil))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["templateAgent"] == nil)
        object.removeValue(forKey: "templateAgent")
        let legacy = try JSONDecoder().decode(
            PommeProvisioningInput.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.templateAgent == nil)
        // The serialized input never carries a credential, only its identifier.
        let withAgent = try JSONEncoder().encode(input(templatePath: "/tmp/Templates/mdm-ready.bundle", agent: reference()))
        let recorded = try #require(
            (try JSONSerialization.jsonObject(with: withAgent) as? [String: Any])?["templateAgent"] as? [String: Any])
        #expect(Set(recorded.keys) == ["credentialID", "executableDigest", "startupVolumeGroupUUID"])
    }

    @Test("A template clone discloses that its agent comes from the template")
    func disclosure() {
        #expect(PommeCore.provisioningDisclosure(virtualization: false, templateAgent: true)["agentInstallMethod"] == "template")
        #expect(PommeCore.provisioningDisclosure(virtualization: false)["agentInstallMethod"] == "recovery")
        #expect(PommeCore.provisioningDisclosure(virtualization: true, templateAgent: true)["agentInstallMethod"] == "ssh-bootstrap")
    }

    @Test("Verification proves only the connected normal agent with the pinned digest and capabilities")
    func pinnedAgentProof() throws {
        let plan = try plan()
        let required = Array(PommeCore.requiredProvisioningAgentCapabilities)
        let pinned = digest
        func status(_ connection: PommeAgentClosedStatus.Connection = .connected,
                    role: PommeProvisioningAgentRole = .normal,
                    digest: String? = nil, capabilities: [String]? = nil) -> PommeAgentClosedStatus {
            .init(connection: connection, role: role, protocolVersion: 1,
                  executableDigest: digest ?? pinned, capabilities: capabilities ?? required, updateState: "")
        }
        #expect(PommeCore.provesPinnedNormalAgent(status(), plan: plan))
        #expect(!PommeCore.provesPinnedNormalAgent(status(.disconnected), plan: plan))
        #expect(!PommeCore.provesPinnedNormalAgent(status(role: .recovery), plan: plan))
        #expect(!PommeCore.provesPinnedNormalAgent(status(digest: templateDigest), plan: plan))
        #expect(!PommeCore.provesPinnedNormalAgent(status(capabilities: ["process.start"]), plan: plan))
    }

    private func volumeGroupsPlist(_ groups: [UUID]) throws -> Data {
        let entries: [[String: Any]] = groups.enumerated().map { index, uuid in
            [
                "APFSVolumeGroupUUID": uuid.uuidString,
                "Volumes": [
                    ["DeviceIdentifier": "disk3s\(index * 2 + 1)", "Roles": ["System"]],
                    ["DeviceIdentifier": "disk3s\(index * 2 + 2)", "Roles": ["Data"]],
                ],
            ]
        }
        return try PropertyListSerialization.data(
            fromPropertyList: ["Containers": [["VolumeGroups": entries]]], format: .xml, options: 0)
    }

    private func rootInfoPlist(group: UUID, mountPoint: String = "/") throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "APFSVolumeGroupID": group.uuidString,
            "FilesystemType": "apfs",
            "MountPoint": mountPoint,
            "DeviceIdentifier": "disk3s1s1",
            "VolumeUUID": UUID().uuidString,
        ], format: .xml, options: 0)
    }
}

/// An isolated, temporary file-based Keychain. Tests never touch the login
/// Keychain or real Pomme credentials.
private struct AdoptionTemporaryKeychain {
    private static let password = Data("pomme-adoption-test-keychain".utf8)

    let path: String
    let keychain: SecKeychain

    init() throws {
        let fixturePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-template-agent-\(UUID().uuidString).keychain-db").path
        var created: SecKeychain?
        let status = Self.password.withUnsafeBytes { bytes in
            SecKeychainCreate(fixturePath, UInt32(bytes.count), bytes.baseAddress, false, nil, &created)
        }
        guard status == errSecSuccess, let created else { throw AdoptionFixtureError.keychain(status) }
        path = fixturePath
        keychain = created
    }

    func lock() throws {
        let status = SecKeychainLock(keychain)
        guard status == errSecSuccess else { throw AdoptionFixtureError.keychain(status) }
    }

    func unlock() throws {
        let status = Self.password.withUnsafeBytes { bytes in
            SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
        }
        guard status == errSecSuccess else { throw AdoptionFixtureError.keychain(status) }
    }

    func cleanup() {
        _ = Self.password.withUnsafeBytes { bytes in
            SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
        }
        if SecKeychainDelete(keychain) != errSecSuccess {
            Issue.record("Temporary Keychain cleanup failed.")
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func add(_ event: String) { lock.withLock { recorded.append(event) } }
    var events: [String] { lock.withLock { recorded } }
}

private enum AdoptionFixtureError: Error {
    case keychain(OSStatus)
}
