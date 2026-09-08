import CryptoKit
import Foundation
import Testing

@Suite("Pomme file commit recovery")
struct PommeFileCommitRecoveryTests {
    @Test("A publish race reports the published cleanup error and preserves the retired entry")
    func publishedCleanupRaceIsTypedAndPreservesRetiredEntry() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("destination")
        let stage = root.appendingPathComponent(".pomme-stage-race")
        let original = Data("original destination".utf8)
        let replacement = Data("replacement bytes".utf8)
        let marker = Data("retired marker".utf8)
        try original.write(to: destination)
        try replacement.write(to: stage)

        var observedPublishedCleanupFailure = false
        do {
            try PommeAgentFileTransaction.commit(
                stage: stage,
                destination: destination,
                beforePublish: {
                    try FileManager.default.removeItem(at: destination)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    try marker.write(to: destination.appendingPathComponent("marker"))
                }
            )
            Issue.record("A destination replacement race unexpectedly committed without a cleanup error.")
        } catch PommeAgentFileTransaction.CommitError.destinationPublishedCleanupFailed {
            observedPublishedCleanupFailure = true
        } catch {
            Issue.record("The destination replacement race returned the wrong error: \(error.localizedDescription)")
        }

        #expect(observedPublishedCleanupFailure)
        #expect(try Data(contentsOf: destination) == replacement)

        var stageIsDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: stage.path, isDirectory: &stageIsDirectory))
        #expect(stageIsDirectory.boolValue)
        #expect(try Data(contentsOf: stage.appendingPathComponent("marker")) == marker)
    }

    @Test("A moved staging parent remains abortable by its original file handle")
    func movedStagingParentRetainsCleanupHandle() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = root.appendingPathComponent("staging-parent", isDirectory: true)
        let movedParent = root.appendingPathComponent("staging-parent-away", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("destination")
        let original = Data("prior destination".utf8)
        let bytes = Data("staged bytes".utf8)
        try original.write(to: destination)

        let agent = try makeAgent()
        let fileID = try await openStage(agent: agent, destination: destination)
        try await write(bytes, to: fileID, using: agent)

        try FileManager.default.moveItem(at: parent, to: movedParent)
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(
                operation: "file.commit",
                payload: commitPayload(fileID: fileID, bytes: bytes, digest: digest(of: bytes))
            ))
        }
        #expect(stageFiles(in: movedParent).count == 1)

        try FileManager.default.moveItem(at: movedParent, to: parent)
        let aborted = try await agent.perform(.request(
            operation: "file.abort",
            payload: .object(["fileID": .string(fileID)])
        ))
        #expect(aborted == .object(["aborted": .bool(true)]))
        #expect(stageFiles(in: parent).isEmpty)
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("A digest mismatch can be followed by one verified abort")
    func digestMismatchCompletesCleanupBeforeAbort() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = root.appendingPathComponent("staging-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("destination")
        let original = Data("prior destination".utf8)
        let bytes = Data("staged bytes".utf8)
        try original.write(to: destination)

        let agent = try makeAgent()
        let fileID = try await openStage(agent: agent, destination: destination)
        try await write(bytes, to: fileID, using: agent)

        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(
                operation: "file.commit",
                payload: commitPayload(
                    fileID: fileID,
                    bytes: bytes,
                    digest: String(repeating: "0", count: 64)
                )
            ))
        }
        #expect(stageFiles(in: parent).isEmpty)
        #expect(try Data(contentsOf: destination) == original)

        let aborted = try await agent.perform(.request(
            operation: "file.abort",
            payload: .object(["fileID": .string(fileID)])
        ))
        #expect(aborted == .object(["aborted": .bool(true)]))
        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await agent.perform(.request(
                operation: "file.abort",
                payload: .object(["fileID": .string(fileID)])
            ))
        }
        #expect(stageFiles(in: parent).isEmpty)
        #expect(try Data(contentsOf: destination) == original)
    }
}

private func makeDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pomme-file-commit-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private func makeAgent() throws -> PommeAgent {
    try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
}

private func openStage(agent: PommeAgent, destination: URL) async throws -> String {
    let opened = try await agent.perform(.request(operation: "file.open", payload: .object([
        "path": .string(destination.path),
        "mode": .string("stageWrite")
    ])))
    return try #require(opened.objectValue?["fileID"]?.stringValue)
}

private func write(_ bytes: Data, to fileID: String, using agent: PommeAgent) async throws {
    let result = try await agent.perform(.request(operation: "file.write", payload: .object([
        "fileID": .string(fileID),
        "dataBase64": .string(bytes.base64EncodedString())
    ])))
    #expect(result == .object(["count": .integer(Int64(bytes.count))]))
}

private func commitPayload(fileID: String, bytes: Data, digest: String) -> JSONValue {
    .object([
        "fileID": .string(fileID),
        "expectedBytes": .integer(Int64(bytes.count)),
        "expectedSHA256": .string(digest)
    ])
}

private func digest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func stageFiles(in directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter {
        $0.hasPrefix(".pomme-stage-")
    } ?? []
}
