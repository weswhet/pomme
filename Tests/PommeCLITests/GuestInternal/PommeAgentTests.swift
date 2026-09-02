import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Pomme persistent agent")
struct PommeAgentTests {
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
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64), remoteLoginTransaction: { enabled in #expect(enabled) })
        let value = try await agent.perform(.request(operation: "remoteLogin.set", payload: .object(["enabled": .bool(true)])))
        #expect(value.objectValue?["enabled"] == .bool(true))
    }

    @Test("An unresolved activation journal survives restart and fails closed")
    func restartGate() async throws {
        let journal = try PommeAgentUpdateJournal(phase: .activationPending, sourceSHA256: String(repeating: "a", count: 64), targetSHA256: String(repeating: "b", count: 64), targetBytes: 1)
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64), recoveredJournal: journal)
        await #expect(throws: PommeAgentOperationError.self) { _ = try await agent.perform(.request(operation: "agent.health")) }
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

    @Test("Recovery role cannot run the persistent command surface")
    func recoveryRoleIsClosed() async throws {
        let agent = try PommeAgent(role: .recovery, executableSHA256: String(repeating: "a", count: 64))
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "process.start", payload: .object(["path": .string("/bin/true"), "arguments": .array([])])))
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
    createTargetParents: Bool = true
) throws -> RecoveryFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let requestID = UUID()
    let workspace = base.appendingPathComponent("pomme-recovery-\(requestID.uuidString.lowercased())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
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
