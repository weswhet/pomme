import ArgumentParser
import Testing

@Suite("Guest unified log command grammar")
struct LogCommandTests {
    @Test("History defaults and explicit values produce the host request")
    func historyPayload() throws {
        var defaults = try LogCommand.parse(["dev"])
        var explicit = try LogCommand.parse([
            "dev", "--last", "boot", "--category", "buddy-preferences", "--category", "owner",
            "--level", "debug", "--format", "jsonl", "--timeout", "300"
        ])
        try defaults.validate()
        try explicit.validate()

        let defaultPayload = try defaults.payload()
        let explicitPayload = try explicit.payload()
        #expect(defaultPayload["last"] as? String == "10m")
        #expect(defaultPayload["categories"] as? [String] == [])
        #expect(defaultPayload["level"] as? String == "info")
        #expect(defaultPayload["format"] as? String == "text")
        #expect(defaultPayload["timeout"] as? Double == 60)
        #expect(explicitPayload["last"] as? String == "boot")
        #expect(explicitPayload["categories"] as? [String] == ["buddy-preferences", "owner"])
        #expect(explicitPayload["level"] as? String == "debug")
        #expect(explicitPayload["format"] as? String == "jsonl")
        #expect(explicitPayload["timeout"] as? Double == 300)
    }

    @Test("Follow sends only streaming options")
    func followPayload() throws {
        var command = try LogCommand.parse(["dev", "--follow", "--category", "buddy-preferences", "--format", "jsonl"])
        try command.validate()

        let payload = try command.payload()
        #expect(payload["categories"] as? [String] == ["buddy-preferences"])
        #expect(payload["level"] as? String == "info")
        #expect(payload["format"] as? String == "jsonl")
        #expect(payload["last"] == nil)
        #expect(payload["timeout"] == nil)
    }

    @Test("POMME_VM_NAME is used only when the target is omitted")
    func targetResolution() throws {
        let omitted = try LogCommand.parse([])
        let explicit = try LogCommand.parse(["other-vm"])

        #expect(try omitted.target(environmentTarget: "default-vm") == "default-vm")
        #expect(try explicit.target(environmentTarget: "default-vm") == "other-vm")
        #expect(throws: ValidationError.self) {
            _ = try omitted.target(environmentTarget: nil)
        }
    }

    @Test("Duration validation accepts boot and positive unit values", arguments: ["boot", "1s", "0.5m", "1h", "2d"])
    func validLast(_ last: String) throws {
        var command = try LogCommand.parse(["dev", "--last", last])
        try command.validate()
    }

    @Test("Duration validation rejects malformed values", arguments: ["", "0s", "-1m", "1", "1w", "nanh", "infd"])
    func invalidLast(_ last: String) {
        #expect(throws: (any Error).self) {
            var command = try LogCommand.parse(["dev", "--last", last])
            try command.validate()
        }
    }

    @Test("History timeout cannot exceed five minutes", arguments: ["300.1", "301"])
    func invalidHistoryTimeout(_ timeout: String) {
        #expect(throws: (any Error).self) {
            var command = try LogCommand.parse(["dev", "--timeout", timeout])
            try command.validate()
        }
    }

    @Test("Follow rejects history limits, timeouts, and JSON documents", arguments: [
        ["dev", "--follow", "--last", "1m"],
        ["dev", "--follow", "--timeout", "30"],
        ["dev", "--follow", "--format", "json"],
        ["dev", "--follow", "--json"]
    ])
    func followConflicts(_ arguments: [String]) {
        #expect(throws: (any Error).self) {
            var command = try LogCommand.parse(arguments)
            try command.validate()
        }
    }

    @Test("JSON shorthand and format conflicts follow shared conventions")
    func formatValidation() throws {
        var shorthand = try LogCommand.parse(["dev", "--json"])
        var matching = try LogCommand.parse(["dev", "--json", "--format", "json"])
        try shorthand.validate()
        try matching.validate()
        #expect(try shorthand.payload()["format"] as? String == "json")
        #expect(try matching.payload()["format"] as? String == "json")

        #expect(throws: (any Error).self) {
            var command = try LogCommand.parse(["dev", "--json", "--format", "jsonl"])
            try command.validate()
        }
    }

    @Test("Log is listed in root help and guest command discovery")
    func discovery() {
        #expect(PommeCLI.helpMessage().contains("log"))
        #expect(CommandCatalog.agentHelp.contains("guest=exec|shell|log|jobs"))
        #expect(CommandCatalog.groups.contains { group in
            group.name == "guest" && group.commands.contains("log")
        })
    }
}
