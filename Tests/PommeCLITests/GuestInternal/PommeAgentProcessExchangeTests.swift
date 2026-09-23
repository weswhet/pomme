import Darwin
import Foundation
import Testing
import Synchronization

/// Each test starts a real daemon whose descriptor read blocks synchronously
/// between exchanges. Serialize the suite so concurrent tests cannot occupy
/// every cooperative worker thread; this suite does not assert daemon
/// cross-test concurrency.
@Suite("Pomme agent process exchanges", .serialized)
struct PommeAgentProcessExchangeTests: Sendable {
    @Test("Recovery desktop start does not opt into normal boundary diagnostics")
    func recoveryExcludesDesktopStartBoundaries() async throws {
        let trace = Mutex<[PommeDesktopStartBoundaryTrace.Event]>([])
        let agent = try PommeAgent(role: .recovery, executableSHA256: String(repeating: "a", count: 64))
        try await withDaemon(agent: agent, desktopStartTraceSink: { event, _ in trace.withLock { $0.append(event) } }) { context in
            try await authenticate(using: context.wire)
            let reply = try await exchange(.request(operation: "process.start", payload: .object([
                "path": .string("/bin/ps"), "arguments": .array([.string("-axo"), .string("uid=,comm=")])])), using: context.wire)
            if let jobID = reply.response.result?.objectValue?["jobID"]?.stringValue {
                if !reply.streams.contains(where: { $0.frame.stream == .exit }) {
                    let cleaned = try await finishSignalTraceChild(agent: agent, jobID: jobID, terminate: false)
                    #expect(cleaned)
                }
            }
        }
        #expect(trace.withLock { $0.isEmpty })
    }

    @Test("Authenticated normal desktop start emits ordered closed guest boundaries")
    func desktopStartBoundaries() async throws {
        let trace = Mutex<[PommeDesktopStartBoundaryTrace.Event]>([])
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        try await withDaemon(agent: agent, desktopStartTraceSink: { event, _ in trace.withLock { $0.append(event) } }) { context in
            let payload: JSONValue = .object(["path": .string("/bin/ps"), "arguments": .array([.string("-axo"), .string("uid=,comm=")])])
            let rejected = try await exchange(.request(operation: "process.start", payload: payload), using: context.wire)
            #expect(rejected.response.ok == false)
            #expect(trace.withLock { $0.isEmpty })
            try await authenticate(using: context.wire)
            let reply = try await exchange(.request(operation: "process.start", payload: payload), using: context.wire)
            try #require(reply.response.ok == true)
            let jobID = try #require(reply.response.result?.objectValue?["jobID"]?.stringValue)
            // An exit stream proves reaping; otherwise drain the short-lived
            // child before closing the daemon fixture.
            if !reply.streams.contains(where: { $0.frame.stream == .exit }) {
                let cleaned = try await finishSignalTraceChild(agent: agent, jobID: jobID, terminate: false)
                #expect(cleaned)
            }
        }
        let events = trace.withLock { $0 }
        #expect(Array(events.prefix(5)) == [.requestAccepted, .handlerEntered, .performReturned, .streamsEntered, .streamsReturned])
        #expect(Array(events.suffix(2)) == [.responseWriteEntered, .responseWritten])
        let writes = Array(events.dropFirst(5).dropLast(2))
        #expect(writes.count.isMultiple(of: 2))
        for (index, event) in writes.enumerated() {
            #expect(event == (index.isMultiple(of: 2) ? .streamWriteEntered : .streamWritten))
        }
    }

    @Test("Real daemon foreground timeout signal integration characterization", .serialized, arguments: 0..<20)
    func foregroundTimeoutSignalCharacterization(iteration: Int) async throws {
        _ = iteration
        try await runForegroundTimeoutSignalCharacterization(crossLogicalDeadlineAtStatusWriteEntry: false)
    }

    @Test("Logical foreground deadline crosses at status-response write entry before one signal and a healthy next command")
    func logicalForegroundDeadlineCrossesAtStatusWriteEntry() async throws {
        try await runForegroundTimeoutSignalCharacterization(crossLogicalDeadlineAtStatusWriteEntry: true)
    }

    private func runForegroundTimeoutSignalCharacterization(crossLogicalDeadlineAtStatusWriteEntry: Bool) async throws {
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        let trace = Mutex<[PommeSignalBoundaryTrace.Event]>([])
        let job = Mutex<String?>(nil)
        let startID = Mutex<UUID?>(nil)
        let operations = Mutex<[String]>([])
        let observed = Mutex<(stdout: Bool, stderr: Bool)>((false, false))
        let clock = Mutex(ContinuousClock.now)
        let crossed = Mutex(false)
        let crossedStatusReturned = Mutex(false)
        let nextJob = Mutex<String?>(nil)
        let observationDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        do {
            let result = try await withDaemon(agent: agent, signalTraceSink: { event, _ in
                trace.withLock { $0.append(event) }
                if crossLogicalDeadlineAtStatusWriteEntry, event == .guestStatusResponseWriteEntered,
                   observed.withLock({ $0.stdout && $0.stderr }), !crossed.withLock({ $0 }) {
                    clock.withLock { $0 = $0.advanced(by: .seconds(2)) }
                    crossed.withLock { $0 = true }
                }
            }) { context in
                try await authenticate(using: context.wire)
                let primary = try await PommeForegroundExecution.run(
                    payload: .object([
                        "path": .string("/bin/sh"),
                        "arguments": .array([.string("-c"), .string("printf ready-out; printf ready-err >&2; exec /bin/sleep 60")])
                    ]), timeout: 1,
                    perform: { operation, payload in
                        operations.withLock { $0.append(operation) }
                        let request = PommeAgentProtocol.Envelope.request(operation: operation, payload: payload)
                        let reply = try await exchange(request, using: context.wire, timeout: 5)
                        let value = try #require(reply.response.result)
                        if operation == "process.start" {
                            job.withLock { $0 = value.objectValue?["jobID"]?.stringValue }
                            startID.withLock { $0 = request.requestID }
                        } else {
                            let matches = payload.objectValue?["jobID"]?.stringValue == job.withLock { $0 }
                            try #require(matches)
                        }
                        try #require(reply.response.ok == true)
                        if operation == "process.status" {
                            try #require(value.objectValue?["exited"] == .bool(false))
                            if crossLogicalDeadlineAtStatusWriteEntry, crossed.withLock({ $0 }) {
                                crossedStatusReturned.withLock { $0 = true }
                            }
                        }
                        if operation == "process.signal" {
                            if crossLogicalDeadlineAtStatusWriteEntry { try #require(crossedStatusReturned.withLock { $0 }) }
                            #expect(payload.objectValue?["signal"] == .integer(Int64(SIGTERM)))
                        }
                        return PommeAgentCorrelatedResult(requestID: request.requestID, result: value, streamFrames: reply.streams)
                    },
                    sendStream: { id, stream, data in
                        operations.withLock { $0.append(stream == .eof ? "eof" : "unexpectedStream") }
                        let matches = id.uuidString.lowercased() == job.withLock { $0 }
                        try #require(matches)
                        let request = try PommeAgentJobStreamFrame(
                            jobID: id, frame: .init(requestID: UUID(), stream: stream, data: data)
                        ).envelope()
                        let reply = try await exchange(request, using: context.wire, timeout: 5)
                        try #require(reply.response.ok == true)
                        return reply.streams
                    },
                    pollTiming: .init(now: { clock.withLock { $0 } }, sleep: { _ in
                        // Wait for returned output on both channels, then
                        // cross the logical deadline either here after status
                        // returns, or at the next status-response write entry.
                        // No physical write is delayed and no wire timeout is
                        // induced; neither case reproduces the live timeout.
                        let ready = observed.withLock { $0.stdout && $0.stderr }
                        if crossLogicalDeadlineAtStatusWriteEntry, crossed.withLock({ $0 }) { return }
                        if ready, !crossLogicalDeadlineAtStatusWriteEntry { clock.withLock { $0 = $0.advanced(by: .seconds(2)) } }
                        else {
                            try #require(ContinuousClock.now < observationDeadline)
                            try await Task.sleep(for: .milliseconds(25))
                        }
                    }),
                    onFrames: { frames in
                        let matches = frames.allSatisfy { $0.jobID.uuidString.lowercased() == job.withLock { $0 } }
                        try #require(matches)
                        observed.withLock { value in
                            value.stdout = value.stdout || frames.contains { $0.frame.stream == .stdout && $0.frame.data?.isEmpty == false }
                            value.stderr = value.stderr || frames.contains { $0.frame.stream == .stderr && $0.frame.data?.isEmpty == false }
                        }
                    }
                )
                if crossLogicalDeadlineAtStatusWriteEntry {
                    try #require(crossed.withLock { $0 })
                    let id = try #require(job.withLock { $0 })
                    let cleaned = try await finishSignalTraceChild(agent: agent, jobID: id, terminate: false)
                    try #require(cleaned)
                    // Same authenticated wire, no reconnect or new daemon.
                    let next = try await PommeForegroundExecution.run(
                        payload: .object(["path": .string("/usr/bin/id"), "arguments": .array([.string("-u")])]),
                        timeout: 5,
                        perform: { operation, payload in
                            let request = PommeAgentProtocol.Envelope.request(operation: operation, payload: payload)
                            let reply = try await exchange(request, using: context.wire, timeout: 5)
                            let value = try #require(reply.response.result)
                            if operation == "process.start" {
                                nextJob.withLock { $0 = value.objectValue?["jobID"]?.stringValue }
                            }
                            try #require(reply.response.ok == true)
                            return .init(requestID: request.requestID, result: value, streamFrames: reply.streams)
                        }, sendStream: { id, stream, data in
                            let request = try PommeAgentJobStreamFrame(
                                jobID: id, frame: .init(requestID: UUID(), stream: stream, data: data)).envelope()
                            let reply = try await exchange(request, using: context.wire, timeout: 5)
                            try #require(reply.response.ok == true)
                            return reply.streams
                        })
                    try #require(next.result.objectValue?["exited"] == .bool(true))
                    try #require(next.result.objectValue?["exitCode"] == .integer(0))
                    try #require(next.result.objectValue?["outputComplete"] == .bool(true))
                }
                return primary
            }
            let values = try #require(result.result.objectValue)
            #expect(values["timedOut"] == .bool(true))
            #expect(values["cancelled"] == .bool(false))
            #expect(values["terminationRequested"] == .bool(true))
            let correlated = result.requestID == startID.withLock { $0 }
            #expect(correlated)
            let calls = operations.withLock { $0 }
            #expect(calls.filter { $0 == "process.start" }.count == 1)
            #expect(calls.filter { $0 == "process.signal" }.count == 1)
            #expect(calls.filter { $0 == "eof" }.count == 1)
            #expect(calls.contains("process.status"))
            #expect(calls.last == "process.signal")
            #expect(observed.withLock { $0.stdout && $0.stderr })
            // Ignore the later successful command's status trace only after
            // the first signal response has completed.
            let allEvents = trace.withLock { events in
                guard let end = events.firstIndex(of: .guestResponseWritten) else { return events }
                return Array(events[...end])
            }
            let statusEvents = allEvents.filter { $0.rawValue.hasPrefix("guestStatus") }
            #expect(statusEvents.filter { $0 == .guestStatusHandlerEntered }.count == calls.filter { $0 == "process.status" }.count)
            #expect(statusEvents.filter { $0 == .guestStatusResponseWritten }.count == calls.filter { $0 == "process.status" }.count)
            #expect(Array(allEvents.prefix(statusEvents.count)) == statusEvents)
            let recorded = Array(allEvents.dropFirst(statusEvents.count))
            #expect(Array(recorded.prefix(5)) == [.guestSignalDecoded, .guestHandlerEntered, .guestPerformReturned, .guestStreamsEntered, .guestStreamsReturned])
            #expect(Array(recorded.suffix(2)) == [.guestResponseWriteEntered, .guestResponseWritten])
            let writes = Array(recorded.dropFirst(5).dropLast(2))
            #expect(writes.count.isMultiple(of: 2))
            for (index, event) in writes.enumerated() {
                #expect(event == (index.isMultiple(of: 2) ? .guestStreamWriteEntered : .guestStreamWritten))
            }
            let id = try #require(job.withLock { $0 })
            let cleaned = try await finishSignalTraceChild(agent: agent, jobID: id, terminate: false)
            try #require(cleaned)
        } catch {
            if let id = nextJob.withLock({ $0 }) {
                do {
                    let cleaned = try await finishSignalTraceChild(agent: agent, jobID: id, terminate: true)
                    #expect(cleaned, "Next-command failure must reap and drain its exact child")
                } catch { Issue.record(error, "Next-command cleanup failed") }
            }
            if let id = job.withLock({ $0 }) {
                do {
                    let cleaned = try await finishSignalTraceChild(agent: agent, jobID: id, terminate: true)
                    #expect(cleaned, "Characterization failure must reap and drain its exact child")
                } catch { Issue.record(error, "Characterization child cleanup failed") }
            }
            throw error
        }
    }

    @Test("Guest trace classifies signal admission and excludes Recovery and unauthenticated status", arguments: ["failure", "replay", "unauthenticated", "unauthenticatedStatus", "recovery", "recoveryStatus", "health"])
    func signalTraceAdmission(mode: String) async throws {
        let trace = Mutex<[(PommeSignalBoundaryTrace.Event, Double)]>([])
        let agent = try PommeAgent(role: mode.hasPrefix("recovery") ? .recovery : .persistent,
                                   executableSHA256: String(repeating: "a", count: 64))
        try await withDaemon(agent: agent, signalTraceSink: { event, elapsed in
            trace.withLock { $0.append((event, elapsed)) }
        }) { context in
            if !mode.hasPrefix("unauthenticated") { try await authenticate(using: context.wire) }
            let request = PommeAgentProtocol.Envelope.request(
                operation: mode == "health" ? "agent.health" : mode.hasSuffix("Status") ? "process.status" : "process.signal",
                payload: .object(["jobID": .string(UUID().uuidString.lowercased()), "signal": .integer(15)])
            )
            let response = try await exchange(request, using: context.wire)
            #expect(response.response.ok == (mode == "health"))
            if mode == "replay" {
                let replay = try await exchange(request, using: context.wire)
                #expect(replay.response.ok == false)
                #expect(replay.response.error?.code == "replayed-request")
            }
        }
        let recorded = trace.withLock { $0 }
        var expected: [PommeSignalBoundaryTrace.Event] = []
        if mode == "failure" || mode == "replay" {
            expected = [.guestSignalDecoded, .guestHandlerEntered, .guestPerformFailed, .guestResponseWriteEntered, .guestResponseWritten]
        }
        if mode == "replay" {
            expected += [.guestSignalDecoded, .guestSignalRejectedReplay, .guestResponseWriteEntered, .guestResponseWritten]
        } else if mode == "unauthenticated" {
            expected = [.guestSignalDecoded, .guestSignalRejectedAuthenticationRequired, .guestResponseWriteEntered, .guestResponseWritten]
        }
        #expect(recorded.map(\.0) == expected)
        #expect(recorded.allSatisfy { $0.1.isFinite && $0.1 >= 0 })
        // Each decoded signal starts a fresh local elapsed clock.
        let starts = recorded.indices.filter { recorded[$0].0 == .guestSignalDecoded }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : recorded.endIndex
            let elapsed = recorded[start..<end].map(\.1)
            #expect(elapsed == elapsed.sorted())
        }
    }

    @Test("Authenticated status and signal traces bracket perform, streams, and response")
    func signalTraceSuccess() async throws {
        let trace = Mutex<[PommeSignalBoundaryTrace.Event]>([])
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        let started = try await agent.performAsynchronously(.request(
            operation: "process.start",
            payload: .object(["path": .string("/bin/sleep"), "arguments": .array([.string("60")])])
        ))
        let jobID = try #require(started.objectValue?["jobID"]?.stringValue)
        do {
            try await withDaemon(agent: agent, signalTraceSink: { event, _ in
                trace.withLock { $0.append(event) }
            }) { context in
                try await authenticate(using: context.wire)
                let status = try await exchange(.request(operation: "process.status", payload: .object([
                    "jobID": .string(jobID)
                ])), using: context.wire)
                try #require(status.response.ok == true)
                let signalled = try await exchange(.request(operation: "process.signal", payload: .object([
                    "jobID": .string(jobID), "signal": .integer(Int64(SIGTERM))
                ])), using: context.wire)
                try #require(signalled.response.ok == true)
            }
        } catch {
            do {
                let cleaned = try await finishSignalTraceChild(agent: agent, jobID: jobID, terminate: true)
                #expect(cleaned, "Failed trace exchange must reap and drain its child before releasing the agent")
            } catch {
                Issue.record(error, "Trace child cleanup failed")
            }
            throw error
        }
        let cleaned = try await finishSignalTraceChild(agent: agent, jobID: jobID, terminate: false)
        try #require(cleaned, "Successful trace exchange must reap and drain its child before releasing the agent")
        let allEvents = trace.withLock { $0 }
        let statusEvents = allEvents.filter { $0.rawValue.hasPrefix("guestStatus") }
        #expect(Array(statusEvents.prefix(4)) == [.guestStatusHandlerEntered, .guestStatusPerformReturned, .guestStatusStreamsEntered, .guestStatusStreamsReturned])
        #expect(Array(statusEvents.suffix(2)) == [.guestStatusResponseWriteEntered, .guestStatusResponseWritten])
        #expect(Array(allEvents.prefix(statusEvents.count)) == statusEvents)
        let recorded = Array(allEvents.dropFirst(statusEvents.count))
        #expect(Array(recorded.prefix(5)) == [.guestSignalDecoded, .guestHandlerEntered, .guestPerformReturned, .guestStreamsEntered, .guestStreamsReturned])
        #expect(Array(recorded.suffix(2)) == [.guestResponseWriteEntered, .guestResponseWritten])
        let streamWrites = Array(recorded.dropFirst(5).dropLast(2))
        #expect(streamWrites.count.isMultiple(of: 2))
        for (index, event) in streamWrites.enumerated() {
            #expect(event == (index.isMultiple(of: 2) ? .guestStreamWriteEntered : .guestStreamWritten))
        }
    }

    private func finishSignalTraceChild(agent: PommeAgent, jobID: String, terminate: Bool) async throws -> Bool {
        let id = try #require(UUID(uuidString: jobID))
        // Cleanup does not inherit caller cancellation and retains the actor
        // until a typed exit frame proves native reaping and output EOF.
        // process.wait is deliberately not used: it only accepts detached jobs.
        return try await Task.detached {
            for attempt in 0..<2 {
                if terminate || attempt > 0 {
                    _ = try? await agent.performAsynchronously(.request(operation: "process.signal", payload: .object([
                        "jobID": .string(jobID), "signal": .integer(Int64(SIGKILL))
                    ])))
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while ContinuousClock.now < deadline {
                    let frames = try await agent.streamEvents(jobID: id, requestID: UUID())
                    if frames.contains(where: { $0.stream == .exit }) { return true }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            return false
        }.value
    }

    @Test("Client exchange budget begins only after delayed daemon admission")
    func delayedDaemonAdmission() async throws {
        let admitted = Mutex(false)
        try await withDaemon(beforeServing: {
            // Deliberately longer than the unchanged one-second wire budget.
            try? await Task.sleep(for: .milliseconds(1_200))
            admitted.withLock { $0 = true }
        }) { context in
            #expect(admitted.withLock { $0 })
            try await authenticate(using: context.wire)
        }
    }

    @Test("Authenticated reconnect retains the original job after a dropped signal response")
    func reconnectAfterDroppedSignalResponse() async throws {
        let agent = try PommeAgent(role: .persistent, executableSHA256: String(repeating: "a", count: 64))
        let retainedID = Mutex<UUID?>(nil)
        do {
            let jobID = try await withDaemon(agent: agent) { context in
                try await authenticate(using: context.wire)
                let started = try await exchange(.request(
                    operation: "process.start",
                    payload: .object(["path": .string("/bin/sleep"), "arguments": .array([.string("10")])])
                ), using: context.wire)
                try #require(started.response.ok == true)
                let text = try #require(started.response.result?.objectValue?["jobID"]?.stringValue)
                let id = try #require(UUID(uuidString: text))
                retainedID.withLock { $0 = id }
                let signal = PommeAgentProtocol.Envelope.request(
                    operation: "process.signal",
                    payload: .object(["jobID": .string(text), "signal": .integer(Int64(SIGTERM))])
                )
                // Send once without reading the response. withDaemon then
                // half-closes A and joins serve, proving queued requests were
                // processed before its unread response and socket are dropped.
                let encoded = try PommeAgentProtocol.encode(signal)
                let sent = encoded.withUnsafeBytes {
                    Darwin.send(context.clientDescriptor, $0.baseAddress, $0.count, 0)
                }
                try #require(sent == encoded.count)
                return id
            }

            try await withDaemon(agent: agent) { context in
                try await authenticate(using: context.wire)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var observedExit = false
                var operations: [String] = []
                while ContinuousClock.now < deadline, !observedExit {
                    let request = PommeAgentProtocol.Envelope.request(
                        operation: "process.status",
                        payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
                    )
                    operations.append(request.operation)
                    let remaining = ContinuousClock.now.duration(to: deadline).components
                    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                    guard seconds > 0 else { break }
                    let result = try await exchange(request, using: context.wire, timeout: min(1, seconds))
                    try #require(result.response.ok == true)
                    #expect(result.response.result?.objectValue?["jobID"]?.stringValue == jobID.uuidString.lowercased())
                    #expect(result.streams.allSatisfy { $0.jobID == jobID && $0.frame.requestID == request.requestID })
                    // The response can precede reaping in streamEvents; an
                    // exited=false snapshot does not invalidate its later exit.
                    if let exit = result.streams.first(where: { $0.frame.stream == .exit }) {
                        #expect(exit.frame.signal == SIGTERM)
                        #expect(exit.frame.data == nil)
                        observedExit = true
                    }
                    await Task.yield()
                }
                try #require(observedExit)
                #expect(operations.isEmpty == false)
                #expect(operations.allSatisfy { $0 == "process.status" })
            }

            // A new registry cannot manufacture the original job's cleanup.
            try await withDaemon { context in
                try await authenticate(using: context.wire)
                let result = try await exchange(.request(
                    operation: "process.status",
                    payload: .object(["jobID": .string(jobID.uuidString.lowercased())])
                ), using: context.wire)
                #expect(result.response.ok == false)
                #expect(result.response.error?.code == "not-found")
                #expect(result.streams.isEmpty)
                #expect(result.response.result == nil)
            }
        } catch {
            if let jobID = retainedID.withLock({ $0 }) {
                // Failure-only cleanup is direct to the original actor, never
                // a mutation on reconnected B. The child is also bounded.
                _ = try? await agent.perform(.request(operation: "process.signal", payload: .object([
                    "jobID": .string(jobID.uuidString.lowercased()), "signal": .integer(Int64(SIGKILL))
                ])))
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var reaped = false
                while ContinuousClock.now < deadline, !reaped {
                    let status = try? await agent.perform(.request(operation: "process.status", payload: .object([
                        "jobID": .string(jobID.uuidString.lowercased())
                    ])))
                    reaped = status?.objectValue?["exited"] == .bool(true)
                    await Task.yield()
                }
                #expect(reaped, "Failure cleanup must reap the bounded child")
            }
            throw error
        }
    }

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
        agent suppliedAgent: PommeAgent? = nil,
        beforeServing: (@Sendable () async -> Void)? = nil,
        signalTraceSink: PommeSignalBoundaryTrace.Sink? = nil,
        desktopStartTraceSink: PommeDesktopStartBoundaryTrace.Sink? = nil,
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
        let agent = try suppliedAgent ?? PommeAgent(role: .persistent, executableSHA256: token)
        let context = DaemonContext(
            wire: PommeAgentVSOCKWire(fileDescriptor: client),
            connection: connection,
            clientDescriptor: client
        )
        let admission = DaemonTaskAdmission()
        let serving = Task {
            await beforeServing?()
            // Task-start admission only: this does not claim bytes were read.
            admission.enter()
            await PommeAgentDaemon.serve(
                descriptor: server,
                connection: connection,
                agent: agent,
                allowedOperation: nil,
                signalTraceSink: signalTraceSink,
                desktopStartTraceSink: desktopStartTraceSink
            )
        }

        await admission.wait()
        do {
            try Task.checkCancellation()
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

private final class DaemonTaskAdmission: Sendable {
    private let state = Mutex<(entered: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func wait() async {
        await withCheckedContinuation { continuation in
            let entered = state.withLock { value in
                if value.entered { return true }
                value.waiter = continuation
                return false
            }
            if entered { continuation.resume() }
        }
    }

    func enter() {
        let waiter = state.withLock { value in
            value.entered = true
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

private struct DaemonContext: Sendable {
    let wire: PommeAgentVSOCKWire
    let connection: PommeAgentConnection
    let clientDescriptor: Int32
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
