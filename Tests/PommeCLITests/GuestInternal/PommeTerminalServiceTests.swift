import Foundation
import Testing

@Suite("Pomme terminal service")
struct PommeTerminalServiceTests {
    @Test("PTY output is replayable byte-for-byte beyond one stream chunk")
    func outputReplay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-terminal-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = try PommeTerminalService(role: .persistent, spoolRoot: root)
        let id = UUID()
        _ = try await service.perform(
            operation: "terminal.create",
            payload: .object([
                "sessionID": .string(id.uuidString.lowercased()),
                "sequence": .integer(0),
                "mutationDigest": .string(String(repeating: "a", count: 64)),
                "path": .string("/bin/sh"),
                "arguments": .array([
                    .string("-c"),
                    .string("dd if=/dev/zero bs=100000 count=1 2>/dev/null")
                ]),
                "shell": .bool(false)
            ])
        )

        var output = Data()
        var offset: UInt64 = 0
        var reachedEOF = false
        for _ in 0..<300 where !reachedEOF {
            let result = try await service.perform(
                operation: "terminal.read",
                payload: .object([
                    "sessionID": .string(id.uuidString.lowercased()),
                    "offset": .integer(Int64(offset)),
                    "count": .integer(Int64(PommeAgentProtocol.maximumStreamChunkBytes))
                ])
            )
            guard let values = result.objectValue,
                  let encoded = values["dataBase64"]?.stringValue,
                  let data = Data(base64Encoded: encoded),
                  let next = values["nextOffset"].flatMap(Self.uint64Value),
                  let eof = Self.boolValue(values["eof"])
            else {
                Issue.record("terminal.read returned an invalid result")
                break
            }
            output.append(data)
            offset = next
            reachedEOF = eof
            _ = try await service.perform(
                operation: "terminal.ack",
                payload: .object([
                    "sessionID": .string(id.uuidString.lowercased()),
                    "offset": .integer(Int64(offset))
                ])
            )
            if !reachedEOF { try await Task.sleep(for: .milliseconds(10)) }
        }

        #expect(reachedEOF)
        #expect(output.count == 100_000)
        #expect(output.allSatisfy { $0 == 0 })
        _ = try? await service.perform(
            operation: "terminal.release",
            payload: .object(["sessionID": .string(id.uuidString.lowercased())])
        )
    }

    @Test("Recovery rejects identity overrides and accepts only its verified shell")
    func recoveryIdentityPolicy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-recovery-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try PommeTerminalService(role: .recovery, spoolRoot: root)

        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await service.perform(
                operation: "terminal.create",
                payload: .object([
                    "sessionID": .string(UUID().uuidString.lowercased()),
                    "sequence": .integer(0),
                    "mutationDigest": .string(String(repeating: "b", count: 64)),
                    "shell": .bool(true),
                    "user": .string("root")
                ])
            )
        }
    }

    @Test("Terminal mutations are idempotent and reject skipped sequences")
    func mutationSequencing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-terminal-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try PommeTerminalService(role: .persistent, spoolRoot: root)
        let id = UUID()
        let createPayload: JSONValue = .object([
            "sessionID": .string(id.uuidString.lowercased()),
            "sequence": .integer(0),
            "mutationDigest": .string(String(repeating: "c", count: 64)),
            "path": .string("/bin/sh"),
            "arguments": .array([.string("-c"), .string("read value")]),
            "shell": .bool(false)
        ])
        _ = try await service.perform(operation: "terminal.create", payload: createPayload)

        let digest = String(repeating: "d", count: 64)
        let input: JSONValue = .object([
            "sessionID": .string(id.uuidString.lowercased()),
            "sequence": .integer(1),
            "mutationDigest": .string(digest),
            "dataBase64": .string(Data("ok\n".utf8).base64EncodedString())
        ])
        let first = try await service.perform(operation: "terminal.input", payload: input)
        let retry = try await service.perform(operation: "terminal.input", payload: input)
        #expect(first == retry)

        await #expect(throws: PommeAgentOperationError.self) {
            _ = try await service.perform(
                operation: "terminal.input",
                payload: .object([
                    "sessionID": .string(id.uuidString.lowercased()),
                    "sequence": .integer(3),
                    "mutationDigest": .string(String(repeating: "e", count: 64)),
                    "dataBase64": .string(Data("skipped\n".utf8).base64EncodedString())
                ])
            )
        }
        _ = try? await service.perform(
            operation: "terminal.terminate",
            payload: .object([
                "sessionID": .string(id.uuidString.lowercased()),
                "sequence": .integer(2),
                "mutationDigest": .string(String(repeating: "f", count: 64)),
                "force": .bool(true)
            ])
        )
        _ = try? await service.perform(
            operation: "terminal.release",
            payload: .object(["sessionID": .string(id.uuidString.lowercased())])
        )
    }

    private static func uint64Value(_ value: JSONValue?) -> UInt64? {
        guard case .integer(let value) = value, value >= 0 else { return nil }
        return UInt64(exactly: value)
    }

    private static func boolValue(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value) = value else { return nil }
        return value
    }
}
