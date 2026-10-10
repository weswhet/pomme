import Darwin
import Foundation
import Testing

@Suite("Pomme agent failure reasons")
struct PommeAgentFailureReasonTests {
    private func failure(
        _ operation: String,
        _ payload: JSONValue = .object([:])
    ) async throws -> (code: String, message: String)? {
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        do {
            _ = try await agent.perform(.request(operation: operation, payload: payload))
            return nil
        } catch {
            return PommeAgentConnection.operationFailure(error)
        }
    }

    @Test("An unknown operation names the operation")
    func unknownOperationIsNamed() async throws {
        let failure = try #require(try await failure("pomme.no-such-operation"))
        #expect(failure.code == "unsupported-operation")
        #expect(failure.message == "The guest agent doesn't support pomme.no-such-operation")
    }

    @Test("A missing file ID names the ID")
    func missingFileIsNamed() async throws {
        let id = UUID()
        let failure = try #require(try await failure(
            "file.read",
            .object(["fileID": .string(id.uuidString.lowercased()), "count": .integer(1)])
        ))
        #expect(failure.code == "not-found")
        #expect(failure.message == "No open file has ID \(id.uuidString.lowercased())")
    }

    @Test("A rejected request value names the field and the rule")
    func invalidValuesAreNamed() async throws {
        let conflicting = try #require(try await failure(
            "process.start",
            .object([
                "path": .string("/usr/bin/true"), "arguments": .array([]),
                "pty": .bool(true), "detached": .bool(true)
            ])
        ))
        #expect(conflicting.code == "invalid-operation")
        #expect(conflicting.message == "process.start can't combine pty and detached")

        let seek = try #require(try await failure(
            "file.seek",
            .object(["fileID": .string("not-a-uuid"), "offset": .integer(0), "whence": .string("set")])
        ))
        #expect(seek.code == "invalid-operation")
        #expect(seek.message == "fileID must be a UUID")

        let list = try #require(try await failure("process.list", .object(["extra": .bool(true)])))
        #expect(list.message == "process.list accepts no fields")
    }

    @Test("An environment failure never echoes the variable's name or value")
    func environmentFailureOmitsValues() async throws {
        let failure = try #require(try await failure(
            "process.start",
            .object([
                "path": .string("/usr/bin/true"), "arguments": .array([]),
                "environment": .object(["9POMME_PRIVATE": .string("hunter2-value")])
            ])
        ))
        #expect(failure.code == "invalid-operation")
        #expect(failure.message.hasPrefix("Environment variable names must be"))
        #expect(!failure.message.contains("9POMME_PRIVATE"))
        #expect(!failure.message.contains("hunter2-value"))
    }

    @Test("An I/O failure carries the operation and the errno text")
    func ioFailureCarriesErrno() {
        let failure = PommeAgentConnection.operationFailure(
            PommeAgentOperationError.io("fsync of the open file", errno: EIO)
        )
        #expect(failure.code == "operation-failed")
        #expect(failure.message == "fsync of the open file failed: \(String(cString: strerror(EIO))) (errno \(EIO))")
        #expect(PommeAgentOperationError.io("fsync of the open file", errno: EIO).kind == .io)
    }
}
