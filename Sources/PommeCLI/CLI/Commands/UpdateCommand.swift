import ArgumentParser

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update Pomme to the newest release.",
        discussion: """
        Pomme updates the way that it was installed. A Homebrew install runs \
        `brew upgrade weswhet/tap/pomme`. An install from the install script, the \
        installer package, or the release tarball runs the install script from \
        https://pommevm.dev/install.pl with Perl, which checks the SHA-256 digest and \
        Developer ID signature of the release before it replaces pomme. An installed \
        alpha updates to the newest alpha or release, and a release updates to the \
        newest release. A build from source cannot update itself; rebuild it with \
        Scripts/build-local.sh. To update the agent in a VM, use `pomme agent update`.
        """
    )

    @Flag(name: .customLong("check"), help: "Report whether an update is available without installing it.")
    var check = false

    @OptionGroup var output: GlobalOptions

    mutating func run() async throws {
        let format = try output.resolvedFormat()
        let result = try await PommeSelfUpdate.run(checkOnly: check, structuredOutput: format != .table)
        try CLIOutputWriter.write(result, options: output)
    }
}
