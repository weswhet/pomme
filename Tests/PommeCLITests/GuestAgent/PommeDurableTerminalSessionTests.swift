import Foundation
import Testing

@Suite("Durable terminal session state")
struct PommeDurableTerminalSessionTests {
    @Test("Control requests and host pages are closed and bounded")
    func closedControlAndPagination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-terminal-page-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PommeDurableTerminalSessionManager(
            role: .normal,
            vmPath: "/vm/page",
            rootURL: root,
            generation: UUID()
        )
        for pid in 1...2 {
            _ = try await manager.register(.init(
                sessionID: UUID(), role: .normal, bootGeneration: UUID(), pid: Int64(pid),
                executable: "/bin/sh", arguments: []
            ))
        }
        let first = try await manager.page(pageToken: nil, pageSize: 1)
        #expect(first.0.count == 1)
        let token = try #require(first.1)
        let second = try await manager.page(pageToken: token, pageSize: 1)
        #expect(second.0.count == 1)
        #expect(second.1 == nil)

        _ = try PommeTerminalSessionControlRequest.parse(from: [
            "operation": .string("terminal.list"),
            "pageSize": .integer(1)
        ])
        #expect(throws: Error.self) {
            _ = try PommeTerminalSessionControlRequest.parse(from: [
                "operation": .string("terminal.list"),
                "unexpected": .bool(true)
            ])
        }
        #expect(throws: Error.self) {
            _ = try PommeTerminalSessionControlRequest.parse(from: [
                "operation": .string("terminal.attach"),
                "sessionID": .string(UUID().uuidString),
                "offset": .number(1.5)
            ])
        }
    }

    @Test("Normal transcripts replay by byte offset and attachments are exclusive")
    func normalTranscriptAndAttachment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-terminal-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PommeDurableTerminalSessionManager(
            role: .normal,
            vmPath: "/vm/test",
            rootURL: root,
            generation: UUID()
        )
        let id = UUID()
        let record = try await manager.register(.init(
            sessionID: id,
            role: .normal,
            bootGeneration: UUID(),
            pid: 42,
            executable: "/bin/sh",
            arguments: ["-l"]
        ))
        #expect(record.transcriptOffset == 0)

        let bytes = Data((0..<100).map(UInt8.init))
        #expect(try await manager.append(bytes, sessionID: id) == 100)
        #expect(try await manager.read(id, from: 10, maximumBytes: 20) == Data(bytes[10..<30]))
        let (loggedRecord, loggedBytes) = try await manager.logs(id, from: 90)
        #expect(loggedRecord.transcriptOffset == 100)
        #expect(loggedBytes == Data(bytes[90..<100]))
        let (_, atEnd) = try await manager.logs(id, from: 100)
        #expect(atEnd.isEmpty)
        await #expect(throws: PommeDurableTerminalError.offsetBeyondEnd(offset: 101, length: 100)) {
            _ = try await manager.logs(id, from: 101)
        }

        let first = try await manager.attach(id, from: 0, takeover: false)
        await #expect(throws: PommeDurableTerminalError.attachmentBusy) {
            _ = try await manager.attach(id, from: nil, takeover: false)
        }
        let replacement = try await manager.attach(id, from: nil, takeover: true)
        await #expect(throws: PommeDurableTerminalError.attachmentReplaced) {
            _ = try await manager.isReplaced(first)
        }
        try await manager.markDelivered(replacement, offset: 100)
        try await manager.detach(replacement)
        try await manager.updateGuestStatus(
            id,
            exited: true,
            exitCode: 0,
            signal: nil,
            outputComplete: true,
            outputLength: 100,
            storageBlocked: false
        )
        #expect((try await manager.inspect(id)).state == .exited)
        try await manager.delete(id)
        #expect(await manager.list().isEmpty)
    }

    @Test("Recovery session storage is helper scoped and is not loaded by a new manager")
    func recoveryIsEphemeral() async throws {
        let id = UUID()
        let manager = PommeDurableTerminalSessionManager(
            role: .recovery,
            vmPath: "/vm/recovery",
            generation: UUID()
        )
        _ = try await manager.register(.init(
            sessionID: id,
            role: .recovery,
            bootGeneration: UUID(),
            pid: 43,
            executable: "/bin/sh",
            arguments: []
        ))
        _ = try await manager.append(Data("transient".utf8), sessionID: id)
        #expect((try await manager.logs(id, from: 0).1) == Data("transient".utf8))

        let replacement = PommeDurableTerminalSessionManager(
            role: .recovery,
            vmPath: "/vm/recovery",
            generation: UUID()
        )
        #expect(await replacement.list().isEmpty)
    }

    @Test("Guest completion waits for every host transcript chunk",
          arguments: [PommeDurableTerminalRole.normal, .recovery])
    func completionWaitsForHostTranscript(role: PommeDurableTerminalRole) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-terminal-final-chunk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PommeDurableTerminalSessionManager(
            role: role,
            vmPath: "/vm/final-chunk",
            rootURL: root,
            generation: UUID()
        )
        let id = UUID()
        _ = try await manager.register(.init(
            sessionID: id,
            role: role,
            bootGeneration: UUID(),
            pid: 44,
            executable: "/bin/sh",
            arguments: []
        ))

        let firstChunkLength = PommeControlProtocol.maximumStreamChunkBytes
        let totalLength = firstChunkLength + 34_472
        let expected = Data((0..<totalLength).map { UInt8($0 % 251) })
        let first = Data(expected.prefix(firstChunkLength))
        let final = Data(expected.suffix(totalLength - firstChunkLength))
        _ = try await manager.append(first, sessionID: id)
        try await manager.updateGuestStatus(
            id,
            exited: true,
            exitCode: 0,
            signal: nil,
            outputComplete: true,
            outputLength: UInt64(totalLength),
            storageBlocked: false
        )

        let pending = try await manager.inspect(id)
        #expect(pending.state == .detached)
        #expect(pending.transcriptOffset == UInt64(firstChunkLength))
        #expect(pending.acknowledgedOffset == 0)

        _ = try await manager.append(final, sessionID: id)
        try await manager.updateGuestStatus(
            id,
            exited: true,
            exitCode: 0,
            signal: nil,
            outputComplete: true,
            outputLength: UInt64(totalLength),
            storageBlocked: false
        )
        try await manager.acknowledgeGuest(id, offset: UInt64(totalLength))
        // An unknown acknowledgement outcome is safe to retry exactly.
        try await manager.acknowledgeGuest(id, offset: UInt64(totalLength))

        var replay = Data()
        var offset: UInt64 = 0
        while offset < UInt64(totalLength) {
            let chunk = try await manager.read(
                id,
                from: offset,
                maximumBytes: PommeControlProtocol.maximumStreamChunkBytes
            )
            #expect(!chunk.isEmpty)
            replay.append(chunk)
            offset += UInt64(chunk.count)
        }
        #expect(replay == expected)
        let complete = try await manager.inspect(id)
        #expect(complete.state == .exited)
        #expect(complete.transcriptOffset == UInt64(totalLength))
        #expect(complete.acknowledgedOffset == UInt64(totalLength))
    }
}
