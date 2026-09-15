import ArgumentParser
import Testing

@Suite("Bootstrap validation failures")
struct PommeBootstrapTests {
    @Test("Validation errors from run() carry the executing subcommand's usage", arguments: [
        (StatusCommand.self as ParsableCommand.Type, "pomme status"),
        (DeleteCommand.self as ParsableCommand.Type, "pomme delete"),
        (TUICommand.self as ParsableCommand.Type, "pomme tui"),
        (ConfigInitCommand.self as ParsableCommand.Type, "pomme config init")
    ])
    func validationFailureCarriesSubcommandUsage(command: ParsableCommand.Type, path: String) {
        let text = PommeBootstrap.validationFailureText(ValidationError("Specify a VM name or set POMME_VM_NAME."), command: command)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.first == "Error: Specify a VM name or set POMME_VM_NAME.")
        #expect(lines.dropFirst().first == "Usage: " + PommeCLI.usageString(for: command))
        #expect(lines.dropFirst().first?.hasPrefix("Usage: \(path)") == true)
        #expect(lines.last == "  See '\(path) --help' for more information.")
        #expect(lines.count == 3)
    }

    @Test("An empty validation message prints usage only")
    func emptyValidationMessagePrintsUsageOnly() {
        let text = PommeBootstrap.validationFailureText(ValidationError(""), command: StatusCommand.self)

        #expect(text.hasPrefix("Usage: pomme status"))
        #expect(!text.contains("Error:"))
    }

    @Test("Runner errors keep ArgumentParser's message-only rendering")
    func runnerErrorsPrintNoUsage() {
        let text = PommeCLI.fullMessage(for: RunnerError.hostCommandFailed("The VM is not running."))

        #expect(!text.contains("Usage:"))
    }
}
