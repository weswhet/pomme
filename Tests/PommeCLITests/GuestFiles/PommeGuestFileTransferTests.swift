import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Pomme guest file transfer")
struct PommeGuestFileTransferTests {
    @Test(
        "Host uploads preserve binary bytes at every transfer boundary",
        arguments: [0, PommeAgentProtocol.maximumFileChunkBytes, PommeAgentProtocol.maximumFileChunkBytes * 2 + 1]
    )
    func uploadSizes(_ size: Int) async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host", isDirectory: true)
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)

        let bytes = binaryData(count: size)
        let old = Data("previous guest destination".utf8)
        let source = host.appendingPathComponent("source.bin")
        let destination = guest.appendingPathComponent("destination.bin")
        try bytes.write(to: source)
        try old.write(to: destination)

        let agent = try PommeAgent(role: .persistent, executableSHA256: testDigest)
        let outcome = try await agent.copyForTransferTests(
            CopyRequest(source: .host(source), destination: .guest(destination.path))
        )

        #expect(outcome.bytes == UInt64(size))
        #expect(outcome.sha256 == digest(of: bytes))
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(outcome.operations.map(\.operation).first == "file.open")
        #expect(outcome.operations.map(\.operation).last == "file.commit")
        #expect(!outcome.operations.map(\.operation).contains("file.abort"))

        let writes = outcome.operations.filter { $0.operation == "file.write" }
        let expectedWriteCount = size == 0
            ? 0
            : (size + PommeAgentProtocol.maximumFileChunkBytes - 1) / PommeAgentProtocol.maximumFileChunkBytes
        #expect(writes.count == expectedWriteCount)
        for write in writes {
            let payload = try #require(write.payload.objectValue)
            let encoded = try #require(payload["dataBase64"]?.stringValue)
            let chunk = try #require(Data(base64Encoded: encoded))
            #expect(chunk.count > 0)
            #expect(chunk.count <= PommeAgentProtocol.maximumFileChunkBytes)
        }
        assertNoHostEndpoints(outcome.operations, forbiddenPath: source.path)
    }

    @Test(
        "Guest downloads replace regular destinations in bounded chunks",
        arguments: [0, PommeAgentProtocol.maximumFileChunkBytes, PommeAgentProtocol.maximumFileChunkBytes * 2 + 1]
    )
    func downloadSizes(_ size: Int) async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host", isDirectory: true)
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)

        let bytes = binaryData(count: size)
        let old = Data("previous destination".utf8)
        let source = guest.appendingPathComponent("source.bin")
        let destination = host.appendingPathComponent("destination.bin")
        try bytes.write(to: source)
        try old.write(to: destination)

        let agent = try PommeAgent(role: .persistent, executableSHA256: testDigest)
        let outcome = try await agent.copyForTransferTests(
            CopyRequest(source: .guest(source.path), destination: .host(destination))
        )

        #expect(outcome.bytes == UInt64(size))
        #expect(outcome.sha256 == digest(of: bytes))
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(outcome.operations.map(\.operation).first == "file.open")
        #expect(outcome.operations.map(\.operation).last == "file.close")
        #expect(!outcome.operations.map(\.operation).contains("file.abort"))

        let reads = outcome.operations.filter { $0.operation == "file.read" }
        let expectedReadCount = size == 0
            ? 0
            : (size + PommeAgentProtocol.maximumFileChunkBytes - 1) / PommeAgentProtocol.maximumFileChunkBytes
        #expect(reads.count == expectedReadCount)
        for read in reads {
            let payload = try #require(read.payload.objectValue)
            guard case let .integer(count)? = payload["count"] else {
                Issue.record("The transfer sent a file.read request without an integer count.")
                continue
            }
            #expect(count > 0)
            #expect(count <= Int64(PommeAgentProtocol.maximumFileChunkBytes))
        }
        assertNoHostEndpoints(outcome.operations, forbiddenPath: destination.path)
    }

    @Test("cat reads offsets, reports EOF, and permits a zero-byte read")
    func catReadsBoundedRanges() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        let bytes = binaryData(count: 23)
        let path = guest.appendingPathComponent("cat.bin")
        try bytes.write(to: path)
        let agent = try PommeAgent(role: .persistent, executableSHA256: testDigest)

        let cases: [(offset: Int, count: Int, expected: Data, eof: Bool)] = [
            (4, 6, bytes.subdata(in: 4..<10), false),
            (bytes.count - 3, 10, bytes.suffix(3), true),
            (bytes.count + 2, 4, Data(), true),
            (2, 0, Data(), false)
        ]
        for testCase in cases {
            let outcome = try await agent.catForTransferTests(
                CatRequest(guestPath: path.path, offset: testCase.offset, count: testCase.count)
            )
            let payload = try #require(outcome.payload.objectValue)
            let encoded = try #require(payload["dataBase64"]?.stringValue)
            #expect(Data(base64Encoded: encoded) == testCase.expected)
            #expect(try CLIOutputWriter.fileOutput(payload.mapValues(\.publicValue)) == testCase.expected)
            #expect(payload["bytes"] == .integer(Int64(testCase.expected.count)))
            #expect(payload["offset"] == .integer(Int64(testCase.offset)))
            #expect(payload["eof"] == .bool(testCase.eof))
            #expect(payload["operation"] == .string("file.read"))
            #expect(outcome.operations.map(\.operation) == ["file.open", "file.seek", "file.read", "file.close"])
            assertNoHostEndpoints(outcome.operations)
        }
    }

    @Test("The documented /etc/hosts guest path is readable")
    func readsEtcHosts() async throws {
        let path = "/etc/hosts"
        let expected = try Data(contentsOf: URL(fileURLWithPath: path))
        let agent = try PommeAgent(role: .persistent, executableSHA256: testDigest)
        let outcome = try await agent.catForTransferTests(
            CatRequest(guestPath: path, offset: 0, count: PommeAgentProtocol.maximumFileChunkBytes)
        )
        let payload = try #require(outcome.payload.objectValue)
        let encoded = try #require(payload["dataBase64"]?.stringValue)
        #expect(Data(base64Encoded: encoded) == expected)
        #expect(payload["eof"] == .bool(true))
        assertNoHostEndpoints(outcome.operations)
    }

    @Test("Symlink sources, ancestors, and guest paths are rejected without mutation")
    func rejectsSymlinkSourcesAndAncestors() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host", isDirectory: true)
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let bytes = Data("safe bytes".utf8)
        let outsideSource = outside.appendingPathComponent("source.bin")
        try bytes.write(to: outsideSource)
        let guestDestination = guest.appendingPathComponent("destination.bin")
        let agent = try PommeAgent(role: .persistent, executableSHA256: testDigest)

        let sourceLink = host.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: outsideSource)
        await #expect(throws: Error.self) {
            _ = try await agent.copyForTransferTests(
                CopyRequest(source: .host(sourceLink), destination: .guest(guestDestination.path))
            )
        }
        #expect(!FileManager.default.fileExists(atPath: guestDestination.path))

        let linkedParent = host.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        let ancestorSource = linkedParent.appendingPathComponent("source.bin")
        await #expect(throws: Error.self) {
            _ = try await agent.copyForTransferTests(
                CopyRequest(source: .host(ancestorSource), destination: .guest(guestDestination.path))
            )
        }
        #expect(!FileManager.default.fileExists(atPath: guestDestination.path))

        let guestSourceLink = guest.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: guestSourceLink, withDestinationURL: outsideSource)
        let hostDestination = host.appendingPathComponent("download.bin")
        let old = Data("unchanged".utf8)
        try old.write(to: hostDestination)
        await #expect(throws: Error.self) {
            _ = try await agent.copyForTransferTests(
                CopyRequest(source: .guest(guestSourceLink.path), destination: .host(hostDestination))
            )
        }
        #expect(try Data(contentsOf: hostDestination) == old)
        #expect(noStageFiles(in: host))

        let fifo = host.appendingPathComponent("source.fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: Error.self) {
            _ = try await agent.copyForTransferTests(
                CopyRequest(source: .host(fifo), destination: .guest(guestDestination.path))
            )
        }
        #expect(!FileManager.default.fileExists(atPath: guestDestination.path))
    }

    @Test("Destination symlinks and directories are preserved")
    func preservesUnsafeDestinations() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host", isDirectory: true)
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let bytes = binaryData(count: 40)
        let source = host.appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let guestTarget = guest.appendingPathComponent("target.bin")
        let guestOutside = outside.appendingPathComponent("guest-target.bin")
        let oldGuest = Data("old guest".utf8)
        try oldGuest.write(to: guestOutside)
        try FileManager.default.createSymbolicLink(at: guestTarget, withDestinationURL: guestOutside)

        let agent = try PommeAgent(role: .persistent, executableSHA256: testDigest)
        await expectRunnerFailure {
            try await agent.copyForTransferTests(
                CopyRequest(source: .host(source), destination: .guest(guestTarget.path))
            )
        }
        #expect(try Data(contentsOf: guestOutside) == oldGuest)
        #expect(FileManager.default.fileExists(atPath: guestTarget.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: guestTarget.path)) != nil)
        #expect(noStageFiles(in: guest))

        let guestSource = guest.appendingPathComponent("source.bin")
        try bytes.write(to: guestSource)
        let hostOutside = outside.appendingPathComponent("host-target.bin")
        let oldHost = Data("old host".utf8)
        try oldHost.write(to: hostOutside)
        let hostTargetLink = host.appendingPathComponent("target-link.bin")
        try FileManager.default.createSymbolicLink(at: hostTargetLink, withDestinationURL: hostOutside)
        await expectRunnerFailure {
            try await agent.copyForTransferTests(
                CopyRequest(source: .guest(guestSource.path), destination: .host(hostTargetLink))
            )
        }
        #expect(try Data(contentsOf: hostOutside) == oldHost)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: hostTargetLink.path)) != nil)
        #expect(noStageFiles(in: host))

        let directoryTarget = host.appendingPathComponent("target-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: true)
        let marker = directoryTarget.appendingPathComponent("marker")
        try Data("marker".utf8).write(to: marker)
        await expectRunnerFailure {
            try await agent.copyForTransferTests(
                CopyRequest(source: .guest(guestSource.path), destination: .host(directoryTarget))
            )
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directoryTarget.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try Data(contentsOf: marker) == Data("marker".utf8))
        #expect(noStageFiles(in: host))
    }

    @Test(
        "Upload failures reject malformed write and commit receipts and abort the guest stage",
        arguments: [TransferInjection.writeFailure, .malformedWrite, .malformedCommit]
    )
    fileprivate func uploadFailures(injection: TransferInjection) async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host", isDirectory: true)
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        let source = host.appendingPathComponent("source.bin")
        let destination = guest.appendingPathComponent("destination.bin")
        let old = Data("prior guest destination".utf8)
        try Data(repeating: 0xA5, count: PommeAgentProtocol.maximumFileChunkBytes + 7).write(to: source)
        try old.write(to: destination)

        let agent = try PommeAgent(role: .persistent, executableSHA256: testDigest)
        do {
            _ = try await agent.copyForTransferTests(
                CopyRequest(source: .host(source), destination: .guest(destination.path)),
                injection: injection
            )
            Issue.record("An injected transfer failure unexpectedly succeeded.")
        } catch let failure as RecordedTransferFailure {
            #expect(failure.runnerError)
            #expect(failure.operations.last?.operation == "file.abort")
        } catch {
            Issue.record("The transfer returned an unexpected error: \(error.localizedDescription)")
        }
        #expect(try Data(contentsOf: destination) == old)
        #expect(noStageFiles(in: guest))
    }

    @Test(
        "Download read failures remove their stage and preserve the destination",
        arguments: [TransferInjection.readFailure, .malformedRead]
    )
    fileprivate func downloadReadFailure(injection: TransferInjection) async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host", isDirectory: true)
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        let source = guest.appendingPathComponent("source.bin")
        let destination = host.appendingPathComponent("destination.bin")
        let old = Data("prior host destination".utf8)
        try Data(repeating: 0x5A, count: PommeAgentProtocol.maximumFileChunkBytes + 3).write(to: source)
        try old.write(to: destination)

        let agent = try PommeAgent(role: .persistent, executableSHA256: testDigest)
        do {
            _ = try await agent.copyForTransferTests(
                CopyRequest(source: .guest(source.path), destination: .host(destination)),
                injection: injection
            )
            Issue.record("An injected read failure unexpectedly succeeded.")
        } catch let failure as RecordedTransferFailure {
            #expect(failure.runnerError)
            #expect(failure.operations.last?.operation == "file.close")
        } catch {
            Issue.record("The transfer returned an unexpected error: \(error.localizedDescription)")
        }
        #expect(try Data(contentsOf: destination) == old)
        #expect(noStageFiles(in: host))
    }

    @Test("Cleanup failures are included in the transfer error")
    func cleanupFailureIsReported() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host", isDirectory: true)
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        let source = host.appendingPathComponent("source.bin")
        let destination = guest.appendingPathComponent("destination.bin")
        let old = Data("prior destination".utf8)
        try Data("replacement".utf8).write(to: source)
        try old.write(to: destination)

        let agent = try PommeAgent(role: .persistent, executableSHA256: testDigest)
        do {
            _ = try await agent.copyForTransferTests(
                CopyRequest(source: .host(source), destination: .guest(destination.path)),
                injection: .cleanupFailure
            )
            Issue.record("A transfer with an injected primary and cleanup failure unexpectedly succeeded.")
        } catch let failure as RecordedTransferFailure {
            #expect(failure.runnerError)
            #expect(!failure.cleanupErrors.isEmpty)
        } catch {
            Issue.record("The transfer returned an unexpected error: \(error.localizedDescription)")
        }
        #expect(try Data(contentsOf: destination) == old)
    }
}

fileprivate enum TransferInjection: String, CaseIterable, Sendable {
    case writeFailure
    case readFailure
    case malformedWrite
    case malformedRead
    case malformedCommit
    case cleanupFailure
}

private enum TransferTestError: Error, Sendable {
    case injectedPrimary
    case injectedCleanup
}

private struct RecordedOperation: Sendable {
    let operation: String
    let payload: JSONValue
}

private final class TransferOperationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedOperation] = []

    func append(_ operation: RecordedOperation) {
        lock.withLock { storage.append(operation) }
    }

    var values: [RecordedOperation] { lock.withLock { storage } }
}

private struct CopyOutcome: Sendable {
    let bytes: UInt64
    let sha256: String
    let operations: [RecordedOperation]
}

private struct CatOutcome: Sendable {
    let payload: JSONValue
    let operations: [RecordedOperation]
}

private struct RecordedTransferFailure: Error, Sendable {
    let description: String
    let runnerError: Bool
    let cleanupErrors: [String]
    let operations: [RecordedOperation]

    var localizedDescription: String { description }
}

private let testDigest = String(repeating: "a", count: 64)

private extension PommeAgent {
    func copyForTransferTests(
        _ request: CopyRequest,
        injection: TransferInjection? = nil
    ) throws -> CopyOutcome {
        let operations = TransferOperationLog()
        let transfer = PommeGuestFileTransfer { operation, payload in
            operations.append(.init(operation: operation, payload: payload))
            switch (injection, operation) {
            case (.writeFailure, "file.write"), (.cleanupFailure, "file.write"):
                throw TransferTestError.injectedPrimary
            case (.malformedWrite, "file.write"):
                return .object(["count": .integer(0)])
            case (.malformedCommit, "file.commit"):
                return .object(["committed": .bool(false)])
            case (.readFailure, "file.read"):
                throw TransferTestError.injectedPrimary
            case (.malformedRead, "file.read"):
                return .object(["eof": .bool(true)])
            case (.cleanupFailure, "file.abort"):
                throw TransferTestError.injectedCleanup
            default:
                return try self.perform(.request(operation: operation, payload: payload))
            }
        }
        do {
            let receipt = try transfer.copy(request)
            return .init(bytes: receipt.bytes, sha256: receipt.sha256, operations: operations.values)
        } catch let error as RunnerError {
            let cleanupErrors: [String]
            if case let .guestFileTransferFailed(_, _, errors) = error {
                cleanupErrors = errors
            } else {
                cleanupErrors = []
            }
            throw RecordedTransferFailure(
                description: error.localizedDescription,
                runnerError: true,
                cleanupErrors: cleanupErrors,
                operations: operations.values
            )
        } catch {
            throw RecordedTransferFailure(
                description: error.localizedDescription,
                runnerError: false,
                cleanupErrors: [],
                operations: operations.values
            )
        }
    }

    func catForTransferTests(_ request: CatRequest) throws -> CatOutcome {
        let operations = TransferOperationLog()
        let transfer = PommeGuestFileTransfer { operation, payload in
            operations.append(.init(operation: operation, payload: payload))
            return try self.perform(.request(operation: operation, payload: payload))
        }
        return .init(payload: try JSONValue(any: transfer.cat(request)), operations: operations.values)
    }

}

private func makeDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pomme-file-transfer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private func binaryData(count: Int) -> Data {
    Data((0..<count).map { index in
        UInt8(truncatingIfNeeded: index &* 37 &+ 11)
    })
}

private func digest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func noStageFiles(in directory: URL) -> Bool {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.allSatisfy {
        !$0.hasPrefix(".pomme-stage-")
    } ?? false
}

private func expectRunnerFailure(
    _ operation: () async throws -> CopyOutcome
) async {
    do {
        _ = try await operation()
        Issue.record("An unsafe destination transfer unexpectedly succeeded.")
    } catch let failure as RecordedTransferFailure {
        #expect(failure.runnerError)
    } catch {
        Issue.record("The transfer returned an unexpected error: \(error.localizedDescription)")
    }
}

private func assertNoHostEndpoints(
    _ operations: [RecordedOperation],
    forbiddenPath: String? = nil
) {
    for operation in operations {
        guard let object = operation.payload.objectValue else {
            Issue.record("\(operation.operation) did not receive an object payload.")
            continue
        }
        #expect(object["source"] == nil)
        #expect(object["destination"] == nil)
        #expect(object["kind"] == nil)
        if let forbiddenPath {
            #expect(!jsonStrings(operation.payload).contains(forbiddenPath))
        }
    }
}

private func jsonStrings(_ value: JSONValue) -> [String] {
    switch value {
    case .string(let string): return [string]
    case .array(let values): return values.flatMap(jsonStrings)
    case .object(let values): return values.values.flatMap(jsonStrings)
    case .null, .bool, .integer, .number: return []
    }
}
