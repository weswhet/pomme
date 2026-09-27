import Darwin
import Foundation
import Testing
import Synchronization

@Suite("Pomme foreground execution")
struct PommeForegroundExecutionTests {
    @Test("Desktop diagnostics require exact probe payloads", arguments: ["console", "aqua", "ps"], ["exact", "user", "environment", "stdinDataBase64", "attachStdin", "pty", "cwd", "arguments", "path", "unknown"])
    func desktopDiagnosticPayloadGate(stage: String, variant: String) async throws {
        let request: GuestCommandRequest
        switch stage {
        case "console": request = .init(path: "/usr/bin/stat", arguments: ["-f", "%Su:%u", "/dev/console"], timeout: 15)
        case "ps": request = .init(path: "/bin/ps", arguments: ["-axo", "uid=,comm="], timeout: 15)
        default: request = try #require(PommeSecurityNormalAgent.aquaSessionProofRequest(uniqueID: 501))
        }
        var payload = try #require(JSONValue(any: request.agentPayload()).objectValue)
        if variant != "exact" {
            payload[variant] = .string("private-value")
            if variant == "stdinDataBase64" { payload[variant] = .string("") }
            if variant == "pty" || variant == "attachStdin" { payload[variant] = .bool(false) }
        }
        let diagnosticPayload = JSONValue.object(payload)
        let messages = Mutex<[String]>([])
        await PommeCore.withLogSink({ line in messages.withLock { $0.append(line) } }) {
            do {
                _ = try await PommeForegroundExecution.run(
                    payload: diagnosticPayload, timeout: 15,
                    perform: { _, _ in throw RunnerError.guestAgentTimedOut("Pomme agent exchange") },
                    sendStream: { _, _, _ in Issue.record("No stream after failed start"); return [] })
                Issue.record("Expected timeout")
            } catch { }
        }
        let lines = messages.withLock { $0 }
        #expect(lines.count == (variant == "exact" ? 1 : 0))
        #expect(lines.allSatisfy { $0.contains("errorKind=agentTimeout") && !$0.contains("private-value") && !$0.contains("Pomme agent exchange") })
    }

    @Test("Desktop transport start failures are closed and opt-in", arguments: [true, false])
    func desktopTransportStartDiagnostic(exact: Bool) async throws {
        let messages = Mutex<[String]>([])
        let payload = exact ? try aquaPayload() : .object(["path": .string("/private/do-not-log")])
        try await PommeCore.withLogSink({ line in messages.withLock { $0.append(line) } }) {
            do {
                _ = try await PommeForegroundExecution.run(
                    payload: payload, timeout: 15,
                    perform: { _, _ in throw RunnerError.guestAgentTimedOut("private-secret") },
                    sendStream: { _, _, _ in Issue.record("No stream after failed start"); return [] })
                Issue.record("Expected original transport error")
            } catch RunnerError.guestAgentTimedOut(let operation) {
                #expect(operation == "private-secret")
            }
        }
        let lines = messages.withLock { $0 }
        if exact {
            let line = try #require(lines.first)
            #expect(lines.count == 1)
            #expect(line.contains("[DEBUG-desktop-transport-20260923] side=helper boundary=start "))
            #expect(line.contains("jobEstablished=false pollCount=0 errorKind=agentTimeout"))
            #expect(line.contains("elapsedMs="))
            #expect(line.contains("private") == false)
        } else { #expect(lines.isEmpty) }
    }

    @Test("Desktop transport phases preserve original errors and single cleanup", arguments: ["startValidation", "eof", "status", "statusValidation", "frameAccept", "terminalValidation", "signal"])
    func desktopTransportPhaseDiagnostic(phase: String) async throws {
        let messages = Mutex<[String]>([])
        let operations = Mutex<[String]>([])
        let payload = try aquaPayload()
        try await PommeCore.withLogSink({ line in messages.withLock { $0.append(line) } }) {
            do {
                _ = try await PommeForegroundExecution.run(
                    payload: payload, timeout: 15,
                    perform: { operation, _ in
                        operations.withLock { $0.append(operation) }
                        if operation == "process.start" {
                            return correlated(requestID: startRequestID,
                                result: phase == "startValidation" ? .object([:]) : started(), frames: [])
                        }
                        if operation == "process.signal" {
                            if phase == "signal" { throw RunnerError.guestAgentError("private-signal") }
                            return correlated(requestID: UUID(), result: .object([:]), frames: [])
                        }
                        if phase == "status" || phase == "signal" { throw RunnerError.guestAgentTimedOut("private-original") }
                        if phase == "statusValidation" {
                            return correlated(requestID: UUID(), result: .object([:]), frames: [])
                        }
                        return correlated(requestID: UUID(),
                            result: status(exited: true, exitCode: phase == "terminalValidation" ? nil : 0),
                            frames: [frame(jobID: jobID, stream: .exit)])
                    }, sendStream: { _, _, _ in
                        if phase == "eof" { throw RunnerError.guestAgentTimedOut("private-original") }
                        return []
                    }, onFrames: { _ in
                        if phase == "frameAccept" { throw RunnerError.guestAgentTimedOut("private-original") }
                    })
                Issue.record("Expected original error")
            } catch RunnerError.guestAgentTimedOut(let value) {
                #expect(["eof", "status", "frameAccept", "signal"].contains(phase))
                #expect(value == "private-original")
            } catch let error as PommeForegroundExecution.Error {
                #expect(["startValidation", "statusValidation", "terminalValidation"].contains(phase))
                #expect(error == .invalidCompletion)
            }
        }
        let lines = messages.withLock { $0 }
        #expect(lines.count == (phase == "signal" ? 2 : 1))
        let line = try #require(lines.last)
        #expect(line.contains("boundary=\(phase) "))
        #expect(line.contains("jobEstablished=\(phase != "startValidation")"))
        #expect(line.contains("pollCount=\(["startValidation", "eof"].contains(phase) ? 0 : 1)"))
        #expect(lines.allSatisfy { $0.contains("private") == false && $0.contains(jobID.uuidString.lowercased()) == false })
        let calls = operations.withLock { $0 }
        #expect(calls.filter { $0 == "process.start" }.count == 1)
        #expect(calls.filter { $0 == "process.signal" }.count == (phase == "startValidation" ? 0 : 1))
    }

    @Test("Failed foreground start preserves its error without sending input", arguments: [true, false])
    func failedStartPreservesError(exact: Bool) async throws {
        let payload = exact ? try aquaPayload() : .object(["path": .string("/private/do-not-log")])
        do {
            _ = try await PommeForegroundExecution.run(
                payload: payload, timeout: 15,
                perform: { _, _ in throw RunnerError.guestAgentTimedOut("private-secret") },
                sendStream: { _, _, _ in Issue.record("No stream after failed start"); return [] })
            Issue.record("Expected original transport error")
        } catch RunnerError.guestAgentTimedOut(let operation) {
            #expect(operation == "private-secret")
        }
    }

    private let jobID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let startRequestID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    private func aquaPayload() throws -> JSONValue {
        let request = try #require(PommeSecurityNormalAgent.aquaSessionProofRequest(uniqueID: 501))
        return try JSONValue(any: request.agentPayload())
    }

    @Test("Foreground failures preserve original errors and single cleanup", arguments: ["startValidation", "eof", "status", "statusValidation", "frameAccept", "terminalValidation", "signal"])
    func failuresPreserveErrorAndSingleCleanup(phase: String) async throws {
        let operations = Mutex<[String]>([])
        let payload = try aquaPayload()
        do {
            _ = try await PommeForegroundExecution.run(
                payload: payload, timeout: 15,
                perform: { operation, _ in
                    operations.withLock { $0.append(operation) }
                    if operation == "process.start" {
                        return correlated(requestID: startRequestID,
                            result: phase == "startValidation" ? .object([:]) : started(), frames: [])
                    }
                    if operation == "process.signal" {
                        if phase == "signal" { throw RunnerError.guestAgentError("private-signal") }
                        return correlated(requestID: UUID(), result: .object([:]), frames: [])
                    }
                    if phase == "status" || phase == "signal" { throw RunnerError.guestAgentTimedOut("private-original") }
                    if phase == "statusValidation" {
                        return correlated(requestID: UUID(), result: .object([:]), frames: [])
                    }
                    return correlated(requestID: UUID(),
                        result: status(exited: true, exitCode: phase == "terminalValidation" ? nil : 0),
                        frames: [frame(jobID: jobID, stream: .exit)])
                }, sendStream: { _, _, _ in
                    if phase == "eof" { throw RunnerError.guestAgentTimedOut("private-original") }
                    return []
                }, onFrames: { _ in
                    if phase == "frameAccept" { throw RunnerError.guestAgentTimedOut("private-original") }
                })
            Issue.record("Expected original error")
        } catch RunnerError.guestAgentTimedOut(let value) {
            #expect(["eof", "status", "frameAccept", "signal"].contains(phase))
            #expect(value == "private-original")
        } catch let error as PommeForegroundExecution.Error {
            #expect(["startValidation", "statusValidation", "terminalValidation"].contains(phase))
            #expect(error == .invalidCompletion)
        }
        let calls = operations.withLock { $0 }
        #expect(calls.filter { $0 == "process.start" }.count == 1)
        #expect(calls.filter { $0 == "process.signal" }.count == (phase == "startValidation" ? 0 : 1))
    }


    @Test("Cleanup receipts are limited to the three exact desktop probes", arguments: ["console", "aqua", "ps"], ["exact", "user", "uid", "environment", "stdinDataBase64", "attachStdin", "pty", "cwd", "arguments", "path", "unknown"])
    func desktopCleanupGate(stage: String, variant: String) async throws {
        let request: GuestCommandRequest
        switch stage {
        case "console": request = .init(path: "/usr/bin/stat", arguments: ["-f", "%Su:%u", "/dev/console"], timeout: 15)
        case "ps": request = .init(path: "/bin/ps", arguments: ["-axo", "uid=,comm="], timeout: 15)
        default: request = try #require(PommeSecurityNormalAgent.aquaSessionProofRequest(uniqueID: 501))
        }
        var payload = try #require(JSONValue(any: request.agentPayload()).objectValue)
        if variant != "exact" {
            payload[variant] = .string("mismatch")
            if variant == "stdinDataBase64" { payload[variant] = .string("") }
            if variant == "pty" || variant == "attachStdin" { payload[variant] = .bool(false) }
        }
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []), statuses: [],
            signalFrames: [frame(jobID: jobID, stream: .exit, signal: 15)]
        )
        let result = try await run(payload: .object(payload), transport: transport, timeout: 0.03)
        #expect((result.result.objectValue?[PommeForegroundExecution.desktopCleanupReceiptKey] != nil) == (variant == "exact"))
        #expect(result.result.objectValue?["timedOut"] == .bool(true))
        #expect(result.result.objectValue?["outputComplete"] == .bool(false))
        #expect(await transport.signalCalls == 1)
        #expect(await transport.operationNames.filter { $0 == "process.start" }.count == 1)
    }

    @Test("Aqua cleanup receipt requires validated host-observed same-job exit", arguments: ["valid", "falseAckExit", "signalExit", "badSignal", "priorExit", "ackOnly", "wrongJob", "malformedExit", "foreignOutput", "forged", "ordinary"])
    func aquaCleanupReceiptBoundary(mode: String) async throws {
        var start = try #require(started().objectValue)
        if mode == "forged" {
            start[PommeForegroundExecution.desktopCleanupReceiptKey] = .object([
                "jobID": .string(jobID.uuidString), "reapedAndDrained": .bool(true)
            ])
        }
        var frames: [PommeAgentJobStreamFrame] = []
        if mode != "ackOnly" && mode != "forged" && mode != "priorExit" {
            frames = [frame(jobID: mode == "wrongJob" ? UUID() : jobID, stream: .exit,
                            data: mode == "malformedExit" ? Data("invalid".utf8) : nil,
                            signal: mode == "signalExit" ? 15 : (mode == "badSignal" ? 128 : nil))]
            if mode == "foreignOutput" { frames.append(frame(jobID: UUID(), stream: .stdout, data: Data())) }
        }
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: .object(start),
                              frames: mode == "priorExit" ? [frame(jobID: jobID, stream: .exit)] : []),
            statuses: [], signalFrames: frames, signalAcknowledged: mode != "falseAckExit"
        )
        let payload: JSONValue = mode == "ordinary" ? .object(["path": .string("/usr/bin/true")]) : try aquaPayload()
        let result = try await run(payload: payload, transport: transport, timeout: 0.03)
        let values = try #require(result.result.objectValue)
        #expect(values["timedOut"] == .bool(true))
        #expect(values["outputComplete"] == .bool(mode == "priorExit"))
        #expect((values[PommeForegroundExecution.desktopCleanupReceiptKey] != nil) == ["valid", "falseAckExit", "signalExit", "priorExit"].contains(mode))
        #expect(await transport.signalCalls == 1)
    }


    @Test("polls until output is complete and retains stderr and exit status")
    func delayedOutputAndCompletion() async throws {
        try await runDelayedOutputAndCompletion()
    }

    @Test("Foreground completion ordering survives a delayed polling resume")
    func delayedPollCompletionOrdering() async throws {
        try await runDelayedOutputAndCompletion(timeout: 0.05, pollSleep: { _ in
            try await Task.sleep(for: .milliseconds(120))
        })
    }

    private func runDelayedOutputAndCompletion(
        timeout: TimeInterval = 5,
        pollSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        // Given
        let firstStatus = correlated(
            requestID: UUID(),
            result: status(exited: false),
            frames: [frame(jobID: jobID, stream: .stdout, data: Data("early".utf8))]
        )
        let finalStatus = correlated(
            requestID: UUID(),
            result: status(exited: true, exitCode: 7),
            frames: [
                frame(jobID: jobID, stream: .stdout, data: Data("late".utf8)),
                frame(jobID: jobID, stream: .stderr, data: Data("warning".utf8)),
                frame(jobID: jobID, stream: .exit)
            ]
        )
        let transport = ForegroundTransport(
            start: correlated(
                requestID: startRequestID,
                result: started(),
                frames: []
            ),
            statuses: [firstStatus, finalStatus]
        )

        // When
        let logicalNow = ContinuousClock.now
        let pollCount = Mutex(0)
        let result = try await run(
            transport: transport, timeout: timeout,
            pollTiming: .init(now: { logicalNow }, sleep: { duration in
                let count = pollCount.withLock { $0 += 1; return $0 }
                // A missing scripted completion must fail, not spin forever
                // against this ordering fixture's intentionally frozen clock.
                try #require(count == 1)
                try await pollSleep(duration)
            })
        )

        // Then
        #expect(pollCount.withLock { $0 } == 1)
        #expect(result.requestID == startRequestID)
        #expect(result.result.objectValue?["jobID"] == .string(jobID.uuidString.lowercased()))
        #expect(result.result.objectValue?["exited"] == .bool(true))
        #expect(result.result.objectValue?["exitCode"] == .integer(7))
        #expect(result.streamFrames.filter { $0.frame.stream == .stdout }.count == 2)
        #expect(result.streamFrames.contains { $0.frame.stream == .stderr && $0.frame.data == Data("warning".utf8) })
        #expect(await transport.operationNames == ["process.start", "process.status", "process.status"])
        #expect(await transport.streamCalls.map(\.stream) == [.eof])
    }

    @Test("Foreground logical deadline and actual cancellation retain partial output without another poll", arguments: [false, true])
    func logicalPollInterruption(cancelled: Bool) async throws {
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [
                correlated(requestID: UUID(), result: status(exited: false), frames: [
                    frame(jobID: jobID, stream: .stdout, data: Data("early".utf8))
                ]),
                correlated(requestID: UUID(), result: status(exited: true, exitCode: 7), frames: [
                    frame(jobID: jobID, stream: .stdout, data: Data("late".utf8)),
                    frame(jobID: jobID, stream: .exit)
                ])
            ]
        )
        let instant = Mutex(ContinuousClock.now)
        let events = Mutex<[String]>([])
        let signalPayload = Mutex<JSONValue?>(nil)
        let sleeps = Mutex<[Duration]>([])
        let task = Task {
            try await PommeForegroundExecution.run(
                payload: .object(["path": .string("/bin/true")]), timeout: 0.05,
                perform: { operation, payload in
                    events.withLock { $0.append(operation) }
                    if operation == "process.signal" { signalPayload.withLock { $0 = payload } }
                    return await transport.perform(operation: operation, payload: payload)
                },
                sendStream: { jobID, stream, data in
                    events.withLock { $0.append("stream.\(stream)") }
                    return await transport.sendStream(jobID: jobID, stream: stream, data: data)
                },
                pollTiming: .init(now: { instant.withLock { $0 } }, sleep: { duration in
                    sleeps.withLock { $0.append(duration) }
                    instant.withLock { $0 = $0.advanced(by: .seconds(1)) }
                    // Cancel the actual runner task while its injected sleep
                    // is active, with an expired clock at the same checkpoint.
                    if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                })
            )
        }
        let result = try await task.value
        #expect(result.requestID == startRequestID)
        #expect(result.result.objectValue?["jobID"] == .string(jobID.uuidString.lowercased()))
        #expect(result.result.objectValue?["timedOut"] == .bool(!cancelled))
        #expect(result.result.objectValue?["cancelled"] == .bool(cancelled))
        #expect(result.result.objectValue?["exited"] == .bool(false))
        #expect(result.result.objectValue?["outputComplete"] == .bool(false))
        #expect(result.streamFrames.count == 1)
        #expect(result.streamFrames.first?.jobID == jobID)
        #expect(result.streamFrames.first?.frame.stream == .stdout)
        #expect(result.streamFrames.first?.frame.data == Data("early".utf8))
        #expect(events.withLock { $0 } == ["process.start", "stream.eof", "process.status", "process.signal"])
        #expect(sleeps.withLock { $0 } == [.milliseconds(25)])
        #expect(signalPayload.withLock { $0 } == .object([
            "jobID": .string(jobID.uuidString.lowercased()), "signal": .integer(Int64(SIGTERM))
        ]))
        #expect(await transport.signalCalls == 1)
    }

    @Test("sends supplied input in bounded chunks followed by one EOF")
    func suppliedInputIsChunkedAndClosed() async throws {
        // Given
        let input = Data(repeating: 0x61, count: PommeAgentProtocol.maximumStreamChunkBytes * 2 + 7)
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [
                correlated(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    frames: [frame(jobID: jobID, stream: .exit)]
                )
            ]
        )

        // When
        _ = try await run(
            payload: .object([
                "path": .string("/bin/cat"),
                "arguments": .array([]),
                "stdinDataBase64": .string(input.base64EncodedString())
            ]),
            transport: transport
        )

        // Then
        let calls = await transport.streamCalls
        #expect(calls.map(\.stream) == [.stdin, .stdin, .stdin, .eof])
        #expect(calls.dropLast().map { $0.data?.count } == [PommeAgentProtocol.maximumStreamChunkBytes, PommeAgentProtocol.maximumStreamChunkBytes, 7])
        #expect(calls.last?.data == nil)
    }

    @Test("bounds unary output while preserving the terminal frame")
    func boundedOutput() async throws {
        // Given
        let chunk = Data(repeating: 0x62, count: PommeAgentProtocol.maximumStreamChunkBytes)
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [
                correlated(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    frames: [
                        frame(jobID: jobID, stream: .stdout, data: chunk),
                        frame(jobID: jobID, stream: .stdout, data: chunk),
                        frame(jobID: jobID, stream: .stdout, data: chunk),
                        frame(jobID: jobID, stream: .exit)
                    ]
                )
            ]
        )

        // When
        let result = try await run(transport: transport)

        // Then
        let stdoutBytes = result.streamFrames
            .filter { $0.frame.stream == .stdout }
            .compactMap { $0.frame.data?.count }
            .reduce(0, +)
        #expect(stdoutBytes == PommeForegroundExecution.maximumBufferedOutputBytes)
        #expect(result.result.objectValue?["stdoutTruncated"] == .bool(true))
        #expect(result.streamFrames.contains { $0.frame.stream == .exit })
    }

    @Test("callback mode forwards all frames and does not return a second copy")
    func callbackMode() async throws {
        // Given
        let collector = FrameCollector()
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [
                correlated(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    frames: [
                        frame(jobID: jobID, stream: .stdout, data: Data("out".utf8)),
                        frame(jobID: jobID, stream: .stderr, data: Data("err".utf8)),
                        frame(jobID: jobID, stream: .exit)
                    ]
                )
            ]
        )

        // When
        let result = try await run(transport: transport) { frames in
            await collector.append(frames)
        }

        // Then
        #expect(result.streamFrames.isEmpty)
        #expect(await collector.frames.count == 3)
        #expect(await collector.frames.contains { $0.frame.stream == .stderr })
        #expect(result.result.objectValue?["stdoutTruncated"] == .bool(false))
        #expect(result.result.objectValue?["stderrTruncated"] == .bool(false))
    }

    @Test("timeout sends SIGTERM once and reports the still-owned job")
    func timeoutDoesNotRestart() async throws {
        // Given
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: []
        )

        // When
        let result = try await run(transport: transport, timeout: 0.03)

        // Then
        #expect(result.result.objectValue?["jobID"] == .string(jobID.uuidString.lowercased()))
        #expect(result.result.objectValue?["exited"] == .bool(false))
        #expect(result.result.objectValue?["timedOut"] == .bool(true))
        #expect(await transport.signalCalls == 1)
        #expect(await transport.operationNames.filter { $0 == "process.start" }.count == 1)
    }

    @Test("cancellation sends SIGTERM once and reports the still-owned job")
    func cancellationDoesNotRestart() async throws {
        // Given
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: []
        )
        let task = Task {
            try await run(transport: transport, timeout: 5)
        }
        try await Task.sleep(for: .milliseconds(20))

        // When
        task.cancel()
        let result = try await task.value

        // Then
        #expect(result.result.objectValue?["jobID"] == .string(jobID.uuidString.lowercased()))
        #expect(result.result.objectValue?["cancelled"] == .bool(true))
        #expect(result.result.objectValue?["timedOut"] == .bool(false))
        #expect(await transport.signalCalls == 1)
        #expect(await transport.operationNames.filter { $0 == "process.start" }.count == 1)
    }

    @Test("rejects a stream frame for another job and terminates the known job once")
    func unrelatedJobFrameIsRejected() async throws {
        // Given
        let otherJob = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: [
                correlated(
                    requestID: UUID(),
                    result: status(exited: true, exitCode: 0),
                    frames: [frame(jobID: otherJob, stream: .stdout, data: Data("wrong".utf8))]
                )
            ]
        )

        // When / Then
        do {
            _ = try await run(transport: transport)
            Issue.record("Expected an unrelated-job stream frame to be rejected.")
        } catch let error as PommeForegroundExecution.Error {
            #expect(error == .unrelatedJobFrame)
        }
        #expect(await transport.signalCalls == 1)
    }

    @Test("rejects detached payloads before starting a process")
    func detachedPayloadIsRejected() async throws {
        // Given
        let transport = ForegroundTransport(
            start: correlated(requestID: startRequestID, result: started(), frames: []),
            statuses: []
        )

        // When / Then
        do {
            _ = try await run(
                payload: .object(["detached": .bool(true)]),
                transport: transport
            )
            Issue.record("Expected detached execution to be rejected.")
        } catch let error as PommeForegroundExecution.Error {
            #expect(error == .detachedPayload)
        }
        #expect(await transport.operationNames.isEmpty)
    }

    private func run(
        payload: JSONValue = .object([
            "path": .string("/bin/true"),
            "arguments": .array([])
        ]),
        transport: ForegroundTransport,
        // This is only the fixture's operation budget. The implementation's
        // bounded deadline behavior is covered by the explicit short-timeout
        // tests below; the larger default avoids starvation under the full
        // parallel suite.
        timeout: TimeInterval = 5,
        pollTiming: PommeForegroundExecution.PollTiming = .init(),
        onFrames: PommeForegroundExecution.FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult {
        try await PommeForegroundExecution.run(
            payload: payload,
            timeout: timeout,
            perform: { operation, payload in
                await transport.perform(operation: operation, payload: payload)
            },
            sendStream: { jobID, stream, data in
                await transport.sendStream(jobID: jobID, stream: stream, data: data)
            },
            pollTiming: pollTiming,
            onFrames: onFrames
        )
    }

    private func started() -> JSONValue {
        .object([
            "jobID": .string(jobID.uuidString.lowercased()),
            "pid": .integer(42),
            "detached": .bool(false),
            "exited": .bool(false)
        ])
    }

    private func status(exited: Bool, exitCode: Int64? = nil, signal: Int64? = nil) -> JSONValue {
        var values: [String: JSONValue] = [
            "jobID": .string(jobID.uuidString.lowercased()),
            "pid": .integer(42),
            "detached": .bool(false),
            "exited": .bool(exited)
        ]
        if let exitCode { values["exitCode"] = .integer(exitCode) }
        if let signal { values["signal"] = .integer(signal) }
        return .object(values)
    }

    private func frame(
        jobID: UUID,
        stream: PommeAgentProtocol.Stream,
        data: Data? = nil,
        signal: Int32? = nil
    ) -> PommeAgentJobStreamFrame {
        try! .init(jobID: jobID, frame: .init(requestID: UUID(), stream: stream, data: data, signal: signal))
    }

    private func correlated(
        requestID: UUID,
        result: JSONValue,
        frames: [PommeAgentJobStreamFrame]
    ) -> PommeAgentCorrelatedResult {
        .init(requestID: requestID, result: result, streamFrames: frames)
    }
}

@Suite("Pomme log stream execution")
struct PommeLogStreamExecutionTests {
    private let jobID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
    private let startRequestID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!

    @Test("forwards more than 64 KiB without retaining output")
    func forwardsLargeOutputWithoutRetention() async throws {
        let collector = FrameCollector()
        let chunk = Data(repeating: 0x61, count: PommeAgentProtocol.maximumStreamChunkBytes)
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [.success(correlated(
                result: status(exited: true, exitCode: 0),
                frames: [
                    frame(stream: .stdout, data: chunk),
                    frame(stream: .stderr, data: chunk),
                    frame(stream: .exit)
                ]
            ))]
        )

        let result = try await run(transport: transport, onFrames: { frames in
            await collector.append(frames)
        })

        #expect(result.streamFrames.isEmpty)
        #expect(await collector.frames.reduce(0) { $0 + ($1.frame.data?.count ?? 0) }
                == 2 * PommeAgentProtocol.maximumStreamChunkBytes)
        #expect(await transport.streamCalls.map(\.stream) == [.eof])
    }

    @Test("allows a follow lifetime beyond the ordinary five-minute limit")
    func unlimitedFollowUsesInjectedClock() async throws {
        let instant = Mutex(ContinuousClock.now)
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: true, exitCode: 0), frames: [frame(stream: .exit)]))
            ]
        )
        let timing = PommeLogStreamExecution.PollTiming(
            now: { instant.withLock { $0 } },
            sleep: { _ in instant.withLock { $0 = $0.advanced(by: .milliseconds(300_500)) } }
        )

        let result = try await run(transport: transport, timeout: 301, pollTiming: timing)

        #expect(result.result.objectValue?["exited"] == .bool(true))
        #expect(await transport.operationNames.filter { $0 == "process.status" }.count == 2)
    }

    @Test("preserves split stdout and stderr frames through the callback")
    func forwardsSplitFrames() async throws {
        let collector = FrameCollector()
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [.success(correlated(
                result: status(exited: true, exitCode: 0),
                frames: [
                    frame(stream: .stdout, data: Data("first".utf8)),
                    frame(stream: .stdout, data: Data("second".utf8)),
                    frame(stream: .stderr, data: Data("warning".utf8)),
                    frame(stream: .exit)
                ]
            ))]
        )

        let result = try await run(transport: transport, onFrames: { frames in
            await collector.append(frames)
        })

        #expect(result.streamFrames.isEmpty)
        #expect(await collector.frames.map { $0.frame.data }.compactMap { $0 }
                == [Data("first".utf8), Data("second".utf8), Data("warning".utf8)])
    }

    @Test("quiet disconnect terminates and confirms the owned process")
    func quietDisconnectTerminatesAndConfirmsCleanup() async throws {
        let probes = Mutex(0)
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: true, exitCode: 0), frames: [frame(stream: .exit)]))
            ]
        )

        do {
            _ = try await run(transport: transport, shouldCancel: {
                probes.withLock { count in
                    count += 1
                    return count >= 3
                }
            })
            Issue.record("Expected the quiet disconnect to interrupt the log stream.")
        } catch let error as PommeLogStreamExecution.Error {
            #expect(error == .interrupted(reason: .disconnected))
        }

        #expect(await transport.signals == [SIGTERM])
        #expect(await transport.streamCalls.map(\.stream) == [.eof])
    }

    @Test("timeout reports its typed reason after confirmed cleanup")
    func timeoutReportsTypedInterruption() async throws {
        let instant = Mutex(ContinuousClock.now)
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: true, exitCode: 0), frames: [frame(stream: .exit)]))
            ]
        )
        let timing = PommeLogStreamExecution.PollTiming(
            now: { instant.withLock { $0 } },
            sleep: { _ in instant.withLock { $0 = $0.advanced(by: .seconds(1)) } }
        )

        do {
            _ = try await run(transport: transport, timeout: 0.5, pollTiming: timing)
            Issue.record("Expected the log stream to time out.")
        } catch let error as PommeLogStreamExecution.Error {
            #expect(error == .interrupted(reason: .timedOut))
        }
        #expect(await transport.signals == [SIGTERM])
    }

    @Test("callback failures are preserved after confirmed cleanup")
    func callbackFailureSurvivesConfirmedCleanup() async throws {
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [
                .success(correlated(
                    result: status(exited: false),
                    frames: [frame(stream: .stdout, data: Data("partial".utf8))]
                )),
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: true, exitCode: 0), frames: [frame(stream: .exit)]))
            ]
        )

        do {
            _ = try await run(transport: transport, onFrames: { _ in throw LogStreamTestError.expected })
            Issue.record("Expected the callback failure to be preserved.")
        } catch let error as LogStreamTestError {
            #expect(error == .expected)
        }
        #expect(await transport.signals == [SIGTERM])
    }

    @Test("malformed frames are preserved after confirmed cleanup")
    func malformedFrameSurvivesConfirmedCleanup() async throws {
        let foreign = try! PommeAgentJobStreamFrame(
            jobID: UUID(),
            frame: .init(requestID: UUID(), stream: .stdout, data: Data("wrong".utf8))
        )
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [
                .success(correlated(result: status(exited: false), frames: [foreign])),
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: true, exitCode: 0), frames: [frame(stream: .exit)]))
            ]
        )

        do {
            _ = try await run(transport: transport)
            Issue.record("Expected the foreign frame to be rejected.")
        } catch let error as PommeLogStreamExecution.Error {
            #expect(error == .unrelatedJobFrame)
        }
        #expect(await transport.signals == [SIGTERM])
    }

    @Test("cleanup escalates from TERM to KILL after its first grace deadline")
    func cleanupEscalatesToKill() async throws {
        let probes = Mutex(0)
        let instant = Mutex(ContinuousClock.now)
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: true, exitCode: 0), frames: [frame(stream: .exit)]))
            ]
        )
        let timing = PommeLogStreamExecution.PollTiming(
            now: { instant.withLock { $0 } },
            sleep: { _ in instant.withLock { $0 = $0.advanced(by: .seconds(5)) } }
        )

        do {
            _ = try await run(transport: transport, pollTiming: timing, shouldCancel: {
                probes.withLock { count in
                    count += 1
                    return count >= 3
                }
            })
            Issue.record("Expected the disconnect to interrupt the log stream.")
        } catch let error as PommeLogStreamExecution.Error {
            #expect(error == .interrupted(reason: .disconnected))
        }

        #expect(await transport.signals == [SIGTERM, SIGKILL])
    }

    @Test("transport failure with no cleanup proof is explicit")
    func transportFailureWithoutCleanupProofIsExplicit() async throws {
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [.failure(.expected)],
            signals: [.failure(.expected)]
        )

        do {
            _ = try await run(transport: transport)
            Issue.record("Expected unconfirmed cleanup after transport failure.")
        } catch let error as PommeLogStreamExecution.Error {
            #expect(error == .cleanupUnconfirmed(reason: .disconnected))
        }
        #expect(await transport.signals == [SIGTERM])
    }

    @Test("a reaped job is confirmed before TERM is sent")
    func naturallyExitedJobIsConfirmedBeforeSignal() async throws {
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [
                .failure(.expected),
                .success(correlated(result: status(exited: true, exitCode: 0), frames: [frame(stream: .exit)]))
            ]
        )

        do {
            _ = try await run(transport: transport)
            Issue.record("Expected the original guest failure to be preserved.")
        } catch let error as LogStreamTestError {
            #expect(error == .expected)
        }
        #expect(await transport.signals.isEmpty)
    }

    @Test("a rejected TERM rechecks whether the job was reaped")
    func rejectedTermRechecksForExitProof() async throws {
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [
                .failure(.expected),
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: true, exitCode: 0), frames: [frame(stream: .exit)]))
            ],
            signals: [.failure(.expected)]
        )

        do {
            _ = try await run(transport: transport)
            Issue.record("Expected the original guest failure to be preserved.")
        } catch let error as LogStreamTestError {
            #expect(error == .expected)
        }
        #expect(await transport.signals == [SIGTERM])
    }

    @Test("guest failures survive confirmed cleanup")
    func guestFailureSurvivesConfirmedCleanup() async throws {
        let transport = LogStreamTransport(
            start: correlated(result: started()),
            statuses: [
                .failure(.expected),
                .success(correlated(result: status(exited: false))),
                .success(correlated(result: status(exited: true, exitCode: 0), frames: [frame(stream: .exit)]))
            ]
        )

        do {
            _ = try await run(transport: transport)
            Issue.record("Expected the guest failure to be preserved.")
        } catch let error as LogStreamTestError {
            #expect(error == .expected)
        }
        #expect(await transport.signals == [SIGTERM])
    }

    private func run(
        transport: LogStreamTransport,
        timeout: TimeInterval? = nil,
        pollTiming: PommeLogStreamExecution.PollTiming = .init(),
        shouldCancel: @escaping PommeLogStreamExecution.CancellationProbe = { false },
        onFrames: PommeLogStreamExecution.FrameHandler? = nil
    ) async throws -> PommeAgentCorrelatedResult {
        try await PommeLogStreamExecution.run(
            payload: .object(["path": .string("/usr/bin/log"), "arguments": .array([])]),
            timeout: timeout,
            perform: { operation, payload in try await transport.perform(operation: operation, payload: payload) },
            sendStream: { jobID, stream, data in try await transport.sendStream(jobID: jobID, stream: stream, data: data) },
            shouldCancel: shouldCancel,
            pollTiming: pollTiming,
            onFrames: onFrames
        )
    }

    private func started() -> JSONValue {
        .object([
            "jobID": .string(jobID.uuidString.lowercased()),
            "pid": .integer(42),
            "detached": .bool(false),
            "exited": .bool(false)
        ])
    }

    private func status(exited: Bool, exitCode: Int64? = nil) -> JSONValue {
        var values: [String: JSONValue] = [
            "jobID": .string(jobID.uuidString.lowercased()),
            "pid": .integer(42),
            "exited": .bool(exited)
        ]
        if let exitCode { values["exitCode"] = .integer(exitCode) }
        return .object(values)
    }

    private func frame(
        stream: PommeAgentProtocol.Stream,
        data: Data? = nil
    ) -> PommeAgentJobStreamFrame {
        try! .init(jobID: jobID, frame: .init(requestID: UUID(), stream: stream, data: data))
    }

    private func correlated(
        result: JSONValue,
        frames: [PommeAgentJobStreamFrame] = []
    ) -> PommeAgentCorrelatedResult {
        .init(requestID: startRequestID, result: result, streamFrames: frames)
    }
}

private enum LogStreamTestError: Swift.Error, Equatable, Sendable {
    case expected
}

private actor LogStreamTransport {
    struct StreamCall: Sendable {
        let jobID: UUID
        let stream: PommeAgentProtocol.Stream
        let data: Data?
    }

    let start: PommeAgentCorrelatedResult
    let statuses: [Result<PommeAgentCorrelatedResult, LogStreamTestError>]
    let signalResults: [Result<PommeAgentCorrelatedResult, LogStreamTestError>]
    private var statusIndex = 0
    private var signalIndex = 0
    private(set) var operationNames: [String] = []
    private(set) var signals: [Int32] = []
    private(set) var streamCalls: [StreamCall] = []

    init(
        start: PommeAgentCorrelatedResult,
        statuses: [Result<PommeAgentCorrelatedResult, LogStreamTestError>],
        signals: [Result<PommeAgentCorrelatedResult, LogStreamTestError>] = []
    ) {
        self.start = start
        self.statuses = statuses
        signalResults = signals
    }

    func perform(operation: String, payload: JSONValue) throws -> PommeAgentCorrelatedResult {
        operationNames.append(operation)
        switch operation {
        case "process.start": return start
        case "process.status":
            guard statusIndex < statuses.count else { throw LogStreamTestError.expected }
            defer { statusIndex += 1 }
            return try statuses[statusIndex].get()
        case "process.signal":
            guard let raw = payload.objectValue?["signal"], case .integer(let signal) = raw,
                  let value = Int32(exactly: signal)
            else { throw LogStreamTestError.expected }
            signals.append(value)
            if signalIndex < signalResults.count {
                defer { signalIndex += 1 }
                return try signalResults[signalIndex].get()
            }
            guard let jobID = payload.objectValue?["jobID"]?.stringValue else { throw LogStreamTestError.expected }
            return .init(requestID: UUID(), result: .object([
                "jobID": .string(jobID), "signalled": .bool(true)
            ]), streamFrames: [])
        default: throw LogStreamTestError.expected
        }
    }

    func sendStream(
        jobID: UUID,
        stream: PommeAgentProtocol.Stream,
        data: Data?
    ) throws -> [PommeAgentJobStreamFrame] {
        streamCalls.append(.init(jobID: jobID, stream: stream, data: data))
        return []
    }
}

private actor FrameCollector {
    private(set) var frames: [PommeAgentJobStreamFrame] = []

    func append(_ values: [PommeAgentJobStreamFrame]) { frames.append(contentsOf: values) }
}

private actor ForegroundTransport {
    struct StreamCall: Sendable {
        let jobID: UUID
        let stream: PommeAgentProtocol.Stream
        let data: Data?
    }

    let start: PommeAgentCorrelatedResult
    let statuses: [PommeAgentCorrelatedResult]
    let signalFrames: [PommeAgentJobStreamFrame]
    let signalAcknowledged: Bool
    private var statusIndex = 0
    private(set) var operationNames: [String] = []
    private(set) var streamCalls: [StreamCall] = []
    private(set) var signalCalls = 0

    init(start: PommeAgentCorrelatedResult, statuses: [PommeAgentCorrelatedResult], signalFrames: [PommeAgentJobStreamFrame] = [], signalAcknowledged: Bool = true) {
        self.start = start
        self.statuses = statuses
        self.signalFrames = signalFrames
        self.signalAcknowledged = signalAcknowledged
    }

    func perform(operation: String, payload: JSONValue) -> PommeAgentCorrelatedResult {
        operationNames.append(operation)
        switch operation {
        case "process.start": return start
        case "process.status":
            if statusIndex < statuses.count {
                defer { statusIndex += 1 }
                return statuses[statusIndex]
            }
            return .init(
                requestID: UUID(),
                result: .object([
                    "jobID": .string("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
                    "pid": .integer(42),
                    "detached": .bool(false),
                    "exited": .bool(false)
                ]),
                streamFrames: []
            )
        case "process.signal":
            signalCalls += 1
            return .init(requestID: UUID(), result: .object([
                "jobID": .string("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), "signalled": .bool(signalAcknowledged)
            ]), streamFrames: signalFrames)
        default:
            return .init(requestID: UUID(), result: .object([:]), streamFrames: [])
        }
    }

    func sendStream(jobID: UUID, stream: PommeAgentProtocol.Stream, data: Data?) -> [PommeAgentJobStreamFrame] {
        streamCalls.append(.init(jobID: jobID, stream: stream, data: data))
        return []
    }
}

@Suite("Foreground interruption messages")
struct PommeForegroundInterruptionMessageTests {
    @Test("A signalled timeout says the process was stopped, not that it is listed")
    func timedOutAndSignalled() {
        let text = PommeForegroundExecution.interruptionMessage(timedOut: true, terminationRequested: true)

        #expect(text == "Foreground command timed out; the guest process was signalled to stop."
                + " Use --detach to run a command that outlives the request.")
        // A foreground job is never in `jobs list`, so it must not be suggested.
        #expect(!text.contains("jobs list"))
    }

    @Test("An unsignalled timeout admits the process may still be running")
    func timedOutWithoutSignal() {
        for requested in [false, Bool?.none] {
            let text = PommeForegroundExecution.interruptionMessage(timedOut: true, terminationRequested: requested)

            #expect(text == "Foreground command timed out and the guest process could not be signalled;"
                    + " it may still be running in the guest.")
            #expect(!text.contains("jobs list"))
        }
    }

    @Test("Cancellation reads the same way without the detach hint")
    func cancelled() {
        #expect(PommeForegroundExecution.interruptionMessage(timedOut: false, terminationRequested: true)
                == "Foreground command was cancelled; the guest process was signalled to stop.")
        #expect(PommeForegroundExecution.interruptionMessage(timedOut: false, terminationRequested: false)
                == "Foreground command was cancelled and the guest process could not be signalled;"
                + " it may still be running in the guest.")
    }
}
