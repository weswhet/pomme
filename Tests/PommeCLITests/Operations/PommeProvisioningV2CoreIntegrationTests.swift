import Darwin
import Foundation
import Testing

struct PommeProvisioningV2CoreIntegrationTests {
    @Test(arguments: [0, 3])
    func frameworkRemoteLoginShutdownAcceptsAlreadyUnloadedService(bootoutStatus: Int) throws {
        var calls: [[String]] = []
        try PommeCore.disableFrameworkRemoteLogin { request in
            calls.append([request.path] + request.arguments)
            let action = request.arguments.first
            return GuestCommandResult(exitCode: action == "bootout" ? bootoutStatus : (action == "print" ? 113 : 0), signal: nil,
                stdout: Data(action == "-getremotelogin" ? "Remote Login: Off\n".utf8 : "".utf8),
                stderr: Data(action == "print" ? "Could not find service \"com.openssh.sshd\" in domain for system\n".utf8 : "".utf8),
                stdoutTruncated: false, stderrTruncated: false)
        }
        #expect(calls == [["/bin/launchctl", "disable", "system/com.openssh.sshd"],
                          ["/bin/launchctl", "bootout", "system/com.openssh.sshd"],
                          ["/usr/sbin/systemsetup", "-getremotelogin"],
                          ["/bin/launchctl", "print", "system/com.openssh.sshd"]])
    }

    @Test(arguments: ["disable", "on", "servicePresent", "unknownPrintFailure", "timeout", "truncated"])
    func frameworkRemoteLoginShutdownRequiresIndependentOffReadbacks(failure: String) throws {
        #expect(throws: PommeProvisioningV2Error.self) {
            try PommeCore.disableFrameworkRemoteLogin { request in
                let action = request.arguments.first
                let code = action == "disable" && failure == "disable" ? 1 : (action == "print" && failure != "servicePresent" ? 113 : 0)
                return GuestCommandResult(exitCode: code, signal: nil,
                    stdout: Data(action == "-getremotelogin" ? "Remote Login: \(failure == "on" ? "On" : "Off")\n".utf8 : "".utf8),
                    stderr: Data(action == "print" && failure != "unknownPrintFailure" ? "Could not find service \"com.openssh.sshd\" in domain for system\n".utf8 : "".utf8),
                    stdoutTruncated: failure == "truncated", stderrTruncated: false, timedOut: failure == "timeout")
            }
        }
    }

    @Test func routeRequiresEveryFirstBootCondition() {
        #expect(PommeCore.usesVirtualizationProvisioning(guestVersion: "27.0", firstBootEligible: true, hostMajor: 27, apiAvailable: true))
        #expect(PommeCore.usesVirtualizationProvisioning(guestVersion: "27", firstBootEligible: true, hostMajor: 28, apiAvailable: true))
        #expect(!PommeCore.usesVirtualizationProvisioning(guestVersion: "28", firstBootEligible: true, hostMajor: 28, apiAvailable: true))
        #expect(!PommeCore.usesVirtualizationProvisioning(guestVersion: "27", firstBootEligible: false, hostMajor: 27, apiAvailable: true))
        #expect(!PommeCore.usesVirtualizationProvisioning(guestVersion: "27", firstBootEligible: true, hostMajor: 26, apiAvailable: true))
        #expect(!PommeCore.usesVirtualizationProvisioning(guestVersion: "27", firstBootEligible: true, hostMajor: 27, apiAvailable: false))
        #expect(!PommeCore.usesVirtualizationProvisioning(guestVersion: "27beta", firstBootEligible: true, hostMajor: 27, apiAvailable: true))
    }

    @Test func disclosureIsClosedAndNeverRendersPrivateFields() throws {
        let fields = PommeCore.provisioningDisclosure(virtualization: true)
        #expect(fields == ["guestProvisioning": "virtualization", "agentInstallMethod": "ssh-bootstrap",
            "account": "pomme", "automaticLogin": "enabled", "remoteLogin": "off"])
        let payload: [String: Any] = fields.merging(["password": "secret-canary", "ownerReference": "private-canary"]) { _, new in new }
        let summary = PommeApplication.provisioningSummary(payload)
        #expect(!summary.contains("canary"))
        #expect(!summary.contains("password"))
        #expect(summary.contains("remoteLogin=off"))
        let legacy = PommeCore.provisioningDisclosure(virtualization: false)
        #expect(legacy["account"] == nil)
        #expect(legacy["guestProvisioning"] == "recovery")
        #expect(PommeApplication.provisioningSummary(legacy).isEmpty)
    }

    @Test func journalSelectionRejectsAmbiguityAndSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = BundleLayout(rootURL: root)
        let state = root.appendingPathComponent(".pomme")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(try PommeCore.provisioningSchemaIfPresent(bundle: bundle) == nil)
        let v1 = state.appendingPathComponent("provisioning-v1.json")
        let v2 = state.appendingPathComponent("provisioning-v2.json")
        try PommeCore.persistExactBootstrapFile(Data("legacy-bytes".utf8), at: v1, mode: 0o600)
        #expect(try PommeCore.provisioningSchema(bundle: bundle) == 1)
        try PommeCore.persistExactBootstrapFile(Data("v2-bytes".utf8), at: v2, mode: 0o600)
        #expect(throws: PommeProvisioningError.self) { try PommeCore.provisioningSchema(bundle: bundle) }
        #expect(try Data(contentsOf: v1) == Data("legacy-bytes".utf8))
        try FileManager.default.removeItem(at: v1)
        #expect(try PommeCore.provisioningSchema(bundle: bundle) == 2)
        try FileManager.default.removeItem(at: v2)
        try FileManager.default.createSymbolicLink(at: v2, withDestinationURL: root.appendingPathComponent("missing"))
        #expect(throws: PommeProvisioningError.self) { try PommeCore.provisioningSchema(bundle: bundle) }
    }

    @Test func dispatchMarkerIsExclusiveAndContainsOnlyBoundIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("dispatched")
        let marker = PommeProvisioningDispatchMarker(vmUUID: UUID(), planDigest: String(repeating: "a", count: 64), attempt: 1)
        try PommeCore.persistProvisioningDispatch(marker, at: url)
        let bytes = try PommeSSHBootstrap.privateRead(url, owner: geteuid(), allowedModes: [0o600])
        #expect(try JSONDecoder().decode(PommeProvisioningDispatchMarker.self, from: bytes) == marker)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == ["vmUUID", "planDigest", "attempt"])
        #expect(throws: PommeProvisioningV2Error.ambiguousProvisionGuest) { try PommeCore.persistProvisioningDispatch(marker, at: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func stagingReplayRejectsAlteredBytesAndFileModes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("request")
        let original = Data("original".utf8)
        try PommeCore.persistExactBootstrapFile(original, at: url, mode: 0o600)
        try PommeCore.persistExactBootstrapFile(original, at: url, mode: 0o600)
        #expect(throws: PommeSSHBootstrapError.self) { try PommeCore.persistExactBootstrapFile(Data("altered".utf8), at: url, mode: 0o600) }
        #expect(try Data(contentsOf: url) == original)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: PommeSSHBootstrapError.self) { try PommeCore.persistExactBootstrapFile(original, at: url, mode: 0o600) }
    }

    @Test func ownerReferenceResumeAcceptsDifferentKeyOrderWithoutRewriting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try PommeOwnerCredentialReference(vmUUID: UUID(),
            machineIdentifierSHA256: String(repeating: "a", count: 64), diskImageFileResourceID: "1:2")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonical = try encoder.encode(owner)
        // These fields contain no commas, so reversal produces a valid legacy
        // encoding with the exact same values and a deliberately different order.
        let body = String(decoding: canonical, as: UTF8.self).dropFirst().dropLast()
        let reordered = Data(("{" + body.split(separator: ",").reversed().joined(separator: ",") + "}").utf8)
        #expect(reordered != canonical)
        for (index, bytes) in [canonical, reordered].enumerated() {
            let url = root.appendingPathComponent("owner-\(index)")
            try PommeCore.persistExactBootstrapFile(bytes, at: url, mode: 0o600)
            try PommeCore.persistBootstrapOwnerReference(owner, at: url)
            #expect(try Data(contentsOf: url) == bytes)
        }
        for name in ["new-one", "new-two"] {
            let url = root.appendingPathComponent(name)
            try PommeCore.persistBootstrapOwnerReference(owner, at: url)
            #expect(try PommeSSHBootstrap.privateRead(url, owner: geteuid(), allowedModes: [0o600]) == canonical)
        }
    }

    @Test(arguments: ["mismatch", "unknown-key", "mode", "symlink", "hardlink", "directory"])
    func ownerReferenceResumeRejectsChangedOrUnsafeFile(kind: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try PommeOwnerCredentialReference(vmUUID: UUID(),
            machineIdentifierSHA256: String(repeating: "a", count: 64), diskImageFileResourceID: "1:2")
        let url = root.appendingPathComponent("owner")
        var bytes = try JSONEncoder().encode(owner)
        if kind == "mismatch" {
            bytes = try JSONEncoder().encode(owner.bindingGeneratedUID(UUID()))
        } else if kind == "unknown-key" {
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["unknown"] = true
            bytes = try JSONSerialization.data(withJSONObject: object)
        }
        if kind == "directory" {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else if kind == "symlink" {
            let target = root.appendingPathComponent("target")
            try PommeCore.persistExactBootstrapFile(bytes, at: target, mode: 0o600)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        } else {
            try PommeCore.persistExactBootstrapFile(bytes, at: url, mode: kind == "mode" ? 0o644 : 0o600)
            if kind == "hardlink" {
                try FileManager.default.linkItem(at: url, to: root.appendingPathComponent("alias"))
            }
        }
        #expect(throws: PommeSSHBootstrapError.self) { try PommeCore.persistBootstrapOwnerReference(owner, at: url) }
        if kind != "directory" { #expect(try Data(contentsOf: url) == bytes) }
    }

    @Test(arguments: ["owner", "agent", "bundle"])
    func deletionRollsBackExactCredentialsOnEveryDownstreamFailure(failure: String) throws {
        let originalOwner = "original-provisioned-password"
        let originalAgent = "original-agent-token"
        var owner: String? = originalOwner
        var agent: String? = originalAgent
        var bundleExists = true
        var restorations: [String] = []
        #expect(throws: PommeSSHBootstrapError.self) {
            try PommeCore.performProvisioningDeletion(cleanupOwner: {
                owner = nil
                if failure == "owner" { throw PommeSSHBootstrapError.invalid }
            }, cleanupAgent: {
                agent = nil
                if failure == "agent" { throw PommeSSHBootstrapError.invalid }
            }, removeBundle: {
                if failure == "bundle" { throw PommeSSHBootstrapError.invalid }
                bundleExists = false
            }, restoreOwner: { owner = originalOwner; restorations.append("owner") },
               restoreAgent: { agent = originalAgent; restorations.append("agent") })
        }
        #expect(owner == originalOwner)
        #expect(agent == originalAgent)
        #expect(bundleExists)
        #expect(restorations == ["owner", "agent"])
    }

    @Test func successfulDeletionDoesNotRestoreOrRegenerateCredentials() throws {
        var owner: String? = "owner"
        var agent: String? = "token"
        var bundleExists = true
        var restorationCalls = 0
        try PommeCore.performProvisioningDeletion(cleanupOwner: { owner = nil },
            cleanupAgent: { agent = nil }, removeBundle: { bundleExists = false },
            restoreOwner: { restorationCalls += 1 }, restoreAgent: { restorationCalls += 1 })
        #expect(owner == nil && agent == nil && !bundleExists)
        #expect(restorationCalls == 0)
    }

    @Test func signedDeletionUsesPlanUUIDWhenMetadataOrUUIDIsMissing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = BundleLayout(rootURL: root)
        let plan = try deletionPlan(bundle: bundle)
        #expect(try PommeCore.deletionCredentialUUID(plan: plan, bundle: bundle) == plan.vm.uuid)
        try Data("{}".utf8).write(to: bundle.metadataURL)
        #expect(try PommeCore.deletionCredentialUUID(plan: plan, bundle: bundle) == plan.vm.uuid)
        try JSONSerialization.data(withJSONObject: [Constants.vmUUIDMetadataKey: plan.vm.uuid.uuidString.lowercased()]).write(to: bundle.metadataURL)
        #expect(try PommeCore.deletionCredentialUUID(plan: plan, bundle: bundle) == plan.vm.uuid)
    }

    @Test(arguments: ["invalid-json", "array", "invalid-uuid", "null-uuid", "numeric-uuid", "different-uuid"])
    func signedDeletionRejectsCorruptOrMismatchedMetadata(kind: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = BundleLayout(rootURL: root)
        let plan = try deletionPlan(bundle: bundle)
        let data: Data
        switch kind {
        case "invalid-json": data = Data("{".utf8)
        case "array": data = Data("[]".utf8)
        case "invalid-uuid": data = try JSONSerialization.data(withJSONObject: [Constants.vmUUIDMetadataKey: "corrupt"])
        case "null-uuid": data = try JSONSerialization.data(withJSONObject: [Constants.vmUUIDMetadataKey: NSNull()])
        case "numeric-uuid": data = try JSONSerialization.data(withJSONObject: [Constants.vmUUIDMetadataKey: 42])
        default: data = try JSONSerialization.data(withJSONObject: [Constants.vmUUIDMetadataKey: UUID().uuidString])
        }
        try data.write(to: bundle.metadataURL)
        #expect(throws: PommeProvisioningError.ownershipMismatch) {
            try PommeCore.deletionCredentialUUID(plan: plan, bundle: bundle)
        }
        #expect(FileManager.default.fileExists(atPath: bundle.rootURL.path))
    }

    @Test func unjournaledDeletionRetainsOptionalMetadataBehavior() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = BundleLayout(rootURL: root)
        #expect(try PommeCore.deletionCredentialUUID(plan: nil, bundle: bundle) == nil)
        try Data("not-json".utf8).write(to: bundle.metadataURL)
        #expect(try PommeCore.deletionCredentialUUID(plan: nil, bundle: bundle) == nil)
        let uuid = UUID()
        try JSONSerialization.data(withJSONObject: [Constants.vmUUIDMetadataKey: uuid.uuidString]).write(to: bundle.metadataURL)
        #expect(try PommeCore.deletionCredentialUUID(plan: nil, bundle: bundle) == uuid)
    }

    @Test func rollbackAttemptsBothCredentialsAndReportsUnverifiedRecovery() {
        var agentRestored = false
        #expect(throws: RunnerError.self) {
            try PommeCore.performProvisioningDeletion(cleanupOwner: {},
                cleanupAgent: { throw PommeSSHBootstrapError.invalid }, removeBundle: {},
                restoreOwner: { throw PommeSSHBootstrapError.invalid },
                restoreAgent: { agentRestored = true })
        }
        #expect(agentRestored)
    }

    @Test func disclosureWaitsForSignedVerificationReceipt() throws {
        let digest = String(repeating: "a", count: 64)
        let plan = try PommeProvisioningPlan(vm: .init(name: "pomme-disclosure", uuid: UUID(), bundlePath: "/tmp/pomme-disclosure.bundle"),
            restore: .init(version: "27.0.0", build: "26A1", restoreImageDigest: digest), display: .required,
            profile: .init(descriptor: PommeRecoveryProfileSelector.descriptor(version: "27.0", build: "26A1")),
            normalAgent: .init(identifier: "normal", executableDigest: digest, role: .normal),
            recoveryAgent: .init(identifier: "recovery", executableDigest: digest, role: .recovery), finalState: .normalRunning)
        let owner = try PommeOwnerCredentialReference(vmUUID: plan.vm.uuid,
            machineIdentifierSHA256: digest, diskImageFileResourceID: "1:2")
        let signer = try PommeProvisioningV2Signer(key: Data(repeating: 1, count: 32))
        var events: [PommeProvisioningV2Event] = []
        for phase in PommeProvisioningV2Phase.allCases where phase != .restoreFinalState {
            events.append(.init(kind: .intent, phase: phase, attempt: 1))
            let pending = try signer.make(generation: 1, plan: plan, ownerReference: owner, events: events)
            let fields = PommeCore.provisioningDisclosure(journal: pending)
            #expect(fields["automaticLogin"] == "pending")
            #expect(fields["remoteLogin"] == "unknown")
            #expect(fields["guestProvisioning"] == "virtualization")
            #expect(fields["agentInstallMethod"] == "ssh-bootstrap")
            events.append(.init(kind: .receipt, phase: phase, attempt: 1, digest: digest))
        }
        let verified = try signer.make(generation: 1, plan: plan, ownerReference: owner,
            startupVolumeGroupUUID: UUID(), events: events)
        #expect(PommeCore.provisioningDisclosure(journal: verified)["automaticLogin"] == "enabled")
        #expect(PommeCore.provisioningDisclosure(journal: verified)["remoteLogin"] == "off")
    }

    @Test func onlyAbsentDispatchMarkerAllowsRetry() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("dispatched")
        let marker = PommeProvisioningDispatchMarker(vmUUID: UUID(), planDigest: String(repeating: "a", count: 64), attempt: 1)
        #expect(try !PommeCore.provisioningDispatchExists(at: url, vmUUID: marker.vmUUID, planDigest: marker.planDigest))
        try PommeCore.persistProvisioningDispatch(marker, at: url)
        #expect(try PommeCore.provisioningDispatchExists(at: url, vmUUID: marker.vmUUID, planDigest: marker.planDigest))
        #expect(throws: PommeProvisioningV2Error.ambiguousProvisionGuest) {
            try PommeCore.provisioningDispatchExists(at: url, vmUUID: UUID(), planDigest: marker.planDigest)
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("missing"))
        #expect(throws: PommeProvisioningV2Error.ambiguousProvisionGuest) {
            try PommeCore.provisioningDispatchExists(at: url, vmUUID: marker.vmUUID, planDigest: marker.planDigest)
        }
    }

    @Test func frameworkRepairRejectsBeforeLegacyJournalOrRecovery() throws {
        try PommeCore.validateProvisioningRepairSchema(1)
        #expect(throws: RunnerError.self) { try PommeCore.validateProvisioningRepairSchema(2) }
    }

    @Test func boundedProcessDoesNotExposeErrorOutput() throws {
        let output = try PommeCore.runBootstrapProcess("/usr/bin/printf", arguments: ["safe"])
        #expect(output == Data("safe".utf8))
        do {
            _ = try PommeCore.runBootstrapProcess("/bin/sh", arguments: ["-c", "printf private-canary >&2; exit 17"])
            Issue.record("Expected subprocess failure")
        } catch {
            #expect(error.localizedDescription == "The guest bootstrap subprocess exited with status 17.")
            #expect(!error.localizedDescription.contains("private-canary"))
        }
        #expect(throws: PommeSSHBootstrapError.self) {
            try PommeCore.runBootstrapProcess("/bin/sleep", arguments: ["1"], timeout: 0.01)
        }
    }

    private func deletionPlan(bundle: BundleLayout) throws -> PommeProvisioningPlan {
        let digest = String(repeating: "a", count: 64)
        return try .init(vm: .init(name: "pomme-delete-test", uuid: UUID(), bundlePath: bundle.rootURL.standardizedFileURL.path),
            restore: .init(version: "27.0.0", build: "26A1", restoreImageDigest: digest), display: .required,
            profile: .init(descriptor: PommeRecoveryProfileSelector.descriptor(version: "27.0.0", build: "26A1")),
            normalAgent: .init(identifier: "normal", executableDigest: digest, role: .normal),
            recoveryAgent: .init(identifier: "recovery", executableDigest: digest, role: .recovery), finalState: .normalRunning)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-v2-core-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}
