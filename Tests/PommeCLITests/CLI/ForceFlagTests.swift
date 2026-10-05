import ArgumentParser
import Foundation
import Testing

@Suite("Force flag spelling")
struct ForceFlagTests {
    @Test("Every --force flag also accepts -f", arguments: [
        StopCommand.self as ParsableCommand.Type,
        DeleteCommand.self,
        SnapshotRestoreCommand.self,
        SnapshotDeleteCommand.self,
        TemplateDeleteCommand.self,
        SessionsTerminateCommand.self,
        ConfigInitCommand.self,
        SIPEnableCommand.self,
        SIPDisableCommand.self,
        AMFIEnableCommand.self,
        AMFIDisableCommand.self,
        MDMCommand.self
    ])
    func shortForce(_ command: ParsableCommand.Type) {
        #expect(command.helpMessage(columns: 400).contains("-f, --force"), "\(command._commandName)")
    }

    @Test("-f sets the same flag as --force")
    func shortForceParses() throws {
        #expect(try StopCommand.parse(["dev", "-f"]).force)
        #expect(try DeleteCommand.parse(["-af"]).force)
        #expect(try SessionsTerminateCommand.parse(["dev", "--session", "00000000-0000-0000-0000-000000000000", "-f"]).force)
        #expect(try SnapshotDeleteCommand.parse(["dev", "--snapshot", "clean", "-f"]).force)
    }
}
