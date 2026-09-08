import Testing

@Suite("Pomme create resume contract")
struct CreateCommandTests {
    @Test("Direct create rejects non-positive and malformed resource sizes in every execution mode", arguments: [
        "0GB",
        "0B",
        "0",
        "0.1B",
        "invalid",
        "-1GB",
        "18446744073709551615B",
        "18446744073709551616B"
    ])
    func rejectsInvalidResourceSize(value: String) {
        for flag in ["--disk-size", "--memory"] {
            #expect(ByteSizeParser.parse(value) == nil)
            for dryRun in [false, true] {
                var arguments = [
                    "research-agent",
                    "--version", "26.6.0",
                    flag, value
                ]
                if dryRun { arguments.append("--dry-run") }

                #expect(throws: Error.self) {
                    var command = try CreateCommand.parse(arguments)
                    try command.validate()
                }
            }
        }
    }

    @Test("Direct create accepts positive disk and memory sizes before runtime effects", arguments: [false, true])
    func acceptsValidResourceSizes(dryRun: Bool) throws {
        var arguments = [
            "research-agent",
            "--version", "26.6.0",
            "--disk-size", "40GB",
            "--memory", "4GB"
        ]
        if dryRun { arguments.append("--dry-run") }

        var command = try CreateCommand.parse(arguments)
        try command.validate()

        #expect(command.diskSize == "40GB")
        #expect(command.memory == "4GB")
        #expect(ByteSizeParser.parse(command.diskSize) == 40 * 1024 * 1024 * 1024)
        #expect(ByteSizeParser.parse(command.memory) == 4 * 1024 * 1024 * 1024)
    }

    @Test("Resume accepts only a target and presentation options")
    func resumeGrammar() throws {
        var command = try CreateCommand.parse(["research-agent", "--resume", "--debug", "--json"])
        try command.validate()
        #expect(command.name == "research-agent")
        #expect(command.resume)
        #expect(command.output.debug)
        #expect(command.output.json)
    }

    @Test("Resume rejects creation parameters", arguments: [
        ["research-agent", "--resume", "--version", "26.6.0"],
        ["research-agent", "--resume", "--restore-image", "/tmp/Restore.ipsw"],
        ["research-agent", "--resume", "--config", "create.yaml"],
        ["research-agent", "--resume", "--dry-run"],
        ["research-agent", "--resume", "--parallel"]
    ])
    func resumeExclusivity(arguments: [String]) {
        #expect(throws: Error.self) {
            var command = try CreateCommand.parse(arguments)
            try command.validate()
        }
    }
}
