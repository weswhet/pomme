import ArgumentParser
import Darwin
import Foundation
import Testing

@Suite("CLI output chunk validation", .serialized)
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

    @Test("Restart stop method is top-level in JSON and JSONL")
    func restartStopMethodSurvivesStructuredOutput() throws {
        let payload = PommeApplication.restartPayload(
            status: ["phase": "status"],
            stop: ["phase": "stop", "stopMethod": VMStopOutcome.forced.rawValue],
            boot: ["phase": "boot", "stopMethod": "boot-conflict", "ok": true],
            preservedMode: true
        )
        let result = operationResult(ok: true, text: "OK boot mode=normal", payload: payload)

        let captured = try captureStandardOutputAndError {
            for format in ["json", "jsonl"] {
                try CLIOutputWriter.write(result, options: GlobalOptions.parse(["--format", format]))
            }
        }

        let lines = captured.stdout.split(separator: "\n")
        #expect(lines.count == 2)
        let objects = try lines.map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(objects.map { $0["stopMethod"] as? String } == ["forced", "forced"])
        #expect(objects.allSatisfy { $0["operation"] as? String == "restart" })
        #expect(captured.stderr.isEmpty)
    }

    @Test("Recovery helper diagnostics stay on stderr for successful and failed JSON and JSONL results")
    func recoveryHelperDiagnosticsDoNotLeakIntoStructuredOutput() throws {
        // Exercise the metadata boundary used by PommeApplication.terminalSessionCreate,
        // then the actual public writer, without a VM, socket, or production test seam.
        for format in ["json", "jsonl"] {
            for ok in [true, false] {
                let directory = "/tmp/pomme-recovery-debug-test-2026-09-20T23-10-26.123Z-attempt"
                let filename = "0001_2026-09-20T23-10-26.123Z_recoveryUtilities_shift-command-t_to_terminal.png"
                let warning = "capture timed out"
                var payload: [String: Any] = [
                    "ok": ok,
                    "sessionID": "session-test",
                    "operation": "terminal.create",
                    "recoveryDebugScreenshotDirectory": directory,
                    "recoveryDebugScreenshotFiles": [filename],
                    "recoveryDebugScreenshotWarnings": [warning],
                ]
                if !ok { payload["error"] = "Recovery navigation failed." }
                let options = try GlobalOptions.parse(["--format", format])
                var exitCode: ExitCode?

                let captured = try captureStandardOutputAndError {
                    PommeRecoveryDebugScreenshotOutput.renderAndRemove(from: &payload)
                    do {
                        try CLIOutputWriter.write(
                            operationResult(ok: ok, text: "session session-test", payload: payload),
                            options: options
                        )
                    } catch let error as ExitCode {
                        exitCode = error
                    }
                }

                let lines = captured.stdout.split(separator: "\n")
                #expect(lines.count == 1)
                let object = try #require(JSONSerialization.jsonObject(with: Data(captured.stdout.utf8)) as? [String: Any])
                #expect(object["ok"] as? Bool == ok)
                #expect(object["sessionID"] as? String == "session-test")
                #expect(object["hostExitCode"] as? Int == (ok ? 0 : 1))
                #expect(exitCode == (ok ? nil : ExitCode(1)))
                if !ok { #expect(object["error"] as? String == "Recovery navigation failed.") }
                for key in ["recoveryDebugScreenshotDirectory", "recoveryDebugScreenshotFiles", "recoveryDebugScreenshotWarnings"] {
                    #expect(object[key] == nil)
                    #expect(!captured.stdout.contains(key))
                }
                for diagnostic in [directory, filename, warning] {
                    #expect(!captured.stdout.contains(diagnostic))
                    #expect(captured.stderr.contains(diagnostic))
                }
                #expect(captured.stderr.contains("Recovery debug screenshots: " + directory))
                #expect(captured.stderr.contains("Warning: Recovery debug screenshot " + warning))
            }
        }
    }

    /// Keep descriptor redirection synchronous and restore both streams even if
    /// rendering throws. Small synthetic responses fit within the pipe buffers.
    private func captureStandardOutputAndError(_ body: () throws -> Void) throws -> (stdout: String, stderr: String) {
        let output = Pipe()
        let error = Pipe()
        fflush(nil)
        let originalOutput = dup(STDOUT_FILENO)
        let originalError = dup(STDERR_FILENO)
        guard originalOutput >= 0, originalError >= 0 else {
            if originalOutput >= 0 { close(originalOutput) }
            if originalError >= 0 { close(originalError) }
            throw POSIXError(.EBADF)
        }
        defer {
            fflush(nil)
            dup2(originalOutput, STDOUT_FILENO)
            dup2(originalError, STDERR_FILENO)
            close(originalOutput)
            close(originalError)
        }
        guard dup2(output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0,
              dup2(error.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0 else {
            throw POSIXError(.EBADF)
        }
        try body()
        fflush(nil)
        dup2(originalOutput, STDOUT_FILENO)
        dup2(originalError, STDERR_FILENO)
        try output.fileHandleForWriting.close()
        try error.fileHandleForWriting.close()
        return (
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
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
