import Foundation
import Testing

@Suite("Pomme CLI guest-agent models")
struct PommeAgentCLIModelsTests {
    @Test("Process requests expose a Pomme start operation and preserve execution controls")
    func processRequestPayload() throws {
        let request = GuestCommandRequest(
            path: "/bin/sh",
            arguments: ["-c", "printf ok"],
            timeout: 12,
            inputData: Data("input".utf8),
            pty: false,
            cwd: "/tmp",
            environment: ["POMME_TEST": "yes"],
            user: "root",
            guestStdoutPath: "/tmp/output"
        )
        try request.validate()
        let control = request.controlPayload
        #expect(control["command"] as? String == "agent.perform")
        #expect(control["operation"] as? String == "process.start")
        let payload = try #require(control["payload"] as? [String: Any])
        #expect(payload["path"] as? String == "/bin/sh")
        #expect(payload["stdinDataBase64"] as? String == Data("input".utf8).base64EncodedString())
        #expect(payload["stdoutPath"] as? String == "/tmp/output")
        #expect(try GuestCommandRequest.parse(from: control).path == "/bin/sh")
    }

    @Test("Identity selectors, PTY, and detached execution are mutually exclusive")
    func processValidation() {
        let conflictingUser = GuestCommandRequest(path: "/bin/true", arguments: [], timeout: 1, user: "root", uid: 0)
        #expect(throws: RunnerError.self) { try conflictingUser.validate() }

        let conflictingGroup = GuestCommandRequest(path: "/bin/true", arguments: [], timeout: 1, group: "wheel", gid: 0)
        #expect(throws: RunnerError.self) { try conflictingGroup.validate() }

        let detachedPTY = GuestCommandRequest(path: "/bin/true", arguments: [], timeout: 1, pty: true)
        #expect(throws: RunnerError.self) { try detachedPTY.validate(detached: true) }

        let oversizedInput = GuestCommandRequest(
            path: "/bin/true",
            arguments: [],
            timeout: 1,
            inputData: Data(repeating: 0, count: PommeAgentCLIModelLimits.maximumStreamChunkBytes + 1)
        )
        #expect(throws: RunnerError.self) { try oversizedInput.validate() }
    }

    @Test("CLI operations use correlated process and agent operation names")
    func cliOperationMapping() throws {
        let id = "00000000-0000-0000-0000-000000000042"
        let start = GuestCLIRequest.startBackground(.init(path: "/bin/true", arguments: [], timeout: 1))
        try start.validate()
        #expect(start.controlPayload["operation"] as? String == "process.start")
        let startPayload = try #require(start.controlPayload["payload"] as? [String: Any])
        #expect(startPayload["detached"] as? Bool == true)

        let status = GuestCLIRequest.jobStatus(id)
        try status.validate()
        #expect(status.controlPayload["operation"] as? String == "process.status")
        let signal = GuestCLIRequest.jobKill(jobID: id, signal: .term)
        #expect(signal.controlPayload["operation"] as? String == "process.signal")
        #expect((signal.controlPayload["payload"] as? [String: Any])?["signal"] as? Int == 15)
        #expect(GuestCLIRequest.health.controlPayload["operation"] as? String == "agent.health")
        #expect(GuestCLIRequest.capabilities.controlPayload["operation"] as? String == "agent.describe")
    }

    @Test("File requests reject unsafe endpoints and enforce the 32 KiB read limit")
    func fileRequestValidation() throws {
        #expect(throws: RunnerError.self) { try CopyEndpoint.parse("alias:/tmp/file") }
        #expect(throws: RunnerError.self) { try CopyRequest.parse(source: "/tmp/a", destination: "/tmp/b") }
        #expect(throws: RunnerError.self) {
            try CatRequest.parse(path: "guest:/tmp/file", offset: 0, count: PommeAgentCLIModelLimits.maximumFileChunkBytes + 1)
        }

        let copy = try CopyRequest.parse(source: "/tmp/source", destination: "guest:/tmp/destination")
        #expect(copy.controlPayload["operation"] as? String == "file.transfer")
        let copyPayload = try #require(copy.controlPayload["payload"] as? [String: Any])
        #expect((copyPayload["source"] as? [String: Any])?["kind"] as? String == "host")
        #expect((copyPayload["destination"] as? [String: Any])?["kind"] as? String == "guest")

        let cat = try CatRequest.parse(path: "guest:/tmp/file", offset: 8, count: 32)
        #expect(cat.controlPayload["operation"] as? String == "file.read")
        #expect((cat.controlPayload["payload"] as? [String: Any])?["count"] as? Int == 32)
    }

    @Test("Remote login and screen sharing requests have closed payloads")
    func servicePayloads() throws {
        let remote = RemoteLoginRequest(enabled: true)
        #expect(remote.controlPayload["operation"] as? String == "remoteLogin.set")
        let parsedRemote = try RemoteLoginRequest.parse(from: remote.controlPayload)
        #expect(parsedRemote.enabled)
        #expect(throws: RunnerError.self) {
            var payload = remote.controlPayload
            payload["unexpected"] = true
            _ = try RemoteLoginRequest.parse(from: payload)
        }

        let screen = ScreenSharingRequest(action: .status)
        #expect(screen.controlPayload["operation"] as? String == "ui.screenSharing")
        #expect(try ScreenSharingRequest.parse(from: screen.controlPayload).action == .status)
    }

    @Test("Process result accepts a bounded start result and rejects oversized output")
    func processResultParsing() throws {
        let id = "00000000-0000-0000-0000-000000000042"
        let result = try GuestCommandResult.parse(from: [
            "ok": true,
            "result": [
                "jobID": id,
                "pid": 42,
                "detached": true,
                "exited": false
            ]
        ])
        #expect(result.jobID?.uuidString.lowercased() == id)
        #expect(result.hostExitCode == 0)
        #expect(result.detached)
        #expect(!result.exited)

        let streamResult = try GuestCommandResult.parse(from: [
            "ok": true,
            "requestID": id,
            "result": ["jobID": id, "pid": 42, "detached": false],
            "streamFrames": [
                ["jobID": id, "requestID": id, "stream": "stdout", "dataBase64": Data("out".utf8).base64EncodedString()],
                ["jobID": id, "requestID": id, "stream": "exit"]
            ]
        ])
        #expect(streamResult.stdout == Data("out".utf8))
        #expect(streamResult.exited)

        let oversized = Data(repeating: 1, count: PommeAgentCLIModelLimits.maximumStreamChunkBytes + 1).base64EncodedString()
        #expect(throws: RunnerError.self) {
            _ = try GuestCommandResult.parse(from: ["ok": true, "stdoutDataBase64": oversized])
        }
    }
}
