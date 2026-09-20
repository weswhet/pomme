import Foundation
import Darwin
import Testing

@Suite("SSH bootstrap identity")
struct PommeSSHBootstrapTests {
    private func discoveryLease(_ address: String = "192.168.64.2") -> String {
        "{\nip_address=\(address)\nhw_address=1,2:0:0:0:0:1\nlease=0x123\n}\n"
    }

    private func discoveryKey(_ address: String) -> String {
        let key = (Data([0,0,0,11]) + Data("ssh-ed25519".utf8) + Data([0,0,0,32]) + Data(repeating: 1, count: 32)).base64EncodedString()
        return "\(address) ssh-ed25519 \(key)\n"
    }

    @Test func discoveryUsesDHCPWithoutNeighborCache() throws {
        var events: [String] = []
        let result = try PommeSSHBootstrap.discoverHostKey(stableMAC: "02:00:00:00:00:01", readLeases: {
            events.append("lease"); return discoveryLease()
        }, scan: { candidate in
            events.append("nonsecret-scan")
            return discoveryKey(candidate)
        }, onEvent: { event in
            switch event {
            case .candidateSelected: events.append("candidate-selected")
            case .keyscanSucceeded: events.append("keyscan-succeeded")
            case .leaseVerified: events.append("lease-verified")
            }
        })
        #expect(events == ["lease", "candidate-selected", "nonsecret-scan", "keyscan-succeeded", "lease", "lease-verified"])
        #expect(result.address == "192.168.64.2")
        #expect(result.key == Data(discoveryKey(result.address).utf8))
    }

    @Test(arguments: ["missing", "changed", "ambiguous"])
    func unverifiedScanCannotReachPinOrCredentialPath(failure: String) throws {
        var reads = 0
        var reachedPinOrCredentialPath = false
        var checkpoints: [PommeSSHBootstrap.DiscoveryEvent] = []
        #expect(throws: (any Error).self) {
            _ = try PommeSSHBootstrap.discoverHostKey(stableMAC: "02:00:00:00:00:01", readLeases: {
                reads += 1
                if reads == 2 && failure == "missing" { return "" }
                if reads == 2 && failure == "changed" { return discoveryLease("192.168.64.3") }
                if reads == 2 && failure == "ambiguous" { return discoveryLease() + discoveryLease("192.168.64.3") }
                return discoveryLease()
            }, scan: { discoveryKey($0) }, onEvent: { checkpoints.append($0) })
            reachedPinOrCredentialPath = true
        }
        #expect(!reachedPinOrCredentialPath)
        #expect(reads == 2)
        #expect(checkpoints == [.candidateSelected, .keyscanSucceeded])
    }

    @Test func ambiguousInitialLeaseNeverScans() throws {
        var scanned = false
        var checkpoints: [PommeSSHBootstrap.DiscoveryEvent] = []
        #expect(throws: (any Error).self) {
            _ = try PommeSSHBootstrap.discoverHostKey(stableMAC: "02:00:00:00:00:01", readLeases: {
                discoveryLease() + discoveryLease("192.168.64.3")
            }, scan: { scanned = true; return discoveryKey($0) }, onEvent: { checkpoints.append($0) })
        }
        #expect(!scanned)
        #expect(checkpoints.isEmpty)
    }

    @Test(arguments: [false, true])
    func failedOrMalformedScanNeverReportsSuccess(throwsError: Bool) throws {
        var checkpoints: [PommeSSHBootstrap.DiscoveryEvent] = []
        var leaseReads = 0
        #expect(throws: (any Error).self) {
            _ = try PommeSSHBootstrap.discoverHostKey(stableMAC: "02:00:00:00:00:01", readLeases: {
                leaseReads += 1; return discoveryLease()
            }, scan: { _ in
                if throwsError { throw PommeSSHBootstrapError.invalid }
                return ""
            }, onEvent: { checkpoints.append($0) })
        }
        #expect(checkpoints == [.candidateSelected])
        #expect(leaseReads == 1)
    }

    private func reader(_ deliveries: [Data?], interrupted: Bool = false) -> PommeSSHBootstrap.ReadOperation {
        var remaining = deliveries
        var interrupt = interrupted
        return { _, destination, maximum in
            if interrupt { interrupt = false; errno = EINTR; return -1 }
            guard !remaining.isEmpty, let next = remaining.removeFirst() else { return 0 }
            let count = min(next.count, maximum)
            next.withUnsafeBytes { source in destination?.copyMemory(from: source.baseAddress!, byteCount: count) }
            if count < next.count { remaining.insert(Data(next.dropFirst(count)), at: 0) }
            return count
        }
    }

    @Test func privateReadsHandlePartialDeliveryAndInterruptions() throws {
        let result = try PommeSSHBootstrap.readExactly(descriptor: -1, count: 6, maximum: 6,
            read: reader([Data("ab".utf8), Data("c".utf8), Data("def".utf8)], interrupted: true))
        #expect(result == Data("abcdef".utf8))
        #expect(throws: (any Error).self) { try PommeSSHBootstrap.readExactly(descriptor: -1, count: 6, maximum: 6, read: reader([Data("ab".utf8), nil])) }
        #expect(throws: (any Error).self) { try PommeSSHBootstrap.readExactly(descriptor: -1, count: 7, maximum: 6, read: reader([])) }
    }

    @Test func leaseSelectionRequiresUniqueStableMACMatch() throws {
        let leases = "{\nname=guest\nip_address=192.168.64.2\nhw_address=1,2:0:0:0:0:1\nlease=0x123\n}\n"
        #expect(try PommeSSHBootstrap.address(leases: leases, stableMAC: "02:00:00:00:00:01") == "192.168.64.2")
        #expect(throws: (any Error).self) { try PommeSSHBootstrap.address(leases: leases, stableMAC: "02:00:00:00:00:02") }
        #expect(throws: (any Error).self) { try PommeSSHBootstrap.address(leases: leases + leases.replacingOccurrences(of: "64.2", with: "64.3"), stableMAC: "02:00:00:00:00:01") }
    }
    @Test func requestRejectsTamperingExpiryAndUnknownKeys() throws {
        let token = Data(repeating: 42, count: 64), vm = UUID(), digest = String(repeating: "a", count: 64)
        let request = try PommeBootstrapRequest(vmUUID: vm, requestID: UUID(), planSHA256: digest, executableSHA256: digest, expiresAt: 1200, stagingOwner: 501, token: token)
        try request.verify(token: token, now: Date(timeIntervalSince1970: 1000), vmUUID: vm, planSHA256: digest, executableSHA256: digest)
        #expect(throws: (any Error).self) { try request.verify(token: Data(repeating: 43, count: 64), now: Date(timeIntervalSince1970: 1000), vmUUID: vm, planSHA256: digest, executableSHA256: digest) }
        #expect(throws: (any Error).self) { try request.verify(token: token, now: Date(timeIntervalSince1970: 1200), vmUUID: vm, planSHA256: digest, executableSHA256: digest) }
        let data = try JSONEncoder().encode(request)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); object["password"] = "secret"
        let unknown = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PommeBootstrapRequest.self, from: unknown) }
        #expect(!String(decoding: data, as: UTF8.self).contains(String(decoding: token, as: UTF8.self)))
        #expect(request.description == "PommeBootstrapRequest(redacted)")
    }
    @Test func commandAndAskpassConfigurationContainOnlyLocators() throws {
        let args = try PommeSSHBootstrap.arguments(address: "192.168.64.2", knownHosts: URL(fileURLWithPath: "/private/test/known_hosts"), command: "/usr/bin/true")
        #expect(args.contains("StrictHostKeyChecking=yes")); #expect(args.contains("-T")); #expect(args.contains("PreferredAuthentications=password"))
        let env = PommeBootstrapAskpass.environment(executable: URL(fileURLWithPath: "/signed/pomme"), ownerReference: URL(fileURLWithPath: "/private/owner-reference.json"))
        #expect(env["POMME_INTERNAL_ASKPASS"] == "1"); #expect(env["SSH_ASKPASS"] == "/signed/pomme")
        #expect(Set(env.keys) == ["PATH", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY", "POMME_INTERNAL_ASKPASS", "POMME_BOOTSTRAP_OWNER_REFERENCE"])
        #expect(!String(describing: env).contains("private-test-password"))
        #expect(throws: (any Error).self) { try PommeSSHBootstrap.arguments(address: "host;command", knownHosts: URL(fileURLWithPath: "/private/test/known_hosts")) }
    }
    @Test func askpassReadsPrivateReferenceWithoutPuttingPasswordInEnvironment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("owner-reference.json")
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: root) }
        let reference = try PommeOwnerCredentialReference(vmUUID: UUID(), machineIdentifierSHA256: String(repeating: "a", count: 64), diskImageFileResourceID: "disk-fixture")
        try JSONEncoder().encode(reference).write(to: file)
        #expect(chmod(file.path, 0o600) == 0)
        let environment = PommeBootstrapAskpass.environment(executable: URL(fileURLWithPath: "/signed/pomme"), ownerReference: file)
        var reads = 0
        let read: (PommeOwnerCredentialReference) throws -> String = {
            #expect($0 == reference); reads += 1; return "private-test-password"
        }
        #expect(try PommeBootstrapAskpass.response(environment: environment, readCredential: read) == Data("private-test-password\n".utf8))
        #expect(reads == 1)
        #expect(!String(describing: environment).contains("private-test-password"))
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private-test-password"))
        #expect(throws: (any Error).self) { try PommeBootstrapAskpass.response(environment: [:], readCredential: read) }
        #expect(chmod(file.path, 0o644) == 0)
        #expect(throws: (any Error).self) { try PommeBootstrapAskpass.response(environment: environment, readCredential: read) }
        #expect(reads == 1)
    }
    @Test func hostKeyRejectsWrongHostAndChanges() throws {
        let key = (Data([0,0,0,11]) + Data("ssh-ed25519".utf8) + Data([0,0,0,32]) + Data(repeating: 1, count: 32)).base64EncodedString()
        let output = "192.168.64.2 ssh-ed25519 \(key)\n"
        #expect(try PommeSSHBootstrap.scannedHostKey(output, address: "192.168.64.2") == Data(output.utf8))
        #expect(throws: (any Error).self) { try PommeSSHBootstrap.scannedHostKey(output, address: "192.168.64.3") }
        #expect(throws: (any Error).self) { try PommeSSHBootstrap.scannedHostKey("", address: "192.168.64.2") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pin = root.appendingPathComponent("known_hosts")
        defer { try? FileManager.default.removeItem(at: pin); try? FileManager.default.removeItem(at: root) }
        let data = Data(output.utf8)
        try PommeSSHBootstrap.pinHostKey(data, at: pin)
        try PommeSSHBootstrap.pinHostKey(data, at: pin)
        let changed = Data(output.replacingOccurrences(of: "64.2", with: "64.3").utf8)
        try PommeSSHBootstrap.pinHostKey(changed, at: pin)
        #expect(try Data(contentsOf: pin) == changed)
        let otherKey = (Data([0,0,0,11]) + Data("ssh-ed25519".utf8) + Data([0,0,0,32]) + Data(repeating: 2, count: 32)).base64EncodedString()
        #expect(throws: (any Error).self) { try PommeSSHBootstrap.pinHostKey(Data("192.168.64.3 ssh-ed25519 \(otherKey)\n".utf8), at: pin) }
        #expect(chmod(pin.path, 0o644) == 0)
        #expect(throws: (any Error).self) { try PommeSSHBootstrap.pinHostKey(data, at: pin) }
    }
    @Test func sshAndScpQuoteKnownHostsPathWithSpaces() throws {
        let knownHosts = URL(fileURLWithPath: "/private/Application Support/pomme/known_hosts")
        let expected = "UserKnownHostsFile=\"/private/Application Support/pomme/known_hosts\""
        let ssh = try PommeSSHBootstrap.arguments(address: "192.168.64.2", knownHosts: knownHosts, command: "/usr/bin/true")
        let scp = try PommeSSHBootstrap.scpArguments(address: "192.168.64.2", knownHosts: knownHosts,
            source: URL(fileURLWithPath: "/private/test/pomme"), requestID: UUID())
        #expect(ssh.contains(expected))
        #expect(scp.contains(expected))
    }
    @Test func launchdActivationAndResumeReadBack() throws {
        var calls: [[String]] = []
        try PommeNormalBootstrapInstaller.activate(plist: URL(fileURLWithPath: "/Library/LaunchDaemons/test.plist")) { executable, arguments in
            #expect(executable == "/bin/launchctl"); calls.append(arguments)
            return calls.count == 1 ? 1 : 0
        }
        #expect(calls.map { $0[0] } == ["print", "bootstrap", "kickstart", "print"])
        calls = []
        try PommeNormalBootstrapInstaller.activate(plist: URL(fileURLWithPath: "/Library/LaunchDaemons/test.plist")) { _, arguments in calls.append(arguments); return 0 }
        #expect(calls.map { $0[0] } == ["print", "kickstart", "print"])
        #expect(throws: (any Error).self) {
            try PommeNormalBootstrapInstaller.activate(plist: URL(fileURLWithPath: "/Library/LaunchDaemons/test.plist")) { _, arguments in arguments[0] == "kickstart" ? 1 : 0 }
        }
    }
    @Test(arguments: [false, true]) func stagingRejectsTamperingAndUnsafeModesBeforeInstallation(privateVar: Bool) throws {
        let id = UUID()
        let parent = privateVar ? URL(fileURLWithPath: "/private/var/tmp") : FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("pomme-bootstrap-root-\(id.uuidString.lowercased()).test")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let executable = root.appendingPathComponent("pomme"), tokenFile = root.appendingPathComponent("agent.token"), manifest = root.appendingPathComponent("request.json")
        defer { for url in [executable, tokenFile, manifest, root] { try? FileManager.default.removeItem(at: url) } }
        let bytes = Data("fake-signed-agent-for-validation-only".utf8), token = Data(String(repeating: "a", count: 64).utf8)
        let request = try PommeBootstrapRequest(vmUUID: UUID(), requestID: id, planSHA256: String(repeating: "b", count: 64), executableSHA256: PommeBootstrapRequest.digest(bytes), expiresAt: 1200, stagingOwner: getuid(), token: token)
        for (url, data, mode) in [(executable, bytes, mode_t(0o700)), (tokenFile, token, mode_t(0o600)), (manifest, try JSONEncoder().encode(request), mode_t(0o600))] {
            try data.write(to: url); #expect(chmod(url.path, mode) == 0)
        }
        let expected = PommeNormalBootstrapInstaller.Expected(vmUUID: request.vmUUID, planSHA256: request.planSHA256, executableSHA256: request.executableSHA256, requestID: id)
        let verified = try PommeNormalBootstrapInstaller.validateStaging(workspace: root, selfExecutable: executable, now: Date(timeIntervalSince1970: 1000), expected: expected, expectedOwner: getuid(), requiredParent: parent)
        #expect(verified.request == request); #expect(verified.executable == bytes)
        #expect(chmod(tokenFile.path, 0o644) == 0)
        #expect(throws: (any Error).self) { try PommeNormalBootstrapInstaller.validateStaging(workspace: root, selfExecutable: executable, now: Date(timeIntervalSince1970: 1000), expected: expected, expectedOwner: getuid(), requiredParent: parent) }
        #expect(chmod(tokenFile.path, 0o600) == 0)
        try Data("tampered".utf8).write(to: executable)
        #expect(throws: (any Error).self) { try PommeNormalBootstrapInstaller.validateStaging(workspace: root, selfExecutable: executable, now: Date(timeIntervalSince1970: 1000), expected: expected, expectedOwner: getuid(), requiredParent: parent) }
    }
    @Test func sourceCleanupAcceptsPrivateVarAndRejectsLinkedWorkspace() throws {
        let id = UUID()
        let root = URL(fileURLWithPath: "/private/var/tmp/pomme-bootstrap-\(id.uuidString.lowercased())")
        let linkedTarget = URL(fileURLWithPath: "/private/var/tmp/pomme-bootstrap-test-\(UUID().uuidString)")
        let bytes = Data("agent".utf8), token = Data(String(repeating: "a", count: 64).utf8)
        let request = try PommeBootstrapRequest(vmUUID: UUID(), requestID: id, planSHA256: String(repeating: "b", count: 64), executableSHA256: PommeBootstrapRequest.digest(bytes), expiresAt: 1200, stagingOwner: getuid(), token: token)
        let staged = PommeNormalBootstrapInstaller.Staging(request: request, executable: bytes, token: token)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: linkedTarget)
        }
        let executable = root.appendingPathComponent("pomme")
        try bytes.write(to: executable)
        #expect(chmod(executable.path, 0o700) == 0)
        try PommeNormalBootstrapInstaller.cleanSourceWorkspace(root, staged: staged)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        // An interrupted cleanup with an absent directory remains replayable.
        try PommeNormalBootstrapInstaller.cleanSourceWorkspace(root, staged: staged)
        try FileManager.default.createDirectory(at: linkedTarget, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: linkedTarget)
        #expect(throws: (any Error).self) { try PommeNormalBootstrapInstaller.cleanSourceWorkspace(root, staged: staged) }
        #expect(FileManager.default.fileExists(atPath: linkedTarget.path))
    }
    @Test func renewalRetainsAuthenticatedIdentityAndRootCommandContainsNoSecret() throws {
        let token = Data(String(repeating: "a", count: 64).utf8), digest = String(repeating: "b", count: 64)
        let old = try PommeBootstrapRequest(vmUUID: UUID(), requestID: UUID(), planSHA256: digest, executableSHA256: digest, expiresAt: 1000, stagingOwner: 501, token: token)
        let renewed = try old.renewed(token: token, now: Date(timeIntervalSince1970: 2000), vmUUID: old.vmUUID, planSHA256: digest, executableSHA256: digest, requestID: old.requestID, stagingOwner: 501)
        #expect(renewed.requestID == old.requestID); #expect(renewed.expiresAt == 5600)
        let nearExpiry = try old.renewed(token: token, now: Date(timeIntervalSince1970: 999), vmUUID: old.vmUUID, planSHA256: digest, executableSHA256: digest, requestID: old.requestID, stagingOwner: 501)
        #expect(nearExpiry.expiresAt == 4599)
        try renewed.verify(token: token, now: Date(timeIntervalSince1970: 2000), vmUUID: old.vmUUID, planSHA256: digest, executableSHA256: digest)
        #expect(throws: (any Error).self) { try old.renewed(token: Data("wrong".utf8), now: Date(timeIntervalSince1970: 2000), vmUUID: old.vmUUID, planSHA256: digest, executableSHA256: digest, requestID: old.requestID, stagingOwner: 501) }
        let command = try PommeSSHBootstrap.installerCommand(request: renewed, stagedRequestSHA256: digest)
        #expect(command.hasPrefix("/usr/bin/sudo -kS -p '' -- /bin/sh -c "))
        #expect(!command.contains("codesign"))
        #expect(!command.contains("stage=47"))
        #expect(command.contains("stage=46"))
        #expect(command.contains("stage=48"))
        #expect(command.contains("exit \"$status\""))
        #expect(command.contains("mktemp -d /private/var/tmp/pomme-bootstrap-root-"))
        for stage in Array(40...46) + [48] { #expect(command.contains("stage=\(stage)")) }
        #expect(command.contains("status=$?; set +e; cleanup=0"))
        #expect(command.contains("cleanup=49"))
        #expect(command.contains("exit \"$stage\""))
        #expect(command.contains("exit \"$cleanup\""))
        #expect(!command.contains(String(decoding: token, as: UTF8.self)))
        #expect(!command.contains(renewed.authentication))
    }
    @Test func installerReportsStagingFailurePhase() {
        let result = PommeNormalBootstrapInstaller.run(arguments: [
            PommeNormalBootstrapInstaller.flag, "/private/var/tmp/pomme-missing-\(UUID().uuidString)",
            "/private/var/tmp/pomme-missing-source", UUID().uuidString,
            String(repeating: "a", count: 64), String(repeating: "b", count: 64), UUID().uuidString
        ])
        #expect(result == 51)
    }
}
