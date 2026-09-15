import Testing

@Suite("Pomme create resume contract", .serialized)
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

    @Test("--latest is shorthand for --version latest")
    func latestFlag() throws {
        var command = try CreateCommand.parse(["research-agent", "--latest", "--dry-run"])
        try command.validate()
        #expect(command.version == "latest")

        var explicit = try CreateCommand.parse(["research-agent", "--latest", "--version", "latest"])
        try explicit.validate()
        #expect(explicit.version == "latest")
    }

    @Test("--from-template excludes restore-image sources, config, and resume", arguments: [
        ["research-agent", "--from-template", "base", "--version", "26.6.0"],
        ["research-agent", "--from-template", "base", "--latest"],
        ["research-agent", "--from-template", "base", "--restore-image", "/tmp/Restore.ipsw"],
        ["research-agent", "--from-template", "base", "--ipsw-device", "Mac14,2"],
        ["--config", "create.yaml", "--from-template", "base"],
        ["research-agent", "--resume", "--from-template", "base"]
    ])
    func templateExclusivity(arguments: [String]) {
        #expect(throws: Error.self) {
            var command = try CreateCommand.parse(arguments)
            try command.validate()
        }
    }

    @Test("Creation boots normally by default; --recovery and --shutdown select the alternatives")
    func bootDefaultsAndFlags() throws {
        var normal = try CreateCommand.parse(["research-agent", "--latest"])
        try normal.validate()
        #expect(normal.boot == .normal)
        #expect(normal.boot.startMode == .normal)

        var recovery = try CreateCommand.parse(["research-agent", "--latest", "--recovery"])
        try recovery.validate()
        #expect(recovery.boot == .recovery)

        var shutdown = try CreateCommand.parse(["research-agent", "--latest", "--shutdown"])
        try shutdown.validate()
        #expect(shutdown.boot == .none)
        #expect(shutdown.boot.startMode == .none)

        for arguments in [
            ["research-agent", "--latest", "--recovery", "--shutdown"],
            ["research-agent", "--latest", "--recovery", "--boot", "none"],
            ["research-agent", "--latest", "--shutdown", "--boot", "recovery"]
        ] {
            #expect(throws: Error.self) {
                var command = try CreateCommand.parse(arguments)
                try command.validate()
            }
        }
    }

    @Test("--from-template validates without a restore source")
    func templateAlone() throws {
        var command = try CreateCommand.parse(["research-agent", "--from-template", "base", "--memory", "4GB"])
        try command.validate()
        #expect(command.fromTemplate == "base")
        #expect(command.version == nil)
    }

    @Test("--latest rejects a conflicting --version or --restore-image", arguments: [
        ["research-agent", "--latest", "--version", "26.6.0"],
        ["research-agent", "--latest", "--restore-image", "/tmp/Restore.ipsw"],
        ["research-agent", "--resume", "--latest"],
        ["--config", "create.yaml", "--latest"]
    ])
    func latestExclusivity(arguments: [String]) {
        #expect(throws: Error.self) {
            var command = try CreateCommand.parse(arguments)
            try command.validate()
        }
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

    @Test("Parallel is a bare flag that names its own misuse")
    func parallelFlagGrammar() throws {
        var bare = try CreateCommand.parse(["--config", "create.yaml", "--dry-run", "--parallel"])
        try bare.validate()
        #expect(bare.parallel)

        do {
            var counted = try CreateCommand.parse(["--config", "create.yaml", "--dry-run", "--parallel", "2"])
            try counted.validate()
            Issue.record("--parallel 2 was accepted.")
        } catch {
            #expect(CreateCommand.fullMessage(for: error).contains("--parallel takes no value"))
        }

        #expect(throws: Error.self) {
            _ = try CreateCommand.parse(["--config", "create.yaml", "--parallel-limit", "2"])
        }
    }

    @Test("Resume rejects creation parameters", arguments: [
        ["research-agent", "--resume", "--version", "26.6.0"],
        ["research-agent", "--resume", "--restore-image", "/tmp/Restore.ipsw"],
        ["research-agent", "--resume", "--config", "create.yaml"],
        ["research-agent", "--resume", "--dry-run"],
        ["research-agent", "--resume", "--parallel"],
        ["research-agent", "--resume", "--recovery"],
        ["research-agent", "--resume", "--shutdown"],
        ["research-agent", "--resume", "--boot", "none"]
    ])
    func resumeExclusivity(arguments: [String]) {
        #expect(throws: Error.self) {
            var command = try CreateCommand.parse(arguments)
            try command.validate()
        }
    }
}
