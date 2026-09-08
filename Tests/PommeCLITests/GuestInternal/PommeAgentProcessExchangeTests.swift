import Darwin
import Foundation
import Testing

/// Each test starts a real daemon whose descriptor read blocks synchronously
/// between exchanges. Serialize the suite so concurrent tests cannot occupy
/// every cooperative worker thread; this suite does not assert daemon
/// cross-test concurrency.
@Suite("Pomme agent process exchanges", .serialized)
struct PommeAgentProcessExchangeTests: Sendable {
    @Test("Successful process exchanges put bounded output before the response")
    func processOutputPrecedesResponse() async throws {
        try await withDaemon { context in
            try await authenticate(using: context.wire)

            let start = PommeAgentProtocol.Envelope.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/bin/sh"),
                    "arguments": .array([
                        .string("-c"),
                        .string("printf stdout; printf stderr >&2")
                    ])
                ])
            )
            let started = try await exchange(start, using: context.wire)
            let jobText = try #require(started.response.result?.objectValue?["jobID"]?.stringValue)
            let jobID = try #require(UUID(uuidString: jobText))

            var frames = started.streams
            var completed = frames.contains { $0.frame.stream == .exit }
            for _ in 0..<32 where !completed {
                let status = PommeAgentProtocol.Envelope.request(
                    operation: "process.status",
                    payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
                )
                let result = try await exchange(status, using: context.wire)
                #expect(result.streams.filter { $0.frame.stream == .stdout }.count <= 1)
                #expect(result.streams.filter { $0.frame.stream == .stderr }.count <= 1)
                frames += result.streams
                completed = result.streams.contains { $0.frame.stream == .exit }
            }

            #expect(completed)
            #expect(frames.contains { $0.frame.stream == .stdout && $0.frame.data == Data("stdout".utf8) })
            #expect(frames.contains { $0.frame.stream == .stderr && $0.frame.data == Data("stderr".utf8) })
            #expect(frames.contains { $0.frame.stream == .exit })
        }
    }

    @Test("Large process output drains one chunk per stream before exit")
    func processOutputIsBoundedAndCompletionWaitsForDrain() async throws {
        try await withDaemon { context in
            try await authenticate(using: context.wire)

            let command = "dd if=/dev/zero bs=65536 count=2 2>/dev/null; dd if=/dev/zero bs=65536 count=2 1>&2 2>/dev/null"
            let start = PommeAgentProtocol.Envelope.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/bin/sh"),
                    "arguments": .array([.string("-c"), .string(command)])
                ])
            )
            let started = try await exchange(start, using: context.wire)
            let jobText = try #require(started.response.result?.objectValue?["jobID"]?.stringValue)
            let jobID = try #require(UUID(uuidString: jobText))

            var frames = started.streams
            var completed = frames.contains { $0.frame.stream == .exit }
            for _ in 0..<32 where !completed {
                let status = PommeAgentProtocol.Envelope.request(
                    operation: "process.status",
                    payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
                )
                let result = try await exchange(status, using: context.wire)
                let stdout = result.streams.filter { $0.frame.stream == .stdout }
                let stderr = result.streams.filter { $0.frame.stream == .stderr }
                #expect(stdout.count <= 1)
                #expect(stderr.count <= 1)
                #expect(stdout.allSatisfy { ($0.frame.data?.count ?? 0) <= PommeAgentProtocol.maximumStreamChunkBytes })
                #expect(stderr.allSatisfy { ($0.frame.data?.count ?? 0) <= PommeAgentProtocol.maximumStreamChunkBytes })
                #expect(result.streams.reduce(0) { $0 + ($1.frame.data?.count ?? 0) } <= 2 * PommeAgentProtocol.maximumStreamChunkBytes)
                frames += result.streams
                completed = result.streams.contains { $0.frame.stream == .exit }
            }

            let stdoutBytes = frames
                .filter { $0.frame.stream == .stdout }
                .reduce(0) { $0 + ($1.frame.data?.count ?? 0) }
            let stderrBytes = frames
                .filter { $0.frame.stream == .stderr }
                .reduce(0) { $0 + ($1.frame.data?.count ?? 0) }
            #expect(completed)
            #expect(stdoutBytes == 2 * 65536)
            #expect(stderrBytes == 2 * 65536)
            #expect(frames.contains { $0.frame.stream == .exit })
        }
    }

    @Test("Accepted stream mutations have a correlated response delimiter")
    func streamMutationIsAcknowledged() async throws {
        try await withDaemon { context in
            try await authenticate(using: context.wire)

            let start = PommeAgentProtocol.Envelope.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/bin/sh"),
                    "arguments": .array([
                        .string("-c"),
                        .string("read line; printf stream-out; printf stream-err >&2")
                    ])
                ])
            )
            let started = try await exchange(start, using: context.wire)
            let jobText = try #require(started.response.result?.objectValue?["jobID"]?.stringValue)
            let jobID = try #require(UUID(uuidString: jobText))

            let streamRequestID = UUID()
            let stream = try PommeAgentJobStreamFrame(
                jobID: jobID,
                frame: .init(
                    requestID: streamRequestID,
                    stream: .stdin,
                    data: Data("ready\n".utf8)
                )
            ).envelope()
            let acknowledged = try await exchange(stream, using: context.wire)
            #expect(acknowledged.response.ok == true)
            #expect(acknowledged.response.requestID == streamRequestID)
            #expect(acknowledged.response.operation == stream.operation)
            #expect(acknowledged.response.result?.objectValue?["jobID"]?.stringValue == jobID.uuidString.lowercased())

            var frames = started.streams + acknowledged.streams
            var completed = frames.contains { $0.frame.stream == .exit }
            for _ in 0..<32 where !completed {
                let status = PommeAgentProtocol.Envelope.request(
                    operation: "process.status",
                    payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
                )
                let result = try await exchange(status, using: context.wire)
                frames += result.streams
                completed = result.streams.contains { $0.frame.stream == .exit }
            }

            #expect(completed)
            #expect(frames.contains { $0.frame.stream == .stdout && $0.frame.data == Data("stream-out".utf8) })
            #expect(frames.contains { $0.frame.stream == .stderr && $0.frame.data == Data("stream-err".utf8) })
        }
    }

    @Test("PTY exchanges retain input, large terminal output, and nonzero exit status")
    func ptyOutputAndInputRemainCorrelated() async throws {
        try await withDaemon { context in
            try await authenticate(using: context.wire)
            let started = try await exchange(.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/bin/sh"),
                    "arguments": .array([
                        .string("-c"),
                        .string("read line; dd if=/dev/zero bs=65536 count=2 2>/dev/null; printf 'pty-marker:%s' \"$line\"; exit 7")
                    ]),
                    "pty": .bool(true)
                ])
            ), using: context.wire)
            let jobText = try #require(started.response.result?.objectValue?["jobID"]?.stringValue)
            let jobID = try #require(UUID(uuidString: jobText))

            let inputRequestID = UUID()
            let input = try PommeAgentJobStreamFrame(
                jobID: jobID,
                frame: .init(requestID: inputRequestID, stream: .stdin, data: Data("value\n".utf8))
            ).envelope()
            let acknowledged = try await exchange(input, using: context.wire)
            #expect(acknowledged.response.ok == true)
            #expect(acknowledged.response.requestID == inputRequestID)

            var frames = started.streams + acknowledged.streams
            var terminal: PommeAgentProtocol.Envelope?
            let clock = ContinuousClock()
            let startedAt = clock.now
            let deadline = startedAt.advanced(by: .seconds(15))
            var polls = 0
            while !frames.contains(where: { $0.frame.stream == .exit }), clock.now < deadline {
                let status = PommeAgentProtocol.Envelope.request(
                    operation: "process.status",
                    payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
                )
                let remaining = deadline - clock.now
                let remainingSeconds = Double(remaining.components.seconds)
                    + Double(remaining.components.attoseconds) / 1_000_000_000_000_000_000
                let result = try await exchange(
                    status,
                    using: context.wire,
                    timeout: min(remainingSeconds, 1)
                )
                polls += 1
                frames += result.streams
                terminal = result.response
                if !frames.contains(where: { $0.frame.stream == .exit }) {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }

            var stdout = Data()
            for frame in frames where frame.frame.stream == .stdout {
                #expect((frame.frame.data?.count ?? 0) <= PommeAgentProtocol.maximumStreamChunkBytes)
                stdout.append(frame.frame.data ?? Data())
            }
            let marker = Data("pty-marker:value".utf8)
            let diagnostics = "polls=\(polls), stdoutBytes=\(stdout.count), elapsed=\(clock.now - startedAt)"
            #expect(frames.allSatisfy { $0.jobID == jobID })
            #expect(frames.contains { $0.frame.stream == .exit }, Comment(rawValue: diagnostics))
            #expect(stdout.count == 2 * 65536 + marker.count, Comment(rawValue: diagnostics))
            #expect(stdout.prefix(2 * 65536) == Data(repeating: 0, count: 2 * 65536), Comment(rawValue: diagnostics))
            #expect(stdout.suffix(marker.count) == marker, Comment(rawValue: diagnostics))
            #expect(terminal?.result?.objectValue?["exitCode"] == .integer(7), Comment(rawValue: diagnostics))
        }
    }

    @Test("PTY echo is opt-in and private input remains absent from streams")
    func ptyEchoRequiresExplicitPublicOptIn() async throws {
        try await withDaemon { context in
            try await authenticate(using: context.wire)

            let privateStart = try await exchange(.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/bin/sh"),
                    "arguments": .array([.string("-c"), .string("read line; printf 'private-marker'; exit 0")]),
                    "pty": .bool(true)
                ])
            ), using: context.wire)
            #expect(privateStart.response.result?.objectValue?["ptyEchoDisabled"] == .bool(true))
            let privateText = try #require(privateStart.response.result?.objectValue?["jobID"]?.stringValue)
            let privateID = try #require(UUID(uuidString: privateText))
            let privateInput = try PommeAgentJobStreamFrame(
                jobID: privateID,
                frame: .init(requestID: UUID(), stream: .stdin, data: Data("private-secret\n".utf8))
            ).envelope()
            let privateAcknowledged = try await exchange(privateInput, using: context.wire)
            var privateFrames = privateStart.streams + privateAcknowledged.streams

            let publicStart = try await exchange(.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/bin/sh"),
                    "arguments": .array([.string("-c"), .string("read line; printf 'public-marker'; exit 0")]),
                    "pty": .bool(true),
                    "ptyEcho": .bool(true)
                ])
            ), using: context.wire)
            #expect(publicStart.response.result?.objectValue?["ptyEchoDisabled"] == .bool(false))
            let publicText = try #require(publicStart.response.result?.objectValue?["jobID"]?.stringValue)
            let publicID = try #require(UUID(uuidString: publicText))
            let publicInput = try PommeAgentJobStreamFrame(
                jobID: publicID,
                frame: .init(requestID: UUID(), stream: .stdin, data: Data("public-input\n".utf8))
            ).envelope()
            let publicAcknowledged = try await exchange(publicInput, using: context.wire)
            var publicFrames = publicStart.streams + publicAcknowledged.streams

            for _ in 0..<32 where !privateFrames.contains(where: { $0.frame.stream == .exit }) || !publicFrames.contains(where: { $0.frame.stream == .exit }) {
                for (jobID, frames) in [(privateID, privateFrames), (publicID, publicFrames)] where !frames.contains(where: { $0.frame.stream == .exit }) {
                    let result = try await exchange(.request(
                        operation: "process.status",
                        payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
                    ), using: context.wire)
                    if jobID == privateID { privateFrames += result.streams }
                    else { publicFrames += result.streams }
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let privateOutput = privateFrames
                .filter { $0.frame.stream == .stdout }
                .reduce(into: Data()) { $0.append($1.frame.data ?? Data()) }
            let publicOutput = publicFrames
                .filter { $0.frame.stream == .stdout }
                .reduce(into: Data()) { $0.append($1.frame.data ?? Data()) }
            #expect(privateFrames.allSatisfy { $0.jobID == privateID })
            #expect(publicFrames.allSatisfy { $0.jobID == publicID })
            #expect(privateOutput == Data("private-marker".utf8))
            #expect(privateOutput.range(of: Data("private-secret".utf8)) == nil)
            #expect(publicOutput.range(of: Data("public-input".utf8)) != nil)
            #expect(publicOutput.range(of: Data("public-marker".utf8)) != nil)
        }
    }

    @Test("Unauthenticated and failed process requests never leak stream frames")
    func rejectedProcessRequestsDoNotStream() async throws {
        try await withDaemon { context in
            try await authenticate(using: context.wire)
            let start = PommeAgentProtocol.Envelope.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/usr/bin/true"),
                    "arguments": .array([])
                ])
            )
            let started = try await exchange(start, using: context.wire)
            let jobText = try #require(started.response.result?.objectValue?["jobID"]?.stringValue)
            let jobID = try #require(UUID(uuidString: jobText))

            context.connection.resetForReconnect()
            let unauthenticated = PommeAgentProtocol.Envelope.request(
                operation: "process.status",
                payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
            )
            let blocked = try await exchange(unauthenticated, using: context.wire)
            #expect(blocked.response.ok == false)
            #expect(blocked.streams.isEmpty)

            try await authenticate(using: context.wire)

            let failed = PommeAgentProtocol.Envelope.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/usr/bin/true"),
                    "arguments": .array([]),
                    "user": .string("nobody"),
                    "uid": .integer(0)
                ])
            )
            let rejected = try await exchange(failed, using: context.wire)
            #expect(rejected.response.ok == false)
            #expect(rejected.streams.isEmpty)
        }
    }

    @Test("Detached jobs list, retain tail logs, and replay them without consumption")
    func detachedJobsListAndReplayLogs() async throws {
        try await withDaemon { context in
            try await authenticate(using: context.wire)
            let started = try await exchange(.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/bin/sh"),
                    "arguments": .array([
                        .string("-c"),
                        .string("dd if=/dev/zero bs=65536 count=3 2>/dev/null; printf tail; exit 7")
                    ]),
                    "detached": .bool(true)
                ])
            ), using: context.wire)
            let jobText = try #require(started.response.result?.objectValue?["jobID"]?.stringValue)
            let jobID = try #require(UUID(uuidString: jobText))

            let listed = try await exchange(.request(operation: "process.list"), using: context.wire)
            let jobs = try #require(listed.response.result?.objectValue?["jobs"]?.arrayValue)
            #expect(jobs.contains { $0.objectValue?["jobID"]?.stringValue == jobID.uuidString.lowercased() })
            #expect(listed.streams.isEmpty)

            let waited = try await exchange(.request(
                operation: "process.wait",
                payload: .object([
                    "jobID": .string(jobID.uuidString.lowercased()),
                    "timeout": .integer(3)
                ])
            ), using: context.wire, timeout: 4)
            let terminal = try #require(waited.response.result?.objectValue)
            #expect(terminal["exited"] == .bool(true))
            #expect(terminal["exitCode"] == .integer(7))
            #expect(terminal["timedOut"] == .bool(false))
            #expect(terminal["outputComplete"] == .bool(true))
            #expect(terminal["stdoutBytes"] == .integer(3 * 65536 + 4))
            #expect(terminal["stdoutTruncated"] == .bool(true))
            let waitedOutput = waited.streams.filter { $0.frame.stream == .stdout }
            #expect(waitedOutput.reduce(0) { $0 + ($1.frame.data?.count ?? 0) } == PommeAgent.maximumRetainedJobLogBytes)
            #expect(waitedOutput.last?.frame.data?.suffix(4) == Data("tail".utf8))
            #expect(waited.streams.last?.frame.stream == .exit)

            let output = PommeAgentProtocol.Envelope.request(
                operation: "process.output",
                payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
            )
            let firstLogs = try await exchange(output, using: context.wire)
            let secondLogs = try await exchange(.request(
                operation: "process.output",
                payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
            ), using: context.wire)
            #expect(firstLogs.response.result?.objectValue?["outputComplete"] == .bool(true))
            #expect(firstLogs.response.result == secondLogs.response.result)
            #expect(firstLogs.streams.map { $0.frame.stream } == secondLogs.streams.map { $0.frame.stream })
            #expect(firstLogs.streams.map { $0.frame.data } == secondLogs.streams.map { $0.frame.data })
            #expect(firstLogs.streams.map { $0.frame.signal } == secondLogs.streams.map { $0.frame.signal })
            #expect(firstLogs.streams.map { $0.frame.data } == waited.streams.map { $0.frame.data })
            #expect(firstLogs.response.result?.objectValue?["stdoutTruncated"] == .bool(true))
        }
    }

    @Test("Detached wait times out without terminating the job and job requests reject unknown or malformed input")
    func detachedWaitTimeoutAndValidation() async throws {
        try await withDaemon { context in
            try await authenticate(using: context.wire)
            let started = try await exchange(.request(
                operation: "process.start",
                payload: .object([
                    "path": .string("/bin/sh"),
                    "arguments": .array([.string("-c"), .string("sleep 2; printf still-ran")]),
                    "detached": .bool(true)
                ])
            ), using: context.wire)
            let jobText = try #require(started.response.result?.objectValue?["jobID"]?.stringValue)

            let timeout = try await exchange(.request(
                operation: "process.wait",
                payload: .object(["jobID": .string(jobText), "timeout": .integer(1)])
            ), using: context.wire, timeout: 2)
            #expect(timeout.response.ok == true)
            #expect(timeout.response.result?.objectValue?["timedOut"] == .bool(true))
            #expect(timeout.response.result?.objectValue?["exited"] == .bool(false))

            let unknown = try await exchange(.request(
                operation: "process.output",
                payload: .object(["jobID": .string("00000000-0000-0000-0000-000000000042")])
            ), using: context.wire)
            #expect(unknown.response.error?.code == "not-found")
            #expect(unknown.streams.isEmpty)

            let malformed = try await exchange(.request(
                operation: "process.wait",
                payload: .object(["jobID": .string(jobText), "timeout": .string("one")])
            ), using: context.wire)
            #expect(malformed.response.error?.code == "invalid-operation")
            #expect(malformed.streams.isEmpty)

            let killed = try await exchange(.request(
                operation: "process.signal",
                payload: .object(["jobID": .string(jobText), "signal": .integer(Int64(SIGKILL))])
            ), using: context.wire)
            #expect(killed.response.ok == true)
        }
    }

    private func authenticate(using wire: PommeAgentVSOCKWire) async throws {
        let request = PommeAgentProtocol.Envelope.request(
            operation: "authenticate",
            payload: .object(["challenge": .string(String(repeating: "b", count: 64))])
        )
        let result = try await exchange(request, using: wire)
        #expect(result.response.ok == true)
        #expect(result.streams.isEmpty)
    }

    private func exchange(
        _ request: PommeAgentProtocol.Envelope,
        using wire: PommeAgentVSOCKWire,
        timeout: TimeInterval = 1
    ) async throws -> ExchangeResult {
        let encoded = try PommeAgentProtocol.encode(request)
        let delivered = try await Task.detached(priority: .utility) {
            try wire.exchange(encoded, timeout: timeout)
        }.value
        return try decodeExchange(delivered, for: request)
    }

    private func decodeExchange(
        _ data: Data,
        for request: PommeAgentProtocol.Envelope
    ) throws -> ExchangeResult {
        var streams: [PommeAgentJobStreamFrame] = []
        var response: PommeAgentProtocol.Envelope?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let envelope = try PommeAgentProtocol.decode(Data(line))
            guard envelope.requestID == request.requestID else {
                throw ExchangeError.responseCorrelation
            }
            switch envelope.kind {
            case .stream:
                streams.append(try PommeAgentJobStreamFrame(envelope: envelope))
            case .response:
                guard envelope.operation == request.operation, response == nil else {
                    throw ExchangeError.responseCorrelation
                }
                response = envelope
            case .request:
                throw ExchangeError.unexpectedRequest
            }
        }
        guard let response else { throw ExchangeError.connectionClosed }
        return .init(response: response, streams: streams)
    }

    private func withDaemon<R: Sendable>(
        body: @Sendable (DaemonContext) async throws -> R
    ) async throws -> R {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw ExchangeError.socketpairFailed
        }
        let client = sockets[0]
        let server = sockets[1]
        let token = String(repeating: "a", count: 64)
        let connection = try PommeAgentConnection(token: token, lifetime: .persistent)
        let agent = try PommeAgent(role: .persistent, executableSHA256: token)
        let context = DaemonContext(
            wire: PommeAgentVSOCKWire(fileDescriptor: client),
            connection: connection
        )
        let serving = Task {
            await PommeAgentDaemon.serve(
                descriptor: server,
                connection: connection,
                agent: agent,
                allowedOperation: nil
            )
        }

        do {
            let result = try await body(context)
            _ = shutdown(client, SHUT_WR)
            _ = await serving.value
            _ = Darwin.close(client)
            _ = Darwin.close(server)
            return result
        } catch {
            _ = shutdown(client, SHUT_RDWR)
            _ = shutdown(server, SHUT_RDWR)
            _ = await serving.value
            _ = Darwin.close(client)
            _ = Darwin.close(server)
            throw error
        }
    }
}

private struct DaemonContext: Sendable {
    let wire: PommeAgentVSOCKWire
    let connection: PommeAgentConnection
}

private struct ExchangeResult: Sendable {
    let response: PommeAgentProtocol.Envelope
    let streams: [PommeAgentJobStreamFrame]
}

private enum ExchangeError: Error {
    case socketpairFailed
    case connectionClosed
    case responseCorrelation
    case unexpectedRequest
}
