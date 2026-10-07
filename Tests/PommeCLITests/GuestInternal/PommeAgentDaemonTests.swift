import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing

@Suite("Pomme agent daemon framing")
struct PommeAgentDaemonTests {
    @Test("persistent connection retries preserve the daemon while Recovery fails immediately")
    func buddyConnectionRetries() throws {
        enum Unavailable: Error { case listener }
        var connections = 0
        var pauses = 0
        let descriptor = try PommeAgentDaemon.connectForRole(role: .persistent, port: 505051, connect: { _ in
            connections += 1
            if connections < 3 { throw Unavailable.listener }
            return 42
        }, pause: { pauses += 1 })
        #expect(descriptor == 42)
        #expect(connections == 3)
        #expect(pauses == 2)
        connections = 0
        pauses = 0
        #expect(throws: Unavailable.self) {
            try PommeAgentDaemon.connectForRole(role: .recovery, port: 505052, connect: { _ in
                connections += 1
                throw Unavailable.listener
            }, pause: { pauses += 1 })
        }
        #expect(connections == 1)
        #expect(pauses == 0)
    }

    @Test("Buddy status requires authentication and Recovery excludes it")
    func buddyStatusAdmission() async throws {
        let token = String(repeating: "a", count: 64)
        let agent = try PommeAgent(role: .persistent, executableSHA256: token)
        let connection = try PommeAgentConnection(token: token, lifetime: .persistent)
        let status = PommeAgentProtocol.Envelope.request(operation: PommeAgent.buddyPreferencesStatusOperation)
        let entered = Mutex(false)
        let denied = await connection.receive(Data(try PommeAgentProtocol.encode(status).dropLast())) { request in
            entered.withLock { $0 = true }
            return try await agent.performAsynchronously(request)
        }
        #expect(!entered.withLock { $0 })
        #expect(try PommeAgentProtocol.decode(Data(denied.dropLast())).error?.code == "authentication-required")
        let authenticate = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object([
            "challenge": .string(String(repeating: "b", count: 64))
        ]))
        _ = await connection.receive(Data(try PommeAgentProtocol.encode(authenticate).dropLast())) { request in
            try await agent.performAsynchronously(request)
        }
        let admitted = await connection.receive(Data(try PommeAgentProtocol.encode(
            .request(operation: PommeAgent.buddyPreferencesStatusOperation)
        ).dropLast())) { request in
            try await agent.performAsynchronously(request)
        }
        #expect(try PommeAgentProtocol.decode(Data(admitted.dropLast())).ok == true)
        #expect(try PommeAgentProtocol.decode(Data(admitted.dropLast())).result == .object(["initializing": .bool(true)]))
        #expect(try await agent.performAsynchronously(status) == .object(["initializing": .bool(true)]))
        #expect(PommeAgent.persistentCapabilities.contains(PommeAgent.buddyPreferencesStatusOperation))
        #expect(!PommeAgent.recoveryCapabilities.contains(PommeAgent.buddyPreferencesStatusOperation))
        #expect(!PommeAgent.recoveryTerminalCapabilities.contains(PommeAgent.buddyPreferencesStatusOperation))
        let recovery = try PommeAgent(role: .recovery, executableSHA256: token)
        await #expect(throws: PommeAgentOperationError.self) {
            try await recovery.performAsynchronously(status)
        }
        let engine = PommeBuddyPreferencesMaintenance()
        #expect(PommeAgentDaemon.startBuddyMaintenance(role: .recovery, maintenance: engine) == nil)
        #expect(await engine.status() == nil)
    }

    @Test("authenticated transport stays responsive during Buddy waiting and running", arguments: [false, true])
    func buddyTransportRemainsResponsive(running: Bool) async throws {
        let reachedStage = Mutex(false)
        let stored = Mutex<[String: PommeBuddyPreferenceValue]>([:])
        let owner = PommeBuddyPreferencesOwner(account: "pomme", uid: 501,
            generatedUID: UUID().uuidString, homeDirectory: "/Users/pomme")
        let engine = PommeBuddyPreferencesMaintenance(dependencies: .init(
            bootSessionUUID: { "11111111-1111-1111-1111-111111111111" },
            owner: { running ? owner : nil }, homeExists: { _ in true }, readPreference: { _, _, key in stored.withLock { $0[key] } },
            writePreference: { _, _, key, value in
                stored.withLock { $0[key] = value }
                reachedStage.withLock { $0 = true }
            },
            command: { _, arguments in
                .init(status: 0, stdout: arguments == ["-productVersion"] ? "27.0" : "26A428", stderr: "")
            }, load: { nil }, save: { _ in }, sleep: {
                reachedStage.withLock { $0 = true }
                try await Task.sleep(for: .seconds(60))
            }
        ))
        let maintenance = try #require(PommeAgentDaemon.startBuddyMaintenance(role: .persistent, maintenance: engine))
        defer { maintenance.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !reachedStage.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard reachedStage.withLock({ $0 }) else {
            maintenance.cancel()
            await maintenance.value
            Issue.record("Maintenance did not reach its suspended stage")
            return
        }
        let token = String(repeating: "a", count: 64)
        let agent = try PommeAgent(role: .persistent, executableSHA256: token, buddyPreferences: engine)
        let connection = try PommeAgentConnection(token: token, lifetime: .persistent)
        for operation in ["authenticate", "agent.health", PommeAgent.buddyPreferencesStatusOperation] {
            let request = PommeAgentProtocol.Envelope.request(operation: operation,
                payload: operation == "authenticate"
                    ? .object(["challenge": .string(String(repeating: "b", count: 64))]) : .object([:]))
            let reply = await connection.receive(Data(try PommeAgentProtocol.encode(request).dropLast())) {
                try await agent.performAsynchronously($0)
            }
            let envelope = try PommeAgentProtocol.decode(Data(reply.dropLast()))
            #expect(envelope.ok == true)
            if operation == PommeAgent.buddyPreferencesStatusOperation {
                // Preference writes are brief native calls, so a running
                // attempt may already have finished when status is read.
                let outcome = envelope.result?.objectValue?["outcome"]
                #expect(running ? [.string("running"), .string("succeeded")].contains(outcome)
                                : outcome == .string("waiting"))
            }
        }
        maintenance.cancel()
        await maintenance.value
    }

    @Test("socketpair admission is newline framed and bounded before allocation")
    func socketpairAdmission() async throws {
        try await runSocketpairAdmission()
    }

    @Test("socketpair peer budget starts after delayed serving admission")
    func delayedSocketpairAdmission() async throws {
        try await runSocketpairAdmission(readTimeout: .seconds(1), beforeServing: {
            try? await Task.sleep(for: .milliseconds(1_200))
        })
    }

    private func runSocketpairAdmission(
        readTimeout: Duration = .seconds(5),
        setupTimeout: Duration = .seconds(30),
        beforeServing: (@Sendable () async -> Void)? = nil
    ) async throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { _ = Darwin.close(sockets[0]); _ = Darwin.close(sockets[1]) }
        let token = String(repeating: "a", count: 64)
        let connection = try PommeAgentConnection(token: token, lifetime: .persistent)
        let agent = try PommeAgent(role: .persistent, executableSHA256: token)
        let authenticate = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object(["challenge": .string(String(repeating: "b", count: 64))]))
        let health = PommeAgentProtocol.Envelope.request(operation: "agent.health")
        let bytes = try PommeAgentProtocol.encode(authenticate) + PommeAgentProtocol.encode(health)
        let serverDescriptor = sockets[1]
        let admission = DaemonServingAdmission()
        let serving = Task {
            await beforeServing?()
            guard !Task.isCancelled else {
                admission.resolve(.failure(CancellationError()))
                return
            }
            admission.resolve(.success(()))
            await PommeAgentDaemon.serve(
                descriptor: serverDescriptor,
                connection: connection,
                agent: agent,
                allowedOperation: nil
            )
        }
        #expect(bytes.withUnsafeBytes { Darwin.write(sockets[0], $0.baseAddress, $0.count) } == bytes.count)
        _ = shutdown(sockets[0], SHUT_WR)
        // Fixture setup has its own bound. The five-second peer budget starts
        // only once the actual serving task enters, not while it is queued.
        do {
            try await admission.wait(timeout: setupTimeout)
            try Task.checkCancellation()
        } catch {
            _ = shutdown(sockets[0], SHUT_RDWR)
            _ = shutdown(sockets[1], SHUT_RDWR)
            serving.cancel()
            await serving.value
            throw error
        }
        // A stream read may return either response independently or both
        // coalesced.  Read until both newline-delimited responses arrive;
        // framing must not depend on packet boundaries.
        let result = await DaemonPeerReader.read(descriptor: sockets[0], timeout: readTimeout)
        let completedNaturally = await DaemonPeerReader.finish(
            serving: serving, result: result, sockets: sockets
        )
        let reply = try result.get()
        #expect(completedNaturally)
        let lines = reply.split(separator: 0x0A)
        #expect(lines.count == 2)
        try #require(lines.count >= 2)
        #expect(try PommeAgentProtocol.decode(Data(lines[0])).requestID == authenticate.requestID)
        #expect(try PommeAgentProtocol.decode(Data(lines[1])).requestID == health.requestID)
    }

    @Test("socketpair admission timeout cancels and joins the setup task")
    func socketpairAdmissionTimeout() async throws {
        let hookReturned = Mutex(false)
        do {
            try await runSocketpairAdmission(setupTimeout: .milliseconds(10), beforeServing: {
                defer { hookReturned.withLock { $0 = true } }
                try? await Task.sleep(for: .seconds(60))
            })
            Issue.record("Expected bounded setup admission failure")
        } catch DaemonServingAdmission.Failure.timedOut {}
        #expect(hookReturned.withLock { $0 })
    }

    @Test("socketpair admission caller cancellation joins the setup task")
    func socketpairAdmissionCancellation() async throws {
        let hookEntered = DaemonServingAdmission()
        let hookReturned = Mutex(false)
        let caller = Task {
            try await runSocketpairAdmission(beforeServing: {
                defer { hookReturned.withLock { $0 = true } }
                hookEntered.resolve(.success(()))
                try? await Task.sleep(for: .seconds(60))
            })
        }
        do {
            try await hookEntered.wait(timeout: .seconds(30))
        } catch {
            caller.cancel()
            _ = try? await caller.value
            throw error
        }
        caller.cancel()
        do {
            try await caller.value
            Issue.record("Expected caller cancellation during setup")
        } catch is CancellationError {}
        #expect(hookReturned.withLock { $0 })
    }

    @Test("serving admission before waiting survives losing timeout resolution")
    func servingAdmissionBeforeWait() async throws {
        let admission = DaemonServingAdmission()
        admission.resolve(.success(()))
        admission.resolve(.failure(DaemonServingAdmission.Failure.timedOut))
        try await admission.wait(timeout: .zero)
        try await admission.wait(timeout: .zero)
    }

    @Test("serving admission failure stays terminal after a late entry", arguments: [false, true])
    func servingAdmissionTerminalFailure(cancelled: Bool) async throws {
        let admission = DaemonServingAdmission()
        if cancelled { admission.resolve(.failure(CancellationError())) }
        // The timeout case exercises the actual watchdog, not an injected
        // timeout result. A late entry cannot overwrite either terminal error.
        for attempt in 0..<2 {
            if attempt == 1 { admission.resolve(.success(())) }
            do {
                try await admission.wait(timeout: .zero)
                Issue.record("Late entry must not replace terminal admission failure")
            } catch is CancellationError {
                #expect(cancelled)
            } catch DaemonServingAdmission.Failure.timedOut {
                #expect(!cancelled)
            }
        }
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

    @Test("Recovery agent hashes its executable without consulting its CDHash")
    func recoveryAgentIgnoresCodeIdentity() throws {
        let fixture = try makeRecoveryRunWorkspace(requestData: Data("not-yet-validated".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let identityQueries = DaemonCleanupRecorder()

        let exit = PommeAgentDaemon.run(
            arguments: recoveryArguments(
                requestID: fixture.requestID,
                workspace: fixture.workspace,
                expectedDigest: String(repeating: "a", count: 64)
            ),
            executablePath: fixture.executable.path,
            recoveryOwner: geteuid(),
            recoveryGroup: fixture.group,
            recoveryCleanupFactory: { _, _, _, _ in {} },
            codeIdentity: { identityQueries.increment(); return Self.enforcedIdentity }
        )

        #expect(exit == PommeAgentDaemon.Exit.integrity.rawValue)
        #expect(identityQueries.value == 0)
    }

    @Test("CDHash identity requires a valid, enforced, hardened, non-ad hoc signature")
    func codeIdentityEnforcement() {
        // The status that the kernel reported for the agent in a macOS 27 guest.
        #expect(PommeAgentCodeIdentity(status: 0x2201_1311, cdhash: Self.cdhash).isEnforced)
        let flag = PommeAgentCodeIdentity.self
        for missing in [flag.valid, flag.hard, flag.kill, flag.enforcement, flag.runtime, flag.signed] {
            #expect(!PommeAgentCodeIdentity(status: 0x2201_1311 & ~missing, cdhash: Self.cdhash).isEnforced)
        }
        for forbidden in [flag.adhoc, flag.getTaskAllow, flag.invalidAllowed, flag.linkerSigned, flag.debugged] {
            #expect(!PommeAgentCodeIdentity(status: 0x2201_1311 | forbidden, cdhash: Self.cdhash).isEnforced)
        }
    }

    @Test("verified code record round-trips and rejects unsafe or malformed files")
    func verifiedCodeRecordFile() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("agent-verified-code")
        let record = try #require(PommeAgentVerifiedCodeRecord(sha256: Self.digest, cdhash: Self.cdhash))

        #expect(PommeAgentVerifiedCodeRecord.read(at: url, expectedOwner: geteuid()) == nil)
        try record.write(to: url)
        #expect(PommeAgentVerifiedCodeRecord.read(at: url, expectedOwner: geteuid()) == record)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(PommeAgentVerifiedCodeRecord.read(at: url, expectedOwner: geteuid() + 1) == nil)
        chmod(url.path, 0o644)
        #expect(PommeAgentVerifiedCodeRecord.read(at: url, expectedOwner: geteuid()) == nil)

        let link = directory.appendingPathComponent("link")
        chmod(url.path, 0o600)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(PommeAgentVerifiedCodeRecord.read(at: link, expectedOwner: geteuid()) == nil)

        #expect(PommeAgentVerifiedCodeRecord(sha256: Self.digest.uppercased(), cdhash: Self.cdhash) == nil)
        #expect(PommeAgentVerifiedCodeRecord(sha256: Self.digest, cdhash: String(Self.cdhash.dropLast())) == nil)
        // Same length as a valid record, so only the format rejects it.
        try Data("\(Self.digest)  \(Self.cdhash.dropLast())\n".utf8).write(to: url)
        chmod(url.path, 0o600)
        #expect(PommeAgentVerifiedCodeRecord.read(at: url, expectedOwner: geteuid()) == nil)
    }

    @Test("persistent agent skips hashing when an enforced CDHash matches its verified record")
    func persistentAgentAcceptsVerifiedCDHash() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordURL = directory.appendingPathComponent("agent-verified-code")
        try #require(PommeAgentVerifiedCodeRecord(sha256: Self.digest, cdhash: Self.cdhash)).write(to: recordURL)

        // The executable doesn't exist, so reaching the token proves that the
        // agent never read it. The missing token stops before any connection.
        let exit = PommeAgentDaemon.run(
            arguments: Self.persistentArguments(directory: directory, digest: Self.digest),
            executablePath: directory.appendingPathComponent("missing-pomme").path,
            recoveryOwner: geteuid(),
            recoveryGroup: getegid(),
            codeIdentity: { Self.enforcedIdentity },
            verifiedCodeURL: recordURL
        )

        #expect(exit == PommeAgentDaemon.Exit.credential.rawValue)
    }

    @Test(
        "persistent agent hashes its executable unless its CDHash is enforced and verified",
        arguments: [
            (status: Self.enforcedIdentity.status, recordedCDHash: String(repeating: "c", count: 40)),
            (status: Self.enforcedIdentity.status & ~PommeAgentCodeIdentity.kill, recordedCDHash: Self.cdhash),
            (status: Self.enforcedIdentity.status | PommeAgentCodeIdentity.adhoc, recordedCDHash: Self.cdhash),
        ]
    )
    func persistentAgentFallsBackToHash(status: UInt32, recordedCDHash: String) throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordURL = directory.appendingPathComponent("agent-verified-code")
        let previous = try #require(PommeAgentVerifiedCodeRecord(sha256: Self.digest, cdhash: recordedCDHash))
        try previous.write(to: recordURL)
        let missing = directory.appendingPathComponent("missing-pomme")

        let exit = PommeAgentDaemon.run(
            arguments: Self.persistentArguments(directory: directory, digest: Self.digest),
            executablePath: missing.path,
            recoveryOwner: geteuid(),
            recoveryGroup: getegid(),
            codeIdentity: { PommeAgentCodeIdentity(status: status, cdhash: Self.cdhash) },
            verifiedCodeURL: recordURL
        )

        // Hashing the missing executable fails before the token is read.
        #expect(exit == PommeAgentDaemon.Exit.transport.rawValue)
        #expect(PommeAgentVerifiedCodeRecord.read(at: recordURL, expectedOwner: geteuid()) == previous)
    }

    @Test("persistent agent records its CDHash only after hashing its pinned digest")
    func persistentAgentRecordsVerifiedCDHash() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordURL = directory.appendingPathComponent("agent-verified-code")
        let executable = directory.appendingPathComponent("pomme")
        let bytes = Data("pomme-test-executable".utf8)
        try bytes.write(to: executable)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        func launch(expecting expected: String, identity: PommeAgentCodeIdentity) -> Int32 {
            PommeAgentDaemon.run(
                arguments: Self.persistentArguments(directory: directory, digest: expected),
                executablePath: executable.path,
                recoveryOwner: geteuid(),
                recoveryGroup: getegid(),
                codeIdentity: { identity },
                verifiedCodeURL: recordURL
            )
        }

        // A digest that launchd didn't pin is never recorded.
        #expect(launch(expecting: Self.digest, identity: Self.enforcedIdentity) == PommeAgentDaemon.Exit.integrity.rawValue)
        #expect(!FileManager.default.fileExists(atPath: recordURL.path))

        // Without enforcement, a matching hash still isn't recorded.
        let unenforced = PommeAgentCodeIdentity(status: Self.enforcedIdentity.status | PommeAgentCodeIdentity.adhoc,
                                                cdhash: Self.cdhash)
        #expect(launch(expecting: digest, identity: unenforced) == PommeAgentDaemon.Exit.credential.rawValue)
        #expect(!FileManager.default.fileExists(atPath: recordURL.path))

        #expect(launch(expecting: digest, identity: Self.enforcedIdentity) == PommeAgentDaemon.Exit.credential.rawValue)
        #expect(PommeAgentVerifiedCodeRecord.read(at: recordURL, expectedOwner: geteuid())
            == PommeAgentVerifiedCodeRecord(sha256: digest, cdhash: Self.cdhash))

        // With the record in place, the next launch never reads the executable.
        try FileManager.default.removeItem(at: executable)
        #expect(launch(expecting: digest, identity: Self.enforcedIdentity) == PommeAgentDaemon.Exit.credential.rawValue)
    }

    private static let digest = String(repeating: "a", count: 64)
    private static let cdhash = String(repeating: "b", count: 40)
    private static let enforcedIdentity = PommeAgentCodeIdentity(status: 0x2201_1311, cdhash: cdhash)

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-agent-code-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// The token file never exists, so a launch stops before connecting.
    private static func persistentArguments(directory: URL, digest: String) -> [String] {
        [
            "--pomme-agent", String(Constants.pommeAgentPort),
            "--token-file", directory.appendingPathComponent("missing-token").path,
            "--expected-sha256", digest,
            "--role", "normal",
        ]
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
        try await runOneShotOperation()
    }

    @Test("one-shot peer budget starts after delayed serving admission")
    func delayedOneShotOperation() async throws {
        try await runOneShotOperation(readTimeout: .seconds(1), beforeServing: {
            try? await Task.sleep(for: .milliseconds(1_200))
        })
    }

    private func runOneShotOperation(
        readTimeout: Duration = .seconds(5),
        setupTimeout: Duration = .seconds(30),
        beforeServing: (@Sendable () async -> Void)? = nil
    ) async throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { _ = Darwin.close(sockets[0]); _ = Darwin.close(sockets[1]) }
        let token = String(repeating: "a", count: 64)
        let connection = try PommeAgentConnection(token: token, lifetime: .oneShot, expiresAt: Date(timeIntervalSinceNow: 60), vmBinding: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", sessionBinding: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let agent = try PommeAgent(role: .recovery, executableSHA256: token)
        let auth = PommeAgentProtocol.Envelope.request(operation: "authenticate", payload: .object([
            "challenge": .string(String(repeating: "b", count: 64)),
            "vmID": .string("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            "sessionID": .string("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        ]))
        let operation = PommeAgentProtocol.Envelope.request(operation: "agent.install", payload: .object([:]))
        let replay = PommeAgentProtocol.Envelope.request(operation: "agent.install", payload: .object([:]))
        let bytes = try PommeAgentProtocol.encode(auth) + PommeAgentProtocol.encode(operation) + PommeAgentProtocol.encode(replay)
        let serverDescriptor = sockets[1]
        let admission = DaemonServingAdmission()
        let serving = Task {
            await beforeServing?()
            guard !Task.isCancelled else {
                admission.resolve(.failure(CancellationError()))
                return
            }
            admission.resolve(.success(()))
            await PommeAgentDaemon.serve(
                descriptor: serverDescriptor,
                connection: connection,
                agent: agent,
                allowedOperation: "agent.install"
            )
        }
        #expect(bytes.withUnsafeBytes { Darwin.write(sockets[0], $0.baseAddress, $0.count) } == bytes.count)

        // Keep the write side open: natural one-shot completion, not EOF,
        // must terminate serving after the one allowlisted operation.
        do {
            try await admission.wait(timeout: setupTimeout)
            try Task.checkCancellation()
        } catch {
            _ = shutdown(sockets[0], SHUT_RDWR)
            _ = shutdown(sockets[1], SHUT_RDWR)
            serving.cancel()
            await serving.value
            throw error
        }
        let result = await DaemonPeerReader.read(descriptor: sockets[0], timeout: readTimeout)
        let completedNaturally = await DaemonPeerReader.finish(
            serving: serving, result: result, sockets: sockets
        )
        let reply = try result.get()
        #expect(completedNaturally)
        let lines = reply.split(separator: 0x0A)
        #expect(lines.count == 2)
        try #require(lines.count >= 2)
        #expect(try PommeAgentProtocol.decode(Data(lines[0])).ok == true)
        #expect(try PommeAgentProtocol.decode(Data(lines[0])).requestID == auth.requestID)
        #expect(try PommeAgentProtocol.decode(Data(lines[1])).requestID == operation.requestID)
    }

    @Test("one-shot admission timeout cancels and joins the setup task")
    func oneShotAdmissionTimeout() async throws {
        let hookReturned = Mutex(false)
        do {
            try await runOneShotOperation(setupTimeout: .milliseconds(10), beforeServing: {
                defer { hookReturned.withLock { $0 = true } }
                try? await Task.sleep(for: .seconds(60))
            })
            Issue.record("Expected bounded one-shot setup admission failure")
        } catch DaemonServingAdmission.Failure.timedOut {}
        #expect(hookReturned.withLock { $0 })
    }

    @Test("one-shot admission caller cancellation joins the setup task")
    func oneShotAdmissionCancellation() async throws {
        let hookEntered = DaemonServingAdmission()
        let hookReturned = Mutex(false)
        let caller = Task {
            try await runOneShotOperation(beforeServing: {
                defer { hookReturned.withLock { $0 = true } }
                hookEntered.resolve(.success(()))
                try? await Task.sleep(for: .seconds(60))
            })
        }
        do {
            try await hookEntered.wait(timeout: .seconds(30))
        } catch {
            caller.cancel()
            _ = try? await caller.value
            throw error
        }
        caller.cancel()
        do {
            try await caller.value
            Issue.record("Expected caller cancellation during one-shot setup")
        } catch is CancellationError {}
        #expect(hookReturned.withLock { $0 })
    }

    @Test("daemon peer reader reports a silent peer deadline before descriptor teardown")
    func peerReadDeadline() async throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { _ = Darwin.close(sockets[0]); _ = Darwin.close(sockets[1]) }
        let result = await DaemonPeerReader.read(descriptor: sockets[0], timeout: .zero)
        // Completion means the reader has relinquished the descriptor; only
        // this owning task shuts down/closes it, including the failure path.
        _ = shutdown(sockets[0], SHUT_RDWR)
        _ = shutdown(sockets[1], SHUT_RDWR)
        #expect(throws: DaemonPeerReader.Failure.deadline) { try result.get() }
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

private final class DaemonServingAdmission: Sendable {
    enum Failure: Error { case timedOut }
    private struct State {
        var result: Result<Void, any Error>?
        var waiter: CheckedContinuation<Void, any Error>?
    }
    private let state = Mutex(State())

    func resolve(_ result: Result<Void, any Error>) {
        let waiter = state.withLock { value -> CheckedContinuation<Void, any Error>? in
            guard value.result == nil else { return nil }
            value.result = result
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume(with: result)
    }

    func wait(timeout: Duration) async throws {
        let watchdog = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            resolve(.failure(Failure.timedOut))
        }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let result = state.withLock { value -> Result<Void, any Error>? in
                        if let result = value.result { return result }
                        value.waiter = continuation
                        return nil
                    }
                    if let result { continuation.resume(with: result) }
                }
                try Task.checkCancellation()
            } onCancel: {
                self.resolve(.failure(CancellationError()))
            }
            watchdog.cancel()
            await watchdog.value
        } catch {
            watchdog.cancel()
            await watchdog.value
            throw error
        }
    }
}

private enum DaemonPeerReader {
    enum Failure: Error, Equatable {
        case deadline
        case socket(Int32)
        case oversizedReply
    }

    static func finish(
        serving: Task<Void, Never>,
        result: Result<Data, any Error>,
        sockets: [Int32]
    ) async -> Bool {
        if case .failure = result {
            for descriptor in sockets { _ = shutdown(descriptor, SHUT_RDWR) }
            await serving.value
            return false
        }
        let serverReturned = Mutex(false)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await serving.value
                serverReturned.withLock { $0 = true }
                return true
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(5)) }
                catch {
                    // Timer cancellation following a joined server is benign;
                    // outer task cancellation must still unblock the server.
                    if serverReturned.withLock({ $0 }) { return true }
                }
                for descriptor in sockets { _ = shutdown(descriptor, SHUT_RDWR) }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            // Join BOTH children. In particular, a timeout must remain false
            // even when shutdown lets the serving child win group.next().
            var natural = first
            for await completed in group { natural = natural && completed }
            return natural
        }
    }

    static func read(
        descriptor: Int32,
        timeout: Duration = .seconds(5)
    ) async -> Result<Data, any Error> {
        await withCheckedContinuation { continuation in
            // The caller retains both descriptors until completion. This
            // dedicated thread is their sole reader, and never accesses them
            // after resuming the continuation. No cooperative worker blocks.
            let deadline = ContinuousClock.now.advanced(by: timeout)
            let thread = Thread {
                let result = Result { try readReply(descriptor: descriptor, deadline: deadline) }
                continuation.resume(returning: result)
            }
            thread.name = "pomme-test-daemon-peer"
            thread.start()
        }
    }

    private static func readReply(
        descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) throws -> Data {
        var reply = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while reply.filter({ $0 == 0x0A }).count < 2 {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw Failure.deadline }
            let parts = remaining.components
            let milliseconds = max(1, min(5_000, parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000))
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&event, 1, Int32(milliseconds))
            if ready < 0 {
                if errno == EINTR { continue }
                throw Failure.socket(errno)
            }
            if ready == 0 { continue }
            if event.revents & Int16(POLLNVAL) != 0 { throw Failure.socket(EBADF) }
            let count = scratch.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw Failure.socket(errno)
            }
            if count == 0 { break }
            reply.append(contentsOf: scratch.prefix(count))
            guard reply.count <= 1_048_576 else { throw Failure.oversizedReply }
        }
        return reply
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
