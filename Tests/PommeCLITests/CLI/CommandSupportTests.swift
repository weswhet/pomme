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
