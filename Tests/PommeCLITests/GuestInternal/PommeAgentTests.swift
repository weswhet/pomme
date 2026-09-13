import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Pomme persistent agent")
struct PommeAgentTests {
    @Test("Recovery terminal authority exposes only health and terminal capabilities")
    func recoveryTerminalAuthority() async throws {
        let agent = try PommeAgent(
            role: .recovery,
            executableSHA256: String(repeating: "a", count: 64),
            authority: .recoveryTerminal
        )
        let describe = try await agent.perform(.request(operation: "agent.describe"))
        #expect(describe.objectValue?["terminalSessionVersion"] == .integer(Int64(PommeTerminalService.protocolVersion)))
        #expect(describe.objectValue?["capabilities"]?.arrayValue?.compactMap(\.stringValue) == PommeAgent.recoveryTerminalCapabilities)
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "file.read"))
        }
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.performAsynchronously(.request(operation: "sip.status"))
        }
    }

    @Test("Capabilities and ordinary-operation update gate are closed")
    func capabilitiesAndUpdateGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("pomme")
        let staged = directory.appendingPathComponent(".pomme-stage")
        try Data("old-agent".utf8).write(to: executable); try Data("new-agent".utf8).write(to: staged)
        let oldDigest = try PommeAgentFileTransaction.sha256(executable)
        let newDigest = try PommeAgentFileTransaction.sha256(staged)
        let agent = try PommeAgent(role: .persistent, executableSHA256: oldDigest, journalPath: directory.appendingPathComponent("journal").path, executablePath: executable.path)
        let describe = try await agent.perform(.request(operation: "agent.describe"))
        #expect(describe.objectValue?["role"]?.stringValue == "persistent")
        #expect(describe.objectValue.map { Set($0.keys) } == Set(["role", "protocol", "version", "executableSHA256", "capabilities", "terminalSessionVersion"]))
        #expect(describe.objectValue?["publicPTYEchoVersion"] == nil)
        #expect(describe.objectValue?["privatePTYInputVersion"] == nil)
        let mdmDescription = try MDMEnrollmentAgentDescription.fromAuthenticatedDescribe(describe)
        #expect(mdmDescription.role == "persistent")
        let privatePTYDescribe = try await agent.perform(.request(
            operation: "agent.describe",
            payload: .object(["includePrivatePTYCapabilities": .bool(true)])
        ))
        #expect(privatePTYDescribe.objectValue.map { Set($0.keys) } == Set(["role", "protocol", "version", "executableSHA256", "capabilities", "privatePTYInputVersion", "terminalSessionVersion"]))
        #expect(privatePTYDescribe.objectValue?["privatePTYInputVersion"] == .integer(Int64(PommeAgent.privatePTYInputVersion)))
        let publicPTYDescribe = try await agent.perform(.request(
            operation: "agent.describe",
            payload: .object(["includePublicPTYCapabilities": .bool(true)])
        ))
        #expect(publicPTYDescribe.objectValue.map { Set($0.keys) } == Set([
            "role", "protocol", "version", "executableSHA256", "capabilities", "publicPTYEchoVersion", "terminalSessionVersion"
        ]))
        #expect(publicPTYDescribe.objectValue?["publicPTYEchoVersion"] == .integer(Int64(PommeAgent.publicPTYEchoVersion)))
        let normalAMFIDescribe = try await agent.perform(.request(
            operation: "agent.describe",
            payload: .object(["includeNormalAMFICapabilities": .bool(true)])
        ))
        #expect(normalAMFIDescribe.objectValue.map { Set($0.keys) } == Set([
            "role", "protocol", "version", "executableSHA256", "capabilities", "terminalSessionVersion",
            "normalAMFIWorkflowVersion"
        ]))
        #expect(normalAMFIDescribe.objectValue?["normalAMFIWorkflowVersion"] == .integer(Int64(PommeAgent.normalAMFIWorkflowVersion)))
        #expect(normalAMFIDescribe.objectValue?["capabilities"]?.arrayValue?.compactMap(\.stringValue).contains("amfi.normal.disable") == true)
        let begin = try await agent.perform(.request(operation: "maintenance.update.begin", payload: .object(["targetSHA256": .string(newDigest), "targetBytes": .integer(9), "stagedExecutable": .string(staged.path)])))
        let transaction = try #require(begin.objectValue?["transactionID"]?.stringValue)
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "agent.health"))
        }
        _ = try await agent.perform(.request(operation: "maintenance.update.commit", payload: .object(["transactionID": .string(transaction), "targetSHA256": .string(newDigest)])))
        _ = try await agent.perform(.request(operation: "maintenance.update.finalize", payload: .object(["transactionID": .string(transaction), "activatedSHA256": .string(newDigest)])))
        #expect((try await agent.perform(.request(operation: "agent.health"))).objectValue?["ok"] == .bool(true))
    }

    @Test("Remote Login only reports success after its transaction succeeds")
    func remoteLoginTransaction() async throws {
        let agent = try PommeAgent(
            role: .persistent,
            executableSHA256: String(repeating: "a", count: 64),
            remoteLoginTransaction: { enabled in
                #expect(enabled)
                return true
            }
        )
        let value = try await agent.perform(.request(operation: "remoteLogin.set", payload: .object(["enabled": .bool(true)])))
        #expect(value.objectValue?["enabled"] == .bool(true))
    }

    @Test("Remote Login uses systemsetup's verified status surface")
    func remoteLoginUsesVerifiedSystemSetupState() throws {
        var invocations: [[String]] = []
        let observed = try PommeRemoteLogin.apply(enabled: false) { arguments in
            invocations.append(arguments)
            if arguments == ["-f", "-setremotelogin", "off"] {
                return .init(stdout: "", stderr: "")
            }
            return .init(stdout: "Remote Login: Off\n", stderr: "")
        }
        #expect(!observed)
        #expect(invocations == [
            ["-f", "-setremotelogin", "off"],
            ["-getremotelogin"]
        ])
    }

    @Test("Remote Login rejects FDA denial and unverifiable state without exposing command output")
    func remoteLoginRejectsUnverifiedState() {
        #expect(throws: PommeAgentOperationError.remoteLoginFullDiskAccessRequired) {
            try PommeRemoteLogin.apply(enabled: true) { _ in
                .init(stdout: "", stderr: "Turning Remote Login on requires Full Disk Access.")
            }
        }
        #expect(throws: PommeAgentOperationError.remoteLoginVerificationFailed) {
            try PommeRemoteLogin.apply(enabled: true) { arguments in
                .init(
                    stdout: arguments == ["-getremotelogin"] ? "Remote Login: Off\n" : "",
                    stderr: ""
                )
            }
        }
        #expect(throws: PommeAgentOperationError.remoteLoginVerificationFailed) {
            try PommeRemoteLogin.apply(enabled: true) { _ in
                .init(stdout: "Remote Login status unavailable", stderr: "")
            }
        }
        #expect(throws: PommeAgentOperationError.io) {
            try PommeRemoteLogin.apply(enabled: true) { _ in throw PommeAgentOperationError.io }
        }
    }

    @Test("An unresolved activation journal survives restart and fails closed")
    func restartGate() async throws {
        let journal = try PommeAgentUpdateJournal(phase: .activationPending, sourceSHA256: String(repeating: "a", count: 64), targetSHA256: String(repeating: "b", count: 64), targetBytes: 1)
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64), recoveredJournal: journal)
        await #expect(throws: PommeAgentOperationError.self) { _ = try await agent.perform(.request(operation: "agent.health")) }
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.performAsynchronously(.request(operation: "process.wait"))
        }
    }

    @Test("Journal is digest-bound and transactional")
    func journal() throws {
        let journal = try PommeAgentUpdateJournal(phase: .prepared, sourceSHA256: String(repeating: "a", count: 64), targetSHA256: String(repeating: "b", count: 64), targetBytes: 1)
        #expect(try journal.changing(.staged).phase == .staged)
        #expect(PommeAgentInstall.executable == "/usr/local/libexec/pomme")
        #expect(PommeAgentInstall.label == "com.github.weswhet.pomme.agent")
        #expect(PommeAgentInstall.token == "/private/var/db/pomme/agent.token")
    }

    @Test("Recovery agent installs only a request-bound staged executable")
    func recoveryInstall() async throws {
        let root = try recoveryFixture()
        defer { try? FileManager.default.removeItem(at: root.base) }
        let agent = try PommeAgent(
            role: .recovery,
            executableSHA256: root.digest,
            recoveryInstaller: root.installer
        )
        let result = try await agent.perform(.request(
            operation: "agent.install",
            payload: .object([
                "persistentToken": .string(root.persistentToken),
                "requestID": .string(root.request.requestID.uuidString.lowercased()),
                "workspacePath": .string(root.workspace.path),
                "installMode": .string("initial")
            ]),
            requestID: root.request.requestID
        ))
        #expect(result.objectValue?["executableSHA256"]?.stringValue == root.digest)
        #expect(result.objectValue?["capabilities"]?.arrayValue?.compactMap(\.stringValue) == PommeAgent.persistentCapabilities)
        #expect(try Data(contentsOf: root.executable) == root.executableData)
        #expect((try FileManager.default.attributesOfItem(atPath: root.token.path)[.posixPermissions] as? NSNumber)?.intValue == 0o400)
        #expect((try FileManager.default.attributesOfItem(atPath: root.privateDirectory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(!FileManager.default.fileExists(atPath: root.privateDirectory.appendingPathComponent("agent-install.journal").path))
        let definition = try String(contentsOf: root.plist, encoding: .utf8)
        #expect(definition.contains(root.digest))
        #expect(result.objectValue?["token"] == nil)
    }

    @Test("Recovery install safely creates fixed parents missing from a fresh Data volume")
    func recoveryInstallCreatesMissingParents() async throws {
        let root = try recoveryFixture(createTargetParents: false)
        defer { try? FileManager.default.removeItem(at: root.base) }
        let agent = try PommeAgent(
            role: .recovery,
            executableSHA256: root.digest,
            recoveryInstaller: root.installer
        )

        _ = try await agent.perform(.request(
            operation: "agent.install",
            payload: .object([
                "persistentToken": .string(root.persistentToken),
                "requestID": .string(root.request.requestID.uuidString.lowercased()),
                "workspacePath": .string(root.workspace.path),
                "installMode": .string("initial")
            ]),
            requestID: root.request.requestID
        ))

        #expect(FileManager.default.fileExists(atPath: root.executable.path))
        #expect(FileManager.default.fileExists(atPath: root.plist.path))
        #expect(FileManager.default.fileExists(atPath: root.token.path))
        #expect((try FileManager.default.attributesOfItem(
            atPath: root.executable.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test("Recovery installation accepts the existing canonical private workspace")
    func recoveryInstallFromCanonicalPrivateWorkspace() async throws {
        // Arrange: reproduce the literal /private path emitted by the launcher,
        // with real files present (nonexistent paths hide Foundation's aliasing).
        let root = try recoveryFixture(
            createTargetParents: false,
            workspaceParent: URL(fileURLWithPath: "/private/var/tmp", isDirectory: true),
            baseParent: URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
        )
        defer {
            try? FileManager.default.removeItem(at: root.workspace)
            try? FileManager.default.removeItem(at: root.base)
        }
        #expect(root.workspace.path.hasPrefix("/private/var/tmp/pomme-recovery-"))
        let agent = try PommeAgent(
            role: .recovery, executableSHA256: root.digest,
            recoveryInstaller: root.installer
        )

        // Act: run the actual workspace validation and transactional installer,
        // targeting only the isolated fixture's fake Data-volume directory.
        let result = try await agent.perform(.request(
            operation: "agent.install",
            payload: .object([
                "persistentToken": .string(root.persistentToken),
                "requestID": .string(root.request.requestID.uuidString.lowercased()),
                "workspacePath": .string(root.workspace.path),
                "installMode": .string("initial")
            ]),
            requestID: root.request.requestID
        ))

        // Assert: source identity survives validation and installation.
        #expect(result.objectValue?["executableSHA256"]?.stringValue == root.digest)
        #expect(try Data(contentsOf: root.executable) == root.executableData)
        #expect(FileManager.default.fileExists(atPath: root.token.path))
    }

    @Test("Recovery install rejects a digest mismatch without replacing an existing executable")
    func recoveryInstallRollbackOnValidationFailure() async throws {
        let root = try recoveryFixture(manifestDigest: String(repeating: "f", count: 64))
        defer { try? FileManager.default.removeItem(at: root.base) }
        try Data("old".utf8).write(to: root.executable)
        let agent = try PommeAgent(role: .recovery, executableSHA256: root.digest, recoveryInstaller: root.installer)
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(
                operation: "agent.install",
                payload: .object([
                    "persistentToken": .string(root.persistentToken),
                    "requestID": .string(root.request.requestID.uuidString.lowercased()),
                    "workspacePath": .string(root.workspace.path),
                    "installMode": .string("initial")
                ]),
                requestID: root.request.requestID
            ))
        }
        #expect(try Data(contentsOf: root.executable) == Data("old".utf8))
    }

    @Test("Recovery workspace proof rejects symlink components and unsafe modes")
    func recoveryWorkspaceProofRejectsSymlinksAndUnsafeModes() throws {
        // Arrange: no real VM, root directory, or credential is used.
        let root = try recoveryFixture()
        defer { try? FileManager.default.removeItem(at: root.base) }
        try PommeAgentFileTransaction.verifyRecoveryWorkspaceDirectory(
            root.workspace, owner: geteuid(), group: getegid()
        )
        let leafAlias = root.base.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: leafAlias, withDestinationURL: root.workspace)
        let parentAlias = root.base.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: root.base)

        // Act/Assert: neither a leaf nor an ancestor link can become a proof.
        for alias in [leafAlias, parentAlias.appendingPathComponent(root.workspace.lastPathComponent)] {
            #expect(throws: PommeAgentProtocol.Error.self) {
                try PommeAgentFileTransaction.verifyRecoveryWorkspaceDirectory(
                    alias, owner: geteuid(), group: getegid()
                )
            }
        }
        try #require(chmod(root.workspace.path, 0o755) == 0)
        #expect(throws: PommeAgentProtocol.Error.self) {
            try PommeAgentFileTransaction.verifyRecoveryWorkspaceDirectory(
                root.workspace, owner: geteuid(), group: getegid()
            )
        }
        #expect(try Data(contentsOf: root.workspace.appendingPathComponent(
            PommeRecoveryArtifactNames.executable
        )) == root.executableData)
    }

    @Test("Recovery role cannot run the persistent command surface")
    func recoveryRoleIsClosed() async throws {
        let agent = try PommeAgent(role: .recovery, executableSHA256: String(repeating: "a", count: 64))
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "process.start", payload: .object(["path": .string("/bin/true"), "arguments": .array([])])))
        }
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(
                operation: "amfi.normal.disable",
                payload: .object(["volumeGroupUUID": .string(UUID().uuidString.lowercased())])
            ))
        }
    }
}

private struct RecoveryFixture {
    let base: URL
    let workspace: URL
    let request: PommeRecoverySessionRequest
    let digest: String
    let executableData: Data
    let persistentToken: String
    let executable: URL
    let token: URL
    let plist: URL
    let privateDirectory: URL
    let installer: PommeAgentRecoveryInstaller
}

private func recoveryFixture(
    manifestDigest: String? = nil,
    createTargetParents: Bool = true,
    workspaceParent: URL? = nil,
    baseParent: URL? = nil
) throws -> RecoveryFixture {
    let base = (baseParent ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
    let requestID = UUID()
    try FileManager.default.createDirectory(
        at: base, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let workspace = (workspaceParent ?? base).appendingPathComponent("pomme-recovery-\(requestID.uuidString.lowercased())")
    try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    guard chown(workspace.path, geteuid(), getegid()) == 0 else {
        throw CocoaError(.fileWriteNoPermission)
    }
    let executableData = Data("signed-recovery-agent".utf8)
    let digest = SHA256.hash(data: executableData).map { String(format: "%02x", $0) }.joined()
    let persistentToken = String(repeating: "9", count: 64)
    let credential = try PommeRecoveryCredential(secret: Data(repeating: 7, count: 32), expiresAt: Date().addingTimeInterval(60))
    let request = try PommeRecoverySessionRequest(
        requestID: requestID,
        vmUUID: UUID(),
        operation: .installAgent,
        expiresAt: Date().addingTimeInterval(60),
        executableSHA256: manifestDigest ?? digest,
        credential: credential
    )
    try executableData.write(to: workspace.appendingPathComponent(PommeRecoveryArtifactNames.executable))
    try JSONEncoder().encode(request).write(to: workspace.appendingPathComponent(PommeRecoveryArtifactNames.request))
    let privateDirectory = base.appendingPathComponent("private")
    let executable = base.appendingPathComponent("libexec/pomme")
    let plist = base.appendingPathComponent("LaunchDaemons/pomme.plist")
    if createTargetParents {
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let token = privateDirectory.appendingPathComponent("agent.token")
    let owner = geteuid()
    let configuration = PommeAgentRecoveryInstaller.Configuration(
        paths: .init(executable: executable, token: token, plist: plist, privateDirectory: privateDirectory),
        expectedOwner: owner,
        expectedGroup: getegid(),
        requiresRoot: false,
        resolveTargetDataRoot: { uuid in
            guard uuid == nil else { throw PommeAgentOperationError.invalid }
            return (
                base,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
            )
        },
        validateTargetDataRoot: { _ in true },
        validateGuestWorkspace: { _, _ in true }
    )
    return .init(
        base: base, workspace: workspace, request: request, digest: digest,
        executableData: executableData, persistentToken: persistentToken, executable: executable, token: token,
        plist: plist, privateDirectory: privateDirectory,
        installer: .init(configuration: configuration)
    )
}
