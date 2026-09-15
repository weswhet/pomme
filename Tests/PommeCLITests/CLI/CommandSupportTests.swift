import Foundation
import Testing

@Suite("CLI output chunk validation")
struct CommandSupportTests {
    @Test("Terminal output accepts one complete 64 KiB stream chunk")
    func terminalOutputAcceptsStreamLimit() throws {
        let expected = Data(repeating: 0xA5, count: PommeControlProtocol.maximumStreamChunkBytes)

        #expect(try CLIOutputWriter.terminalOutput([
            "dataBase64": expected.base64EncodedString()
        ]) == expected)
    }

    @Test("Terminal output rejects oversized chunks")
    func terminalOutputRejectsOversizedChunk() {
        let oversized = Data(repeating: 0xA5, count: PommeControlProtocol.maximumStreamChunkBytes + 1)

        #expect(throws: RunnerError.self) {
            try CLIOutputWriter.terminalOutput(["dataBase64": oversized.base64EncodedString()])
        }
    }

    @Test("Terminal output rejects malformed base64")
    func terminalOutputRejectsMalformedBase64() {
        #expect(throws: RunnerError.self) {
            try CLIOutputWriter.terminalOutput(["dataBase64": "not-base64!"])
        }
    }

    @Test("JSONL splits a list-shaped payload into one object per element")
    func jsonlSplitsCollection() {
        let payload: [String: Any] = ["ok": true, "vms": [["name": "a"], ["name": "b"]]]
        let lines = CLIOutputWriter.jsonlLines(payload: payload, keyPath: ["vms"])

        #expect(lines.map { $0["name"] as? String } == ["a", "b"])
    }

    @Test("JSONL prints nothing for an empty collection")
    func jsonlEmptyCollection() {
        #expect(CLIOutputWriter.jsonlLines(payload: ["ok": true, "vms": [[String: Any]]()], keyPath: ["vms"]).isEmpty)
    }

    @Test("JSONL prints the whole payload when the collection is absent")
    func jsonlWholePayloadWithoutCollection() {
        let failure: [String: Any] = ["ok": false, "error": "The helper is not running."]
        let lines = CLIOutputWriter.jsonlLines(payload: failure, keyPath: ["result", "jobs"])

        #expect(lines.count == 1)
        #expect(lines.first?["error"] as? String == "The helper is not running.")
    }

    @Test("JSONL follows a nested key path")
    func jsonlNestedKeyPath() {
        let payload: [String: Any] = ["ok": true, "result": ["jobs": [["jobID": "j1"]]]]

        #expect(CLIOutputWriter.jsonlLines(payload: payload, keyPath: ["result", "jobs"]).map { $0["jobID"] as? String } == ["j1"])
    }

    @Test("The raw output format is no longer accepted")
    func rawFormatRejected() throws {
        #expect(throws: (any Error).self) {
            try GlobalOptions.parse(["--format", "raw"])
        }
        #expect(try GlobalOptions.parse(["--format", "jsonl"]).resolvedFormat() == .jsonl)
    }

    @Test("Failed text results render on stderr with the Error prefix")
    func failedTextResultsRenderOnStderr() {
        let failed = operationResult(ok: false, text: "The terminal session was not found.")

        #expect(CLIOutputWriter.tableRendering(for: failed)
                == .text(descriptor: STDERR_FILENO, text: "Error: The terminal session was not found."))
        #expect(CLIOutputWriter.tableRendering(for: failed, label: "t1")
                == .text(descriptor: STDERR_FILENO, text: "Error: t1: The terminal session was not found."))
        #expect(CLIOutputWriter.tableRendering(for: operationResult(ok: false, text: ""))
                == .text(descriptor: STDERR_FILENO, text: "Error: The operation failed."))
    }

    @Test("Successful text results stay on stdout without a prefix")
    func successfulTextResultsStayOnStdout() {
        let stopped = operationResult(ok: true, text: "VM is already stopped.")

        #expect(CLIOutputWriter.tableRendering(for: stopped)
                == .text(descriptor: STDOUT_FILENO, text: "VM is already stopped."))
        #expect(CLIOutputWriter.tableRendering(for: stopped, label: "t1")
                == .text(descriptor: STDOUT_FILENO, text: "VM is already stopped."))
    }

    @Test("Byte-carrying results keep their frame routes whether or not they failed")
    func byteResultsKeepFrameRoutes() {
        let foreground = operationResult(ok: false, text: "", payload: ["foreground": true, "streamFrames": []])
        let job = operationResult(ok: false, text: "", payload: ["operation": "process.wait", "streamFrames": [[String: Any]]()])
        let logs = operationResult(ok: true, text: "", payload: ["operation": "terminal.logs", "dataBase64": ""])
        let failedLogs = operationResult(ok: false, text: "The transcript offset is invalid.", payload: ["operation": "terminal.logs"])
        let failedRead = operationResult(ok: false, text: "The file is missing.", payload: ["operation": "file.read"])

        #expect(CLIOutputWriter.tableRendering(for: foreground) == .foregroundFrames)
        #expect(CLIOutputWriter.tableRendering(for: job) == .jobFrames)
        #expect(CLIOutputWriter.tableRendering(for: logs) == .terminalBytes)
        #expect(CLIOutputWriter.tableRendering(for: failedLogs)
                == .text(descriptor: STDERR_FILENO, text: "Error: The transcript offset is invalid."))
        #expect(CLIOutputWriter.tableRendering(for: failedRead)
                == .text(descriptor: STDERR_FILENO, text: "Error: The file is missing."))
    }

    private func operationResult(ok: Bool, text: String, payload: [String: Any] = [:]) -> PommeOperationResult {
        PommeOperationResult(
            title: "Test",
            vmName: "t1",
            ok: ok,
            hostExitCode: ok ? 0 : 1,
            text: text,
            payload: payload
        )
    }

    @Test("File output retains its strict 32 KiB limit")
    func fileOutputRetainsFileLimit() throws {
        let maximum = Data(repeating: 0x5A, count: PommeAgentProtocol.maximumFileChunkBytes)
        let oversized = Data(repeating: 0x5A, count: PommeAgentProtocol.maximumFileChunkBytes + 1)

        #expect(try CLIOutputWriter.fileOutput([
            "dataBase64": maximum.base64EncodedString()
        ]) == maximum)
        #expect(throws: RunnerError.self) {
            try CLIOutputWriter.fileOutput(["dataBase64": oversized.base64EncodedString()])
        }
    }
}
