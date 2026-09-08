import Testing

@Suite("Direct local restore-image command contract")
struct DirectLocalRestoreImageCommandTests {
    @Test("A local restore image is accepted for direct creation planning")
    func acceptsLocalRestoreImage() throws {
        let command = try CreateCommand.parse([
            "research-agent",
            "--restore-image", "/tmp/Restore.ipsw",
            "--dry-run"
        ])

        #expect(command.restoreImage == "/tmp/Restore.ipsw")
        #expect(command.dryRun)
    }

    @Test("A local restore image has a non-empty path", arguments: ["", "   ", "\n\t"])
    func rejectsEmptyLocalRestoreImage(path: String) throws {
        #expect(throws: Error.self) {
            _ = try CreateCommand.parse([
                "research-agent",
                "--restore-image", path
            ])
        }
    }

    @Test("IPSW device selection is unambiguous")
    func rejectsIPSWDeviceWithLocalRestoreImage() throws {
        #expect(throws: Error.self) {
            _ = try CreateCommand.parse([
                "research-agent",
                "--restore-image", "/tmp/Restore.ipsw",
                "--ipsw-device", "VirtualMac2,1"
            ])
        }
    }
}
