import Foundation
import Testing

@Suite("Recovery file system flush")
struct PommeRecoveryFileSystemFlushTests {
    private static let token = String(repeating: "a", count: 64)
    private static let binding = try! PommeAgentVSOCKBinding(
        vmID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        sessionID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )

    @Test("A sync that exits 0 through the resident flushes Recovery and releases its terminal")
    func successfulSync() async throws {
        let (coordinator, resident) = try await connectedResident(exitCode: 0)
        defer { coordinator.teardown() }

        #expect(await PommeRecoveryFileSystemFlush.run(coordinator: coordinator, vmName: "test"))
        #expect(resident.created == [["/bin/sh", "-c", "/bin/sync"]])
        #expect(resident.released == 1)
    }

    @Test("A sync that fails leaves the stop to its usual window")
    func failedSync() async throws {
        let (coordinator, resident) = try await connectedResident(exitCode: 127)
        defer { coordinator.teardown() }

        #expect(await PommeRecoveryFileSystemFlush.run(coordinator: coordinator, vmName: "test") == false)
        #expect(resident.released == 1)
    }

    @Test("A sync that doesn't finish in time isn't treated as a flush")
    func unfinishedSync() async throws {
        let (coordinator, _) = try await connectedResident(exitCode: nil)
        defer { coordinator.teardown() }

        #expect(await PommeRecoveryFileSystemFlush.run(coordinator: coordinator, vmName: "test", timeout: 0.3) == false)
    }

    @Test("Without a connected Recovery agent there is nothing to flush through")
    func noAgent() async throws {
        #expect(await PommeRecoveryFileSystemFlush.run(coordinator: nil, vmName: "test") == false)

        let coordinator = PommeAgentVSOCKCoordinator(
            transport: FlushTransport(),
            secretProvider: { _ in Self.token },
            bindingProvider: { _ in Self.binding }
        )
        try coordinator.attachRecoveryResident()
        defer { coordinator.teardown() }
        #expect(await PommeRecoveryFileSystemFlush.run(coordinator: coordinator, vmName: "test", timeout: 0.3) == false)
    }

    @Test("A stop soon after Recovery starts waits for the resident to connect")
    func residentConnectsLate() async throws {
        let transport = FlushTransport()
        let coordinator = PommeAgentVSOCKCoordinator(
            transport: transport,
            secretProvider: { _ in Self.token },
            bindingProvider: { _ in Self.binding }
        )
        try coordinator.attachRecoveryResident()
        defer { coordinator.teardown() }
        let resident = FlushResident(token: Self.token, exitCode: 0)
        Task {
            try await Task.sleep(for: .milliseconds(300))
            transport.connect(resident, port: PommeAgentVSOCKRole.recoveryResident.port)
        }

        #expect(await PommeRecoveryFileSystemFlush.run(coordinator: coordinator, vmName: "test", timeout: 5))
        #expect(resident.created == [["/bin/sh", "-c", "/bin/sync"]])
    }

    @Test("Ordinary Recovery doesn't wait for an agent that connects only for a terminal")
    func ordinaryRecoveryDoesNotWait() async throws {
        let coordinator = PommeAgentVSOCKCoordinator(
            transport: FlushTransport(),
            secretProvider: { _ in Self.token },
            bindingProvider: { _ in Self.binding }
        )
        try coordinator.attachRecoveryRuntime()
        defer { coordinator.teardown() }
        let started = Date()
        #expect(await PommeRecoveryFileSystemFlush.run(coordinator: coordinator, vmName: "test", timeout: 5) == false)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    private func connectedResident(
        exitCode: Int64?
    ) async throws -> (PommeAgentVSOCKCoordinator, FlushResident) {
        let transport = FlushTransport()
        let coordinator = PommeAgentVSOCKCoordinator(
            transport: transport,
            secretProvider: { _ in Self.token },
            bindingProvider: { _ in Self.binding }
        )
        try coordinator.attachRecoveryResident()
        let resident = FlushResident(token: Self.token, exitCode: exitCode)
        transport.connect(resident, port: PommeAgentVSOCKRole.recoveryResident.port)
        for _ in 0..<200 where !coordinator.isAuthenticated(as: .recoveryResident) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.isAuthenticated(as: .recoveryResident))
        return (coordinator, resident)
    }
}

private final class FlushTransport: PommeAgentVSOCKTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var accepts: [UInt32: @Sendable (any PommeAgentVSOCKConnection) -> Void] = [:]

    func install(port: UInt32, accept: @escaping @Sendable (any PommeAgentVSOCKConnection) -> Void) throws {
        lock.withLock { accepts[port] = accept }
    }
    func remove(port: UInt32) { lock.withLock { _ = accepts.removeValue(forKey: port) } }
    func connect(_ connection: any PommeAgentVSOCKConnection, port: UInt32) { lock.withLock { accepts[port] }?(connection) }
}

/// Answers authentication and the terminal operations the flush uses. A nil
/// exit code keeps the sync running forever.
private final class FlushResident: PommeAgentVSOCKConnection, @unchecked Sendable {
    private let token: String
    private let exitCode: Int64?
    private let lock = NSLock()
    private var storedCreated: [[String]] = []
    private var storedReleased = 0
    var created: [[String]] { lock.withLock { storedCreated } }
    var released: Int { lock.withLock { storedReleased } }

    init(token: String, exitCode: Int64?) {
        self.token = token
        self.exitCode = exitCode
    }

    func exchange(_ request: Data, timeout: TimeInterval) async throws -> Data {
        let envelope = try PommeAgentProtocol.decode(Data(request.dropLast()))
        let payload = envelope.payload.objectValue ?? [:]
        switch envelope.operation {
        case "authenticate":
            let challenge = payload["challenge"]?.stringValue ?? ""
            let proof = try PommeAgentAuthentication.proof(token: token, challenge: challenge)
            return try PommeAgentProtocol.encode(.response(to: envelope, result: .object(["proof": .string(proof)])))
        case "agent.describe":
            return try PommeAgentProtocol.encode(.response(to: envelope, result: .object([
                "version": .integer(Int64(PommeAgentProtocol.version)),
                "capabilities": .array(PommeAgent.recoveryTerminalCapabilities.map(JSONValue.string))
            ])))
        case "terminal.create":
            let command = [payload["path"]?.stringValue ?? ""]
                + (payload["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            lock.withLock { storedCreated.append(command) }
            return try PommeAgentProtocol.encode(.response(to: envelope, result: .object([
                "sessionID": payload["sessionID"] ?? .null, "pid": .integer(42), "exited": .bool(false)
            ])))
        case "terminal.status":
            var result: [String: JSONValue] = ["sessionID": payload["sessionID"] ?? .null, "exited": .bool(exitCode != nil)]
            if let exitCode { result["exitCode"] = .integer(exitCode) }
            return try PommeAgentProtocol.encode(.response(to: envelope, result: .object(result)))
        case "terminal.release":
            lock.withLock { storedReleased += 1 }
            return try PommeAgentProtocol.encode(.response(to: envelope, result: .object(["released": .bool(true)])))
        default:
            return try PommeAgentProtocol.encode(.failure(to: envelope, code: "unsupported", message: "test"))
        }
    }

    func close() {}
}
