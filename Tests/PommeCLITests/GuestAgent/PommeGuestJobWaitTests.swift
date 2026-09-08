import Darwin
import Foundation
import Testing

struct PommeGuestJobWaitTests {
    private let jobID = UUID().uuidString.lowercased()

    @Test("Public wait releases exchanges between polls and fetches retained output once")
    func pollsUntilExitAndOutputEOF() throws {
        var operations: [String] = []
        var time = 10.0
        var sleeps = 0
        let frames: [[String: Any]] = [
            ["stream": "stdout", "dataBase64": Data([0, 255, 10]).base64EncodedString()],
            ["stream": "stderr", "dataBase64": Data("error".utf8).base64EncodedString()],
            ["stream": "exit"]
        ]
        let waiter = PommeGuestJobWait(perform: { request, _ in
            switch request {
            case .jobStatus(let supplied):
                #expect(supplied == jobID)
                operations.append("status")
                return response(exited: operations.count >= 2, pending: operations.count < 3)
            case .jobOutput(let supplied):
                #expect(supplied == jobID)
                operations.append("output")
                return response(exited: true, pending: false, code: 7, frames: frames)
            default:
                Issue.record("Public waits must not send process.wait or a signal.")
                throw POSIXError(.EINVAL)
            }
        }, now: { time }, sleep: { interval in
            // This callback runs outside perform, where another host command
            // can acquire the VM lease and the serial guest connection.
            #expect(operations.last == "status")
            sleeps += 1
            time += interval
        })

        let result = try waiter.wait(jobID: jobID, timeout: 1)
        #expect(operations == ["status", "status", "status", "output"])
        #expect(sleeps == 2)
        #expect(result["hostExitCode"] as? Int == 7)
        #expect(result["operation"] as? String == "process.wait")
        #expect((result["result"] as? [String: Any])?["timedOut"] as? Bool == false)
        let output = try CLIOutputWriter.backgroundJobOutput(result)
        #expect(output.count == 2)
        #expect(output[0].descriptor == STDOUT_FILENO)
        #expect(output[0].data == Data([0, 255, 10]))
        #expect(output[1].descriptor == STDERR_FILENO)
        #expect(output[1].data == Data("error".utf8))
    }

    @Test("Fractional wait timeout leaves the target running and does not fetch partial logs")
    func timeoutDoesNotSignal() throws {
        var time = 0.0
        var polls = 0
        var slept = 0.0
        let waiter = PommeGuestJobWait(perform: { request, _ in
            guard case .jobStatus = request else {
                Issue.record("Timeout must not signal or fetch logs.")
                throw POSIXError(.EINVAL)
            }
            polls += 1
            return response(exited: false, pending: true, frames: [
                ["stream": "stdout", "dataBase64": Data("last-poll-only".utf8).base64EncodedString()]
            ])
        }, now: { time }, sleep: { interval in
            #expect(interval > 0 && interval <= 0.05)
            time += interval
            slept += interval
        })

        let result = try waiter.wait(jobID: jobID, timeout: 0.12)
        #expect(polls == 3)
        #expect(abs(slept - 0.12) < 0.000001)
        #expect(result["ok"] as? Bool == false)
        #expect(result["hostExitCode"] as? Int == 124)
        let status = try #require(result["result"] as? [String: Any])
        #expect(status["timedOut"] as? Bool == true)
        #expect(status["exited"] as? Bool == false)
        #expect(try CLIOutputWriter.backgroundJobOutput(result).isEmpty)
    }

    @Test("Wait propagates unknown-job failure without retry")
    func failedStatusIsNotRetried() throws {
        var calls = 0
        let waiter = PommeGuestJobWait(perform: { _, _ in
            calls += 1
            return ["ok": false, "hostExitCode": 1, "error": "not-found"]
        }, sleep: { _ in Issue.record("A failed status cannot be retried.") })
        let result = try waiter.wait(jobID: jobID, timeout: 1)
        #expect(calls == 1)
        #expect(result["error"] as? String == "not-found")
    }

    @Test("Partial control frames cannot exceed the public wait deadline")
    func partialControlResponseTimesOut() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { _ = Darwin.close($0) } }
        var firstByte: UInt8 = 123
        try #require(Darwin.write(pair[1], &firstByte, 1) == 1)
        var calls = 0
        let started = ProcessInfo.processInfo.systemUptime
        let waiter = PommeGuestJobWait(perform: { _, remaining in
            calls += 1
            #expect(remaining > 0 && remaining <= 0.05)
            var reader = ControlWireCodec.FrameReader()
            _ = try reader.readFrame(from: pair[0], deadline: ProcessInfo.processInfo.systemUptime + remaining)
            Issue.record("The incomplete JSONL frame must time out.")
            return response(exited: false, pending: true)
        })
        let result = try waiter.wait(jobID: jobID, timeout: 0.05)
        #expect(result["hostExitCode"] as? Int == 124)
        #expect(calls == 1)
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
    }

    @Test("The host control client applies the remaining deadline to its response")
    func controlClientResponseDeadline() throws {
        let socket = URL(fileURLWithPath: "/tmp/pomme-wait-deadline-\(UUID().uuidString).sock")
        let server = PommeControlServer(socketURL: socket) { _ in
            try? await Task.sleep(for: .milliseconds(150))
            return #"{"ok":true}"#
        }
        try server.start()
        defer { server.stop() }
        let client = PommeControlSocketClient(identity: .init(socketPath: socket.path, pid: getpid(), startedAt: "test"))
        #expect(throws: POSIXError(.ETIMEDOUT)) {
            try client.send(.init(command: "status"), timeout: 0.03)
        }
    }

    @Test("A signalling command can temporarily own the lease between wait polls")
    func leaseContentionDoesNotAbortWait() throws {
        var time = 0.0
        var calls = 0
        let waiter = PommeGuestJobWait(perform: { _, remaining in
            #expect(remaining > 0 && remaining <= 1)
            calls += 1
            if calls == 1 { throw VMBundleMutationLease.Error.activeMutation(name: "test") }
            return response(exited: true, pending: false)
        }, now: { time }, sleep: { time += $0 })
        let result = try waiter.wait(jobID: jobID, timeout: 1)
        #expect(result["hostExitCode"] as? Int == 0)
        #expect(calls == 3)
        #expect(time == 0.05)
    }

    @Test("Wait rejects mismatched job identity and malformed completion")
    func validatesResponses() throws {
        var wrongJob = response(exited: true, pending: false)
        var status = try #require(wrongJob["result"] as? [String: Any])
        status["jobID"] = UUID().uuidString
        wrongJob["result"] = status
        let wrong = PommeGuestJobWait(perform: { _, _ in wrongJob })
        #expect(throws: (any Error).self) { try wrong.wait(jobID: jobID, timeout: 1) }

        let incomplete = PommeGuestJobWait(perform: { request, _ in
            switch request {
            case .jobStatus: return response(exited: true, pending: false)
            case .jobOutput: return response(exited: true, pending: true)
            default: throw POSIXError(.EINVAL)
            }
        })
        #expect(throws: (any Error).self) { try incomplete.wait(jobID: jobID, timeout: 1) }

        let malformedExitCodes: [Any] = [true, 1.5, "0", Int64(-1), Int64(256)]
        for malformedExitCode in malformedExitCodes {
            let malformed = PommeGuestJobWait(perform: { _, _ in
                var result = response(exited: true, pending: false)
                var completed = try #require(result["result"] as? [String: Any])
                completed["exitCode"] = malformedExitCode
                result["result"] = completed
                return result
            })
            #expect(throws: (any Error).self) {
                try malformed.wait(jobID: jobID, timeout: 1)
            }
        }
    }

    @Test("Wait maps signal termination to shell exit status")
    func signalledCompletion() throws {
        let waiter = PommeGuestJobWait(perform: { _, _ in
            var result = response(exited: true, pending: false)
            var status = try #require(result["result"] as? [String: Any])
            status.removeValue(forKey: "exitCode")
            status["signal"] = Int64(15)
            result["result"] = status
            return result
        })
        #expect(try waiter.wait(jobID: jobID, timeout: 1)["hostExitCode"] as? Int == 143)
    }

    @Test("Job logs reject malformed byte frames and preserve empty output")
    func validatesOutputFrames() throws {
        #expect(try CLIOutputWriter.backgroundJobOutput(["streamFrames": [["stream": "exit"]]]).isEmpty)
        let invalidFrames: [[String: Any]] = [
            ["stream": "stdin", "dataBase64": ""],
            ["stream": "stdout", "dataBase64": "invalid"],
            ["stream": "stderr"],
            ["stream": "stdout", "dataBase64": Data(repeating: 0, count: 65_537).base64EncodedString()]
        ]
        for frame in invalidFrames {
            #expect(throws: (any Error).self) {
                try CLIOutputWriter.backgroundJobOutput(["streamFrames": [frame]])
            }
        }
    }

    private func response(exited: Bool, pending: Bool, code: Int = 0,
                          frames: [[String: Any]] = []) -> [String: Any] {
        ["ok": true, "hostExitCode": 0, "streamFrames": frames, "result": [
            // PommeCore.sendControlObject exposes JSONValue integer fields as
            // Int64. Keep this fixture aligned with the actual control path;
            // native Int values would hide a production numeric-cast bug.
            "jobID": jobID, "pid": Int64(42), "exited": exited,
            "outputPending": pending, "outputComplete": exited && !pending,
            "exitCode": Int64(code), "stdoutTruncated": false, "stderrTruncated": false
        ]]
    }
}
