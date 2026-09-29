import Darwin
import CryptoKit
import Foundation
import Testing

@Suite("Pomme agent files, jobs, and privilege validation", .serialized)
struct PommeAgentOperationsTests {
    @Test("File chunks are bounded and handle operations are correlated")
    func files() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        let path = directory.appendingPathComponent("result").path
        let opened = try await agent.perform(.request(operation: "file.open", payload: .object(["path": .string(path), "mode": .string("stageWrite")])))
        let id = try #require(opened.objectValue?["fileID"]?.stringValue)
        let bytes = Data("pomme".utf8)
        let write = try await agent.perform(.request(operation: "file.write", payload: .object(["fileID": .string(id), "dataBase64": .string(bytes.base64EncodedString())])))
        #expect(write.objectValue?["count"] == .integer(Int64(bytes.count)))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let committed = try await agent.perform(.request(operation: "file.commit", payload: .object([
            "fileID": .string(id),
            "expectedBytes": .integer(Int64(bytes.count)),
            "expectedSHA256": .string(digest)
        ])))
        #expect(committed == .object([
            "committed": .bool(true),
            "bytes": .integer(Int64(bytes.count)),
            "sha256": .string(digest)
        ]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "file.open", payload: .object(["path": .string(path), "mode": .string("write")])))
        }
    }

    @Test("Staging refuses a symlink in any ancestor component")
    func ancestorSymlinkIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathComponent("outside/deep")
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: root.appendingPathComponent("outside").path)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "file.open", payload: .object(["path": .string(linked.appendingPathComponent("deep/result").path), "mode": .string("stageWrite")])))
        }
    }

    @Test("A partial file mutation poisons the handle and requires abort")
    func partialWriteCannotRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64), writeChunk: { descriptor, data, offset in
            guard offset == 0 else { return -1 }
            return data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, 1) }
        })
        let opened = try await agent.perform(.request(operation: "file.open", payload: .object(["path": .string(directory.appendingPathComponent("result").path), "mode": .string("stageWrite")])))
        let id = try #require(opened.objectValue?["fileID"]?.stringValue)
        let payload: JSONValue = .object(["fileID": .string(id), "dataBase64": .string(Data("two".utf8).base64EncodedString())])
        await #expect(throws: PommeAgentOperationError.self) { _ = try await agent.perform(.request(operation: "file.write", payload: payload)) }
        await #expect(throws: PommeAgentOperationError.self) { _ = try await agent.perform(.request(operation: "file.write", payload: payload)) }
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "file.commit", payload: .object([
                "fileID": .string(id),
                "expectedBytes": .integer(1),
                "expectedSHA256": .string(String(repeating: "0", count: 64))
            ])))
        }
    }

    @Test("File commit verifies the guest bytes before replacing the destination")
    func fileCommitDigestMismatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("profile.mobileconfig")
        let original = Data("existing".utf8)
        try original.write(to: destination)
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        let opened = try await agent.perform(.request(operation: "file.open", payload: .object([
            "path": .string(destination.path),
            "mode": .string("stageWrite")
        ])))
        let id = try #require(opened.objectValue?["fileID"]?.stringValue)
        let bytes = Data("replacement".utf8)
        _ = try await agent.perform(.request(operation: "file.write", payload: .object([
            "fileID": .string(id),
            "dataBase64": .string(bytes.base64EncodedString())
        ])))

        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "file.commit", payload: .object([
                "fileID": .string(id),
                "expectedBytes": .integer(Int64(bytes.count)),
                "expectedSHA256": .string(String(repeating: "0", count: 64))
            ])))
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
            !$0.hasPrefix(".pomme-stage-")
        })
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(operation: "file.commit", payload: .object([
                "fileID": .string(id),
                "expectedBytes": .integer(Int64(bytes.count)),
                "expectedSHA256": .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            ])))
        }
    }

    @Test("Detached jobs remain addressable and signal validation is closed")
    func jobs() async throws {
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        let started = try await agent.perform(.request(operation: "process.start", payload: .object(["path": .string("/bin/sleep"), "arguments": .array([.string("1")]) ])))
        let id = try #require(started.objectValue?["jobID"]?.stringValue)
        let status = try await agent.perform(.request(operation: "process.status", payload: .object(["jobID": .string(id)])))
        #expect(status.objectValue?["jobID"]?.stringValue == id)
        _ = try await agent.perform(.request(operation: "process.signal", payload: .object(["jobID": .string(id), "signal": .integer(Int64(SIGTERM))])))
    }

    @Test("Buffered execution keeps stdout and stderr separate")
    func bufferedStreams() async throws {
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        let started = try await agent.perform(.request(operation: "process.start", payload: .object(["path": .string("/bin/sh"), "arguments": .array([.string("-c"), .string("printf out; printf err >&2")]) ])))
        let id = try #require(started.objectValue?["jobID"]?.stringValue)
        let jobID = try #require(UUID(uuidString: id))
        let requestID = UUID()
        var events: [PommeAgentStreamFrame] = []
        // A real child needs wall-clock time to exit; yielding alone can
        // finish every poll before the process has run.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !events.contains(where: { $0.stream == .exit }), ContinuousClock.now < deadline {
            events += try await agent.streamEvents(jobID: jobID, requestID: requestID)
            if !events.contains(where: { $0.stream == .exit }) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let stdout = events
            .filter { $0.stream == .stdout }
            .compactMap(\.data)
            .reduce(into: Data()) { $0.append(contentsOf: $1) }
        let stderr = events
            .filter { $0.stream == .stderr }
            .compactMap(\.data)
            .reduce(into: Data()) { $0.append(contentsOf: $1) }
        let exitIndex = try #require(events.firstIndex { $0.stream == .exit })
        #expect(stdout == Data("out".utf8))
        #expect(stderr == Data("err".utf8))
        #expect(events[..<exitIndex].contains { $0.stream == .stdout })
        #expect(events[..<exitIndex].contains { $0.stream == .stderr })
        #expect(events[exitIndex].requestID == requestID)
    }

    @Test("PTY receives resize, signal, and terminal output")
    func ptyStreams() async throws {
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        let started = try await agent.perform(.request(operation: "process.start", payload: .object(["path": .string("/bin/sh"), "arguments": .array([.string("-c"), .string("printf pty; sleep 5")]), "pty": .bool(true)])))
        let id = try #require(started.objectValue?["jobID"]?.stringValue); let jobID = try #require(UUID(uuidString: id)); let requestID = UUID()
        try await agent.resizePTY(jobID: jobID, columns: 120, rows: 40)
        var events = try await agent.streamEvents(jobID: jobID, requestID: requestID)
        for _ in 0..<20 where !events.contains(where: { $0.stream == .stdout }) {
            try await Task.sleep(for: .milliseconds(10))
            events += try await agent.streamEvents(jobID: jobID, requestID: requestID)
        }
        events += try await agent.acceptStream(.init(requestID: requestID, stream: .signal, signal: SIGTERM), jobID: jobID)
        for _ in 0..<200 where !events.contains(where: { $0.stream == .exit }) {
            try await Task.sleep(for: .milliseconds(25))
            events += try await agent.streamEvents(jobID: jobID, requestID: requestID)
        }
        #expect(events.contains { $0.requestID == requestID && $0.stream == .stdout })
        #expect(events.contains { $0.requestID == requestID && $0.stream == .exit })
    }

    @Test("Identity selectors are mutually exclusive")
    func privilegeValidation() throws {
        #expect(throws: PommeAgentOperationError.self) {
            _ = try PommePrivilege.resolve(["user": .string("root"), "uid": .integer(0)])
        }
        #expect(throws: PommeAgentOperationError.self) {
            _ = try PommePrivilege.resolve(["group": .string("wheel"), "gid": .integer(0)])
        }
    }
}
