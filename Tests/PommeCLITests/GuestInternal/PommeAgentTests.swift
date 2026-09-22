import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Pomme persistent agent")
struct PommeAgentTests {

    @Test("Same-job signal cleans descendants after their leader exits", arguments: [false, true])
    func exitedLeaderDescendantCleanup(streamSignal: Bool) async throws {
        try await descendantFixture(streamSignal: streamSignal)
    }

    @Test("Unexpected external reap loses signal authority and cannot manufacture an exit frame")
    func externallyReapedLeaderFailsClosed() async throws {
        try await descendantFixture(streamSignal: false, loseOwnership: true)
    }

    private func descendantFixture(streamSignal: Bool, loseOwnership: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-descendant-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let ready = directory.appendingPathComponent("ready")
        let stop = directory.appendingPathComponent("stop")
        let done = directory.appendingPathComponent("done")
        let childPID = directory.appendingPathComponent("child-pid")
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64),
                                  journalPath: directory.appendingPathComponent("journal").path)
        // The descendant retains both output pipes. A private sentinel and
        // finite loop provide cleanup even when the candidate rejects signal;
        // the test never kills a numeric PID after its leader was reaped.
        let childScript = """
        trap 'printf done > "$3"; exit 0' TERM
        printf ready > "$1"
        n=0
        while [ ! -e "$2" ] && [ "$n" -lt 60 ]; do
          /bin/sleep 1
          n=$((n + 1))
        done
        printf done > "$3"
        """
        let leaderScript = """
        /bin/sh -c "$1" descendant "$2" "$3" "$4" &
        printf '%s' "$!" > "$5"
        exit 7
        """
        let started = try await agent.perform(.request(operation: "process.start", payload: .object([
            "path": .string("/bin/sh"), "detached": .bool(loseOwnership),
            "arguments": .array(["-c", leaderScript, "leader", childScript, ready.path, stop.path, done.path, childPID.path].map(JSONValue.string))
        ])))
        let values = try #require(started.objectValue)
        let jobText = try #require(values["jobID"]?.stringValue)
        let jobID = try #require(UUID(uuidString: jobText))
        guard case .integer(let rawPID)? = values["pid"], let pid = pid_t(exactly: rawPID), pid > 0 else {
            throw PommeAgentOperationError.invalid
        }
        var failure: (any Error)?
        var frames: [PommeAgentStreamFrame] = []
        do {
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !FileManager.default.fileExists(atPath: ready.path) || !FileManager.default.fileExists(atPath: childPID.path) {
                try #require(ContinuousClock.now < readyDeadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            let descendantPID = try #require(Int32(String(contentsOf: childPID, encoding: .utf8)))
            #expect(descendantPID > 0 && descendantPID != pid)
            var leaderExited = false
            repeat {
                var info = siginfo_t()
                let observed = Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                leaderExited = (observed == 0 && info.si_pid == pid) || (observed == -1 && errno == ECHILD)
                if leaderExited { break }
                try #require(ContinuousClock.now < readyDeadline)
                try await Task.sleep(for: .milliseconds(10))
            } while true
            #expect(leaderExited)
            let terminal = try await agent.perform(.request(operation: "process.status", payload: .object(["jobID": .string(jobText)])))
            #expect(terminal.objectValue?["exited"] == .bool(true))
            #expect(terminal.objectValue?["exitCode"] == .integer(7))
            frames = try await agent.streamEvents(jobID: jobID, requestID: UUID())
            #expect(!frames.contains { $0.stream == .exit })
            #expect(!FileManager.default.fileExists(atPath: done.path))
            if loseOwnership {
                var info = siginfo_t()
                try #require(Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0)
                try #require(info.si_pid == pid)
                var consumedStatus: Int32 = 0
                try #require(Darwin.waitpid(pid, &consumedStatus, WNOHANG) == pid)
                #expect(consumedStatus & 0x7f == 0)
                #expect((consumedStatus >> 8) & 0xff == 7)
                // Real ECHILD on the next refresh must revoke ownership while
                // retaining only the previously observed leader status.
                let lost = try await agent.perform(.request(operation: "process.status", payload: .object(["jobID": .string(jobText)])))
                #expect(lost.objectValue?["exitCode"] == .integer(7))
                frames += try await agent.streamEvents(jobID: jobID, requestID: UUID())
                #expect(!frames.contains { $0.stream == .exit })
                await #expect(throws: PommeAgentOperationError.self) {
                    _ = try await agent.perform(.request(operation: "process.signal", payload: .object([
                        "jobID": .string(jobText), "signal": .integer(Int64(SIGTERM))
                    ])))
                }
                await #expect(throws: PommeAgentOperationError.self) {
                    _ = try await agent.acceptStream(.init(requestID: UUID(), stream: .signal, signal: SIGTERM), jobID: jobID)
                }
                // This fixture has pipes, so this is not an ownership-specific
                // resize proof; the autonomous PTY case covers stale resize.
                await #expect(throws: PommeAgentOperationError.self) {
                    try await agent.resizePTY(jobID: jobID, columns: 80, rows: 24)
                }
            } else if streamSignal {
                frames += try await agent.acceptStream(.init(requestID: UUID(), stream: .signal, signal: SIGTERM), jobID: jobID)
            } else {
                let response = try await agent.perform(.request(operation: "process.signal", payload: .object([
                    "jobID": .string(jobText), "signal": .integer(Int64(SIGTERM))
                ])))
                #expect(response.objectValue?["signalled"] == .bool(true))
            }
            if !loseOwnership {
                let signalDeadline = ContinuousClock.now.advanced(by: .seconds(30))
                while !frames.contains(where: { $0.stream == .exit }), ContinuousClock.now < signalDeadline {
                    frames += try await agent.streamEvents(jobID: jobID, requestID: UUID())
                    try await Task.sleep(for: .milliseconds(10))
                }
                // This proof precedes the fallback sentinel, so an accepted but
                // ineffective group signal cannot pass using fixture cleanup.
                try #require(frames.contains { $0.stream == .exit })
                #expect(FileManager.default.fileExists(atPath: done.path))
            }
        } catch {
            failure = error
        }
        // Always release the exact descendant through its private sentinel,
        // including the expected RED rejection, before rethrowing any failure.
        try Data().write(to: stop)
        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        if loseOwnership {
            var outputComplete = false
            repeat {
                let output = try await agent.perform(.request(operation: "process.output", payload: .object(["jobID": .string(jobText)])))
                outputComplete = output.objectValue?["outputComplete"] == .bool(true)
                if outputComplete { break }
                try? await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < cleanupDeadline
            #expect(outputComplete)
            #expect(FileManager.default.fileExists(atPath: done.path))
            let replay = try await agent.retainedLogEvents(jobID: jobID, requestID: UUID())
            #expect(!replay.contains { $0.stream == .exit })
            let streamed = try await agent.streamEvents(jobID: jobID, requestID: UUID())
            #expect(!streamed.contains { $0.stream == .exit })
            if outputComplete { try FileManager.default.removeItem(at: directory) }
            if let failure { throw failure }
            return
        }
        while !frames.contains(where: { $0.stream == .exit }), ContinuousClock.now < cleanupDeadline {
            frames += try await agent.streamEvents(jobID: jobID, requestID: UUID())
            try? await Task.sleep(for: .milliseconds(10))
        }
        let drained = frames.contains { $0.stream == .exit }
        #expect(drained)
        if drained {
            var info = siginfo_t()
            let observed = Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            #expect(observed == -1 && errno == ECHILD, "Exit frame must prove the leader was actually reaped")
        }
        #expect(FileManager.default.fileExists(atPath: done.path))
        let retained = try await agent.perform(.request(operation: "process.status", payload: .object(["jobID": .string(jobText)])))
        #expect(retained.objectValue?["exitCode"] == .integer(7))
        #expect(retained.objectValue?["signal"] == nil)
        if drained { try FileManager.default.removeItem(at: directory) }
        if let failure { throw failure }
    }

    @Test("Signalled child is reaped without a later job request")
    func signalledChildReapedWithoutPolling() async throws {
        try await autonomousReap(signalled: true, detached: false)
    }

    @Test("Immediate child exit is reaped autonomously with terminal output retained", arguments: [false, true])
    func immediateChildReapedWithoutPolling(detached: Bool) async throws {
        try await autonomousReap(signalled: false, detached: detached)
    }

    @Test("No-output and PTY children are reaped without polling", arguments: [false, true])
    func autonomousReapOutputEndpoints(pty: Bool) async throws {
        // Local observer-disabled characterization found that closing a PTY
        // can discard unread output before any waitpid. Use a quiet PTY for
        // reaping proof; pipes below retain bytes, and live PTY tests drain
        // while the writer remains alive.
        try await autonomousReap(signalled: false, detached: false, pty: pty, producesOutput: false)
    }

    private func autonomousReap(signalled: Bool, detached: Bool, pty: Bool = false, producesOutput: Bool = true) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-autonomous-reap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = try PommeAgent(
            role: .persistent,
            executableSHA256: String(repeating: "a", count: 64),
            journalPath: directory.appendingPathComponent("journal").path
        )
        let started = try await agent.perform(.request(operation: "process.start", payload: .object([
            "path": .string(signalled ? "/bin/sleep" : "/bin/sh"),
            "arguments": .array((signalled ? ["60"] : ["-c", producesOutput ? "printf retained; exit 7" : "exit 7"]).map(JSONValue.string)),
            "detached": .bool(detached), "pty": .bool(pty)
        ])))
        let values = try #require(started.objectValue)
        let jobText = try #require(values["jobID"]?.stringValue)
        let jobID = try #require(UUID(uuidString: jobText))
        guard case .integer(let rawPID)? = values["pid"], let pid = pid_t(exactly: rawPID), pid > 0 else {
            throw PommeAgentOperationError.invalid
        }

        var observedZombie = false
        let observation: Result<Bool, any Error>
        do {
            if signalled {
                let response = try await agent.perform(.request(operation: "process.signal", payload: .object([
                    "jobID": .string(jobText), "signal": .integer(Int64(SIGTERM))
                ])))
                #expect(response.objectValue?["signalled"] == .bool(true))
            }
            // Scheduler guard, not a two-second production reap SLA: complete
            // parallel test runs can defer an actor task for over 17 seconds.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            var reaped = false
            repeat {
                var info = siginfo_t()
                // WNOWAIT observes this exact child without consuming its
                // terminal status. No agent status/list/stream call occurs here.
                let result = Darwin.waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == -1 {
                    if errno == ECHILD { reaped = true; break }
                    if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                } else if info.si_pid == pid {
                    observedZombie = true
                }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            observation = .success(reaped)
        } catch {
            observation = .failure(error)
        }
        if case .success(let reaped) = observation {
            #expect(reaped, "Expected autonomous reap without requests; observedZombie=\(observedZombie)")
        }

        // Observation is complete. Only now may an agent request refresh/reap
        // the job, including on the expected red path or caller cancellation.
        var terminal = try? await agent.perform(.request(operation: "process.status", payload: .object([
            "jobID": .string(jobText)
        ])))
        if terminal?.objectValue?["exited"] != .bool(true) {
            // Reaping and signalling now share actor ownership, so cleanup
            // cannot race the autonomous reaper and signal a released PID.
            _ = try? await agent.perform(.request(operation: "process.signal", payload: .object([
                "jobID": .string(jobText), "signal": .integer(Int64(SIGKILL))
            ])))
            let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while terminal?.objectValue?["exited"] != .bool(true), ContinuousClock.now < cleanupDeadline {
                terminal = try? await agent.perform(.request(operation: "process.status", payload: .object([
                    "jobID": .string(jobText)
                ])))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(terminal?.objectValue?["exited"] == .bool(true), "Exact-child failure cleanup must reap")
        var finalInfo = siginfo_t()
        let finalWait = Darwin.waitid(P_PID, id_t(pid), &finalInfo, WEXITED | WNOHANG | WNOWAIT)
        #expect(finalWait == -1 && errno == ECHILD)
        _ = try observation.get()
        #expect(terminal?.objectValue?["jobID"] == .string(jobText))
        if signalled {
            #expect(terminal?.objectValue?["signal"] == .integer(Int64(SIGTERM)))
        } else {
            #expect(terminal?.objectValue?["exitCode"] == .integer(7))
        }
        // Reaping does not imply pipe EOF was already consumed. Only after
        // the independent kernel assertion may these bounded reads drain it.
        let streamRequestID = UUID()
        let drainDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        var frames: [PommeAgentStreamFrame] = []
        repeat {
            frames += try await agent.streamEvents(jobID: jobID, requestID: streamRequestID)
            if frames.contains(where: { $0.stream == .exit }) { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < drainDeadline
        let exits = frames.filter { $0.stream == .exit }
        #expect(exits.count == 1)
        #expect(exits.first?.signal == (signalled ? SIGTERM : nil))
        #expect(frames.allSatisfy { $0.requestID == streamRequestID })
        if !signalled {
            #expect(frames.filter { $0.stream == .stdout }.reduce(into: Data()) { $0.append($1.data ?? Data()) } == (producesOutput ? Data("retained".utf8) : Data()))
            if detached {
                for _ in 0..<2 {
                    let replay = try await agent.retainedLogEvents(jobID: jobID, requestID: UUID())
                    #expect(replay.filter { $0.stream == .stdout }.reduce(into: Data()) { $0.append($1.data ?? Data()) } == Data("retained".utf8))
                    #expect(replay.filter { $0.stream == .exit }.count == 1)
                }
            }
        }
        // Autonomous reaping releases the kernel PID; neither signal entry
        // point may target that PID again through the retained job record.
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "process.signal", payload: .object([
                "jobID": .string(jobText), "signal": .integer(Int64(SIGTERM))
            ])))
        }
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.acceptStream(.init(requestID: UUID(), stream: .signal, signal: SIGTERM), jobID: jobID)
        }
        await #expect(throws: PommeAgentOperationError.self) {
            try await agent.resizePTY(jobID: jobID, columns: 80, rows: 24)
        }
    }

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
            "normalAMFIWorkflowVersion", "normalAMFIStatusVersion"
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
