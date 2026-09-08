import Darwin
import Foundation
import Testing

@Suite("Pomme agent execution options")
struct PommeAgentExecutionOptionsTests: Sendable {
    @Test("Agent applies cwd environment stdin and stderr redirection")
    func agentAppliesExecutionOptions() async throws {
        let root = try Fixture()
        defer { root.remove() }
        let stdin = root.url.appendingPathComponent("input")
        let stderr = root.url.appendingPathComponent("stderr")
        try Data("from-file".utf8).write(to: stdin)
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))

        let started = try await agent.perform(.request(
            operation: "process.start",
            payload: .object([
                "path": .string("/bin/sh"),
                "arguments": .array([.string("-c"), .string("printf '%s:%s:' \"$POMME_OPTIONS_TEST\" \"$PWD\"; cat; printf stderr-file >&2")]),
                "cwd": .string(root.url.path),
                "environment": .object(["POMME_OPTIONS_TEST": .string("applied")]),
                "stdinPath": .string(stdin.path),
                "stderrPath": .string(stderr.path)
            ])
        ))
        let id = try #require(started.objectValue?["jobID"]?.stringValue)
        let jobID = try #require(UUID(uuidString: id))
        let events = try await finish(agent, jobID: jobID)

        let stdout = events
            .filter { $0.stream == .stdout }
            .compactMap(\.data)
            .reduce(into: Data()) { $0.append($1) }
        #expect(stdout == Data("applied:\(physicalPath(root.url.path)):from-file".utf8))
        #expect(events.allSatisfy { $0.stream != .stderr })
        #expect(try Data(contentsOf: stderr) == Data("stderr-file".utf8))
    }

    @Test("Agent applies stdout redirection while preserving stderr streaming")
    func agentAppliesStdoutRedirection() async throws {
        let root = try Fixture()
        defer { root.remove() }
        let stdout = root.url.appendingPathComponent("stdout")
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))

        let started = try await agent.perform(.request(
            operation: "process.start",
            payload: .object([
                "path": .string("/bin/sh"),
                "arguments": .array([.string("-c"), .string("printf stdout-file; printf stderr-stream >&2")]),
                "stdoutPath": .string(stdout.path)
            ])
        ))
        let id = try #require(started.objectValue?["jobID"]?.stringValue)
        let jobID = try #require(UUID(uuidString: id))
        let events = try await finish(agent, jobID: jobID)

        let stderr = events
            .filter { $0.stream == .stderr }
            .compactMap(\.data)
            .reduce(into: Data()) { $0.append($1) }
        #expect(try Data(contentsOf: stdout) == Data("stdout-file".utf8))
        #expect(stderr == Data("stderr-stream".utf8))
        #expect(events.allSatisfy { $0.stream != .stdout })
    }

    @Test("Agent rejects malformed and unopenable execution options before starting a job")
    func agentRejectsInvalidExecutionOptions() async throws {
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        for payload: JSONValue in [
            .object(["path": .string("/usr/bin/true"), "arguments": .array([]), "cwd": .string("relative")]),
            .object(["path": .string("/usr/bin/true"), "arguments": .array([]), "environment": .object(["9INVALID": .string("x")])]),
            .object(["path": .string("/usr/bin/true"), "arguments": .array([]), "pty": .bool(true), "stdoutPath": .string("/tmp/output")]),
            .object(["path": .string("/usr/bin/true"), "arguments": .array([]), "stdoutPath": .string("/path-that-does-not-exist/pomme-output")])
        ] {
            await #expect(throws: PommeAgentOperationError.self) {
                _ = try await agent.perform(.request(operation: "process.start", payload: payload))
            }
        }
    }

    @Test("Privilege resolution returns usable root and current-account groups")
    func privilegeResolutionIncludesRealGroups() throws {
        let rootByName = try #require(try PommePrivilege.resolve(["user": .string("root")]))
        let rootByID = try #require(try PommePrivilege.resolve(["uid": .integer(0)]))
        let current = try #require(try PommePrivilege.resolve(["uid": .integer(Int64(geteuid()))]))

        #expect(rootByName.uid == 0)
        #expect(rootByName.supplementary.contains(rootByName.gid))
        #expect(rootByID.uid == 0)
        #expect(rootByID.supplementary.contains(rootByID.gid))
        #expect(current.uid == geteuid())
        #expect(current.supplementary.contains(current.gid))

        let nobody = try #require(try PommePrivilege.resolve(["user": .string("nobody")]))
        let nobodyByID = try #require(try PommePrivilege.resolve(["gid": .integer(Int64(nobody.gid))]))
        #expect(nobody.gid == gid_t.max - 1)
        #expect(nobodyByID.gid == nobody.gid)

        if let wheel = getgrnam("wheel") {
            let byName = try #require(try PommePrivilege.resolve(["group": .string("wheel")]))
            let byID = try #require(try PommePrivilege.resolve(["gid": .integer(Int64(wheel.pointee.gr_gid))]))
            #expect(byName.gid == wheel.pointee.gr_gid)
            #expect(byID.gid == wheel.pointee.gr_gid)
        }
    }

    @Test("Concurrent launches keep the parent environment and cwd unchanged")
    func concurrentLaunchesDoNotMutateParent() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.remove(); second.remove() }
        let originalCWD = FileManager.default.currentDirectoryPath
        let originalEnvironment = ProcessInfo.processInfo.environment
        let one = try PommeProcess.spawn(
            path: "/bin/sh",
            arguments: ["-c", "printf '%s:%s' \"$POMME_OPTIONS_TEST\" \"$PWD\""],
            identity: nil,
            pty: false,
            options: .init(cwd: first.url.path, environment: ["POMME_OPTIONS_TEST": "one"])
        )
        let two = try PommeProcess.spawn(
            path: "/bin/sh",
            arguments: ["-c", "printf '%s:%s' \"$POMME_OPTIONS_TEST\" \"$PWD\""],
            identity: nil,
            pty: false,
            options: .init(cwd: second.url.path, environment: ["POMME_OPTIONS_TEST": "two"])
        )
        defer { closeSpawned(one); closeSpawned(two) }

        #expect(try output(of: one) == Data("one:\(physicalPath(first.url.path))".utf8))
        #expect(try output(of: two) == Data("two:\(physicalPath(second.url.path))".utf8))
        #expect(FileManager.default.currentDirectoryPath == originalCWD)
        #expect(ProcessInfo.processInfo.environment == originalEnvironment)
    }

    @Test("An explicit current identity does not require a privileged transition")
    func currentIdentityLaunchesWithoutRoot() throws {
        let identity = try #require(try PommePrivilege.resolve(["uid": .integer(Int64(geteuid()))]))
        let spawned = try PommeProcess.spawn(
            path: "/bin/sh",
            arguments: ["-c", "printf current-identity"],
            identity: identity,
            pty: false
        )
        defer { closeSpawned(spawned) }
        #expect(try output(of: spawned) == Data("current-identity".utf8))
    }

    @Test("Identity helper accepts only a ready marker followed by exec closure")
    func identityHelperHandshakeRequiresReadyThenClosure() throws {
        for (bytes, expected) in [
            (Data(), false),
            (Data([1]), false),
            (Data([0x7f, 1]), false),
            (Data([0x7f]), true)
        ] {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
            defer {
                _ = Darwin.close(descriptors[0])
                _ = Darwin.close(descriptors[1])
            }
            try bytes.withUnsafeBytes { pointer in
                if !bytes.isEmpty {
                    guard Darwin.write(descriptors[1], pointer.baseAddress, bytes.count) == bytes.count else {
                        throw POSIXError(.EIO)
                    }
                }
            }
            _ = Darwin.close(descriptors[1])
            descriptors[1] = -1
            #expect(try PommeProcess.helperSucceeded(statusDescriptor: descriptors[0]) == expected)
        }
    }

    private func finish(_ agent: PommeAgent, jobID: UUID) async throws -> [PommeAgentStreamFrame] {
        let requestID = UUID()
        var events: [PommeAgentStreamFrame] = []
        for _ in 0..<100 {
            events += try await agent.streamEvents(jobID: jobID, requestID: requestID)
            if events.contains(where: { $0.stream == .exit }) { return events }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Process did not complete within one second.")
        return events
    }

    private func output(of spawned: PommeProcess.Spawned) throws -> Data {
        guard let descriptor = spawned.stdout else { throw POSIXError(.EBADF) }
        var data = Data()
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 4 * 1024)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
            } else if count == 0 {
                _ = waitpid(spawned.pid, &status, 0)
                return data
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw POSIXError(.EIO)
            }
            usleep(10_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func closeSpawned(_ spawned: PommeProcess.Spawned) {
        [spawned.stdin, spawned.stdout, spawned.stderr, spawned.ptyMaster]
            .compactMap { $0 }
            .forEach { _ = Darwin.close($0) }
        var status: Int32 = 0
        if waitpid(spawned.pid, &status, WNOHANG) == 0 {
            _ = kill(spawned.pid, SIGKILL)
            _ = waitpid(spawned.pid, &status, 0)
        }
    }

    private func physicalPath(_ path: String) -> String {
        path.hasPrefix("/var/") ? "/private\(path)" : path
    }
}

private struct Fixture: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-exec-options-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
