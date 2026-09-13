import Darwin
import Foundation
import Testing

@Suite("Pomme agent daemon framing")
struct PommeAgentDaemonTests {
    @Test("socketpair admission is newline framed and bounded before allocation")
    func socketpairAdmission() async throws {
        var sockets: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { _ = Darwin.close(sockets[0]); _ = Darwin.close(sockets[1]) }
        let token = String(repeating: "a", count: 64)
        let connection = try PommeAgentConnection(token: token, lifetime: .persistent)
        let agent = try PommeAgent(role: .persistent, executableSHA256: token)
        let serverDescriptor = sockets[1]
        async let serving: Void = PommeAgentDaemon.serve(
            descriptor: serverDescriptor,
            connection: connection,
            agent: agent,
            allowedOperation: nil
        )
        let authenticate = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object(["challenge": .string(String(repeating: "b", count: 64))]))
        let health = PommeAgentProtocol.Envelope.request(operation: "agent.health")
        let bytes = try PommeAgentProtocol.encode(authenticate) + PommeAgentProtocol.encode(health)
        #expect(bytes.withUnsafeBytes { Darwin.write(sockets[0], $0.baseAddress, $0.count) } == bytes.count)
        _ = shutdown(sockets[0], SHUT_WR)
        // A stream read may return either response independently or both
        // coalesced.  Read until both newline-delimited responses arrive;
        // framing must not depend on packet boundaries.
        var reply = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while reply.split(separator: 0x0A).count < 2 {
            let count = scratch.withUnsafeMutableBytes { Darwin.read(sockets[0], $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            reply.append(contentsOf: scratch.prefix(Int(count)))
        }
        let lines = reply.split(separator: 0x0A)
        #expect(lines.count == 2)
        guard lines.count >= 2 else { return }
        #expect(try PommeAgentProtocol.decode(Data(lines[0])).requestID == authenticate.requestID)
        #expect(try PommeAgentProtocol.decode(Data(lines[1])).requestID == health.requestID)
        _ = await serving
    }

    @Test("daemon grammar constrains normal and bounded Recovery ports")
    func arguments() throws {
        let digest = String(repeating: "a", count: 64)
        let normal = try PommeAgentDaemon.parse(arguments: ["--pomme-agent", "505051", "--token-file", "/private/token", "--expected-sha256", digest])
        #expect(normal.role == .persistent)
        let vmID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let sessionID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        #expect(throws: Error.self) { _ = try PommeAgentDaemon.parse(arguments: ["--pomme-agent", "505052", "--token-file", "/private/token", "--expected-sha256", digest]) }
        #expect(throws: Error.self) { _ = try PommeAgentDaemon.parse(arguments: ["--pomme-agent", "505052", "--token-file", "/private/token", "--expected-sha256", digest, "--role", "recovery", "--one-shot-expiry", "9999999999", "--vm-id", vmID, "--session-id", sessionID, "--operation", "sip.disable"]) }
        let recovery = try PommeAgentDaemon.parse(arguments: ["--pomme-agent", "505052", "--token-file", "/private/token", "--expected-sha256", digest, "--role", "recovery", "--one-shot-expiry", "9999999999", "--vm-id", vmID, "--session-id", sessionID, "--operation", "agent.install", "--request-file", "/private/request.json"])
        #expect(recovery.role == .recovery)
        #expect(recovery.vmBinding == vmID)
        #expect(recovery.sessionBinding == sessionID)
        #expect(recovery.allowedOperation == "agent.install")
        let security = try PommeAgentDaemon.parse(arguments: ["--pomme-agent", "505053", "--token-file", "/private/token", "--expected-sha256", digest, "--role", "recovery", "--one-shot-expiry", "9999999999", "--vm-id", vmID, "--session-id", sessionID, "--operation", "sip.disable", "--request-file", "/private/request.json"])
        #expect(security.allowedOperation == "sip.disable")
        let terminal = try PommeAgentDaemon.parse(arguments: ["--pomme-agent", "505053", "--token-file", "/private/token", "--expected-sha256", digest, "--role", "recovery", "--one-shot-expiry", "9999999999", "--vm-id", vmID, "--session-id", sessionID, "--operation", "terminal.session", "--request-file", "/private/request.json"])
        #expect(terminal.allowedOperation == "terminal.session")
        #expect(terminal.terminalAuthority)
        #expect(throws: Error.self) { _ = try PommeAgentDaemon.parse(arguments: ["--pomme-agent", "505053", "--token-file", "/private/token", "--expected-sha256", digest, "--role", "recovery", "--one-shot-expiry", "9999999999", "--vm-id", vmID, "--session-id", sessionID, "--operation", "agent.install", "--request-file", "/private/request.json"]) }
        #expect(throws: Error.self) { _ = try PommeAgentDaemon.parse(arguments: ["--pomme-agent", "505052", "--token-file", "/private/token", "--expected-sha256", digest, "--role", "recovery", "--one-shot-expiry", "9999999999", "--vm-id", vmID.uppercased(), "--session-id", sessionID, "--operation", "agent.install", "--request-file", "/private/request.json"]) }
    }

    @Test("Recovery token is consumed through its descriptor")
    func consumesToken() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-daemon-token-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("token")
        let token = String(repeating: "a", count: 64)
        guard FileManager.default.createFile(atPath: path.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o400]) else { throw CocoaError(.fileWriteUnknown) }
        let read = try PommeAgentDaemon.readToken(at: path.path, consume: true, expectedOwner: geteuid(), expectedGroup: getegid())
        #expect(read == token)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(throws: Error.self) { _ = try PommeAgentDaemon.readToken(at: path.path, consume: true, expectedOwner: geteuid(), expectedGroup: getegid()) }
    }

    @Test("Recovery workspace cleanup removes only a validated request directory")
    func recoveryWorkspaceCleanup() throws {
        let requestID = UUID()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-recovery-cleanup-\(UUID().uuidString)")
        let workspace = parent.appendingPathComponent(
            "pomme-recovery-\(requestID.uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let artifacts: [(String, Int)] = [
            (PommeRecoveryArtifactNames.executable, 0o555),
            (PommeRecoveryArtifactNames.request, 0o400),
            (PommeRecoveryArtifactNames.credential, 0o400)
        ]
        for (name, mode) in artifacts {
            let url = workspace.appendingPathComponent(name)
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(name.utf8),
                attributes: [.posixPermissions: mode]
            ) else { throw CocoaError(.fileWriteUnknown) }
        }

        try PommeAgentFileTransaction.removeRecoveryWorkspace(
            workspace,
            requestID: requestID,
            owner: geteuid(),
            group: getegid()
        )
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }

    @Test("Recovery workspace cleanup rejects an unexpected entry before mutation")
    func recoveryWorkspaceCleanupRejectsUnexpectedEntry() throws {
        let requestID = UUID()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-recovery-cleanup-\(UUID().uuidString)")
        let workspace = parent.appendingPathComponent(
            "pomme-recovery-\(requestID.uuidString.lowercased())"
        )
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let executable = workspace.appendingPathComponent(PommeRecoveryArtifactNames.executable)
        let unexpected = workspace.appendingPathComponent("unexpected")
        #expect(FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("agent".utf8),
            attributes: [.posixPermissions: 0o555]
        ))
        #expect(FileManager.default.createFile(
            atPath: unexpected.path,
            contents: Data("stop".utf8),
            attributes: [.posixPermissions: 0o400]
        ))

        #expect(throws: Error.self) {
            try PommeAgentFileTransaction.removeRecoveryWorkspace(
                workspace,
                requestID: requestID,
                owner: geteuid(),
                group: getegid()
            )
        }
        #expect(FileManager.default.fileExists(atPath: executable.path))
        #expect(FileManager.default.fileExists(atPath: unexpected.path))
    }

    @Test("Recovery daemon removes its exact workspace after executable validation fails")
    func daemonCleansWorkspaceAfterDigestFailure() throws {
        let fixture = try makeRecoveryRunWorkspace(requestData: Data("not-yet-validated".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let cleanups = DaemonCleanupRecorder()
        let arguments = recoveryArguments(
            requestID: fixture.requestID,
            workspace: fixture.workspace,
            expectedDigest: String(repeating: "a", count: 64)
        )

        let exit = PommeAgentDaemon.run(
            arguments: arguments,
            executablePath: fixture.executable.path,
            recoveryOwner: geteuid(),
            recoveryGroup: fixture.group,
            recoveryCleanupFactory: { _, _, _, _ in
                { cleanups.increment() }
            }
        )

        #expect(exit == PommeAgentDaemon.Exit.integrity.rawValue)
        #expect(cleanups.value == 1)
    }

    @Test("default Recovery cleanup accepts an existing private workspace before digest validation")
    func defaultCleanupCanonicalPrivateWorkspaceReachesDigestValidation() throws {
        // Given: an actual existing /private/var/tmp workspace. On this host,
        // standardizedFileURL resolves the /private alias to /var/tmp for
        // existing paths, while the launcher's request-bound argument remains
        // the required /private/var/tmp spelling. The credential is removed
        // before launching so this regression does not read credentials or
        // attempt a host connection.
        let fixture = try makeRecoveryRunWorkspace(requestData: Data("not-yet-validated".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try FileManager.default.removeItem(
            at: fixture.workspace.appendingPathComponent(PommeRecoveryArtifactNames.credential)
        )

        // When: the production run path uses its default cleanup factory with
        // a deliberately incorrect digest.
        let exit = PommeAgentDaemon.run(
            arguments: recoveryArguments(
                requestID: fixture.requestID,
                workspace: fixture.workspace,
                expectedDigest: String(repeating: "0", count: 64)
            ),
            executablePath: fixture.executable.path,
            recoveryOwner: geteuid(),
            recoveryGroup: fixture.group
        )

        // Then: canonical path validation must pass first, allowing the
        // digest guard to return integrity (65), and the exact workspace must
        // be cleaned up without opening a credential or socket.
        #expect(exit == PommeAgentDaemon.Exit.integrity.rawValue)
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.path))
    }

    @Test("default Recovery cleanup rejects lexical traversal before mutation")
    func defaultCleanupRejectsLexicalTraversalBeforeMutation() throws {
        // Given: a valid request-bound workspace, but a request path with a
        // dot-component that resolves to the same file lexically.
        let fixture = try makeRecoveryRunWorkspace(requestData: Data("not-yet-validated".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        var arguments = recoveryArguments(
            requestID: fixture.requestID,
            workspace: fixture.workspace,
            expectedDigest: String(repeating: "0", count: 64)
        )
        guard let requestFlag = arguments.firstIndex(of: "--request-file") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        arguments[requestFlag + 1] = "\(fixture.workspace.path)/../\(fixture.workspace.lastPathComponent)/\(PommeRecoveryArtifactNames.request)"

        // When: the daemon is invoked through its production cleanup seam.
        let exit = PommeAgentDaemon.run(
            arguments: arguments,
            executablePath: fixture.executable.path,
            recoveryOwner: geteuid(),
            recoveryGroup: fixture.group
        )

        // Then: the lexical alias is rejected before cleanup, digest, token,
        // or socket work, and every staged artifact remains in place.
        #expect(exit == PommeAgentDaemon.Exit.invalidArguments.rawValue)
        #expect(FileManager.default.fileExists(atPath: fixture.workspace.path))
        #expect(FileManager.default.fileExists(atPath: fixture.executable.path))
        #expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent(PommeRecoveryArtifactNames.request).path))
        #expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent(PommeRecoveryArtifactNames.credential).path))
    }

    @Test("default Recovery cleanup rejects a symlink alias before mutation")
    func defaultCleanupRejectsSymlinkAliasBeforeMutation() throws {
        // Given: a valid request-bound workspace and a separate symlink to its
        // executable. The alias points at the right inode but is not the exact
        // request-bound pathname.
        let fixture = try makeRecoveryRunWorkspace(requestData: Data("not-yet-validated".utf8))
        let alias = fixture.workspace.deletingLastPathComponent()
            .appendingPathComponent("pomme-recovery-executable-alias-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: fixture.workspace)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.executable)

        // When: the daemon is invoked with the symlink path as its executable.
        let exit = PommeAgentDaemon.run(
            arguments: recoveryArguments(
                requestID: fixture.requestID,
                workspace: fixture.workspace,
                expectedDigest: String(repeating: "0", count: 64)
            ),
            executablePath: alias.path,
            recoveryOwner: geteuid(),
            recoveryGroup: fixture.group
        )

        // Then: the alias is rejected before any cleanup mutation, and the
        // original workspace plus the alias are still present.
        #expect(exit == PommeAgentDaemon.Exit.invalidArguments.rawValue)
        #expect(FileManager.default.fileExists(atPath: fixture.workspace.path))
        #expect(FileManager.default.fileExists(atPath: fixture.executable.path))
        #expect(FileManager.default.fileExists(atPath: alias.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == fixture.executable.path)
    }

    @Test("Recovery daemon removes its exact workspace after request validation fails")
    func daemonCleansWorkspaceAfterRequestFailure() throws {
        let fixture = try makeRecoveryRunWorkspace(requestData: Data("invalid-json".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let digest = try PommeAgentFileTransaction.sha256(fixture.executable)
        let cleanups = DaemonCleanupRecorder()
        let arguments = recoveryArguments(
            requestID: fixture.requestID,
            workspace: fixture.workspace,
            expectedDigest: digest
        )
        let exit = PommeAgentDaemon.run(
            arguments: arguments,
            executablePath: fixture.executable.path,
            recoveryOwner: geteuid(),
            recoveryGroup: fixture.group,
            recoveryCleanupFactory: { _, _, _, _ in
                { cleanups.increment() }
            }
        )

        #expect(exit == PommeAgentDaemon.Exit.invalidArguments.rawValue)
        #expect(cleanups.value == 1)
    }

    @Test("Recovery daemon closes after one allowlisted operation")
    func oneShotOperation() async throws {
        var sockets: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { _ = Darwin.close(sockets[0]); _ = Darwin.close(sockets[1]) }
        let token = String(repeating: "a", count: 64)
        let connection = try PommeAgentConnection(token: token, lifetime: .oneShot, expiresAt: Date(timeIntervalSinceNow: 60), vmBinding: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", sessionBinding: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let agent = try PommeAgent(role: .recovery, executableSHA256: token)
        let serverDescriptor = sockets[1]
        async let serving: Void = PommeAgentDaemon.serve(
            descriptor: serverDescriptor,
            connection: connection,
            agent: agent,
            allowedOperation: "agent.install"
        )
        let auth = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object([
            "challenge": .string(String(repeating: "b", count: 64)),
            "vmID": .string("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            "sessionID": .string("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        ]))
        let operation = PommeAgentProtocol.Envelope.request(operation: "agent.install", payload: .object([:]))
        let replay = PommeAgentProtocol.Envelope.request(operation: "agent.install", payload: .object([:]))
        let bytes = try PommeAgentProtocol.encode(auth) + PommeAgentProtocol.encode(operation) + PommeAgentProtocol.encode(replay)
        #expect(bytes.withUnsafeBytes { Darwin.write(sockets[0], $0.baseAddress, $0.count) } == bytes.count)

        var reply = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while reply.split(separator: 0x0A).count < 2 {
            let count = scratch.withUnsafeMutableBytes { Darwin.read(sockets[0], $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            reply.append(contentsOf: scratch.prefix(Int(count)))
        }
        let lines = reply.split(separator: 0x0A)
        #expect(lines.count == 2)
        #expect(try PommeAgentProtocol.decode(Data(lines[0])).ok == true)
        #expect(try PommeAgentProtocol.decode(Data(lines[1])).requestID == operation.requestID)
        _ = await serving
    }

    private func makeRecoveryRunWorkspace(
        requestData: Data
    ) throws -> (requestID: UUID, workspace: URL, executable: URL, group: gid_t) {
        let requestID = UUID()
        let workspace = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent(
                "pomme-recovery-\(requestID.uuidString.lowercased())",
                isDirectory: true
            )
        guard !FileManager.default.fileExists(atPath: workspace.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let executable = workspace.appendingPathComponent(PommeRecoveryArtifactNames.executable)
        let request = workspace.appendingPathComponent(PommeRecoveryArtifactNames.request)
        let credential = workspace.appendingPathComponent(PommeRecoveryArtifactNames.credential)
        guard FileManager.default.createFile(
            atPath: executable.path,
            contents: Data("pomme-test-executable".utf8),
            attributes: [.posixPermissions: 0o555]
        ), FileManager.default.createFile(
            atPath: request.path,
            contents: requestData,
            attributes: [.posixPermissions: 0o400]
        ), FileManager.default.createFile(
            atPath: credential.path,
            contents: Data(String(repeating: "a", count: 64).utf8),
            attributes: [.posixPermissions: 0o400]
        ) else { throw CocoaError(.fileWriteUnknown) }
        guard chmod(workspace.path, 0o700) == 0,
              chmod(executable.path, 0o555) == 0,
              chmod(request.path, 0o400) == 0,
              chmod(credential.path, 0o400) == 0
        else { throw CocoaError(.fileWriteNoPermission) }
        var credentialInfo = stat()
        guard lstat(credential.path, &credentialInfo) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return (requestID, workspace, executable, credentialInfo.st_gid)
    }

    private func recoveryArguments(
        requestID: UUID,
        workspace: URL,
        expectedDigest: String
    ) -> [String] {
        [
            "--pomme-agent", String(Constants.pommeRecoverySessionPort),
            "--token-file", workspace.appendingPathComponent(PommeRecoveryArtifactNames.credential).path,
            "--expected-sha256", expectedDigest,
            "--role", "recovery",
            "--one-shot-expiry", String(Date().addingTimeInterval(600).timeIntervalSince1970),
            "--vm-id", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "--session-id", requestID.uuidString.lowercased(),
            "--operation", PommeRecoveryOperation.installAgent.wireName,
            "--request-file", workspace.appendingPathComponent(PommeRecoveryArtifactNames.request).path,
        ]
    }
}

private final class DaemonCleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
