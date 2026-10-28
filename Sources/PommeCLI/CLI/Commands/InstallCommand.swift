import ArgumentParser
import Foundation

/// Installs host software in a running VM. `--pkg` is the only source today;
/// another source, such as an app, would become a sibling option, and the
/// options would then be optional with an exactly-one check in `validate()`.
struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a host package in a running VM.",
        discussion: """
        Copies the package into a new folder in the guest, runs /usr/sbin/installer \
        as root with the startup volume as the target, and then removes the copy. \
        Pomme waits up to 1800 seconds (30 minutes) for the installer unless you pass \
        --timeout, at most 86400 seconds. If the wait ends first, the installer keeps \
        running in the guest and Pomme leaves the copy in place.
        """
    )

    @Argument(help: "VM name. Uses POMME_VM_NAME when omitted.")
    var name: String?

    @Option(name: .customLong("pkg"), help: ArgumentHelp("Host path of a flat installer package (.pkg) to install.", valueName: "path"))
    var package: String

    @OptionGroup var timeout: TimeoutOptions
    @OptionGroup var output: GlobalOptions

    mutating func validate() throws {
        _ = try PommeHostPackage.validated(path: package)
        _ = try installTimeout()
    }

    /// The wait for the installer: 30 minutes by default and at most a day.
    func installTimeout() throws -> TimeInterval {
        let value = try timeout.value(default: PommeGuestPackageInstall.defaultTimeout)
        guard value <= PommeGuestPackageInstall.maximumTimeout else {
            throw ValidationError(
                "--timeout must be at most \(Int(PommeGuestPackageInstall.maximumTimeout)) seconds for pomme install."
            )
        }
        return value
    }

    /// The target VM and the install that `run()` performs, resolved without
    /// any guest traffic so that tests can check them.
    func makeInstall(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (vm: String, install: PommeGuestPackageInstall) {
        let target = try VMTargetResolver.names(
            from: name.map { [$0] } ?? [], allowMultiple: false, environment: environment
        )[0]
        let install = PommeGuestPackageInstall(
            package: try PommeHostPackage.validated(path: package),
            timeout: try installTimeout()
        )
        return (target, install)
    }

    mutating func run() throws {
        try PommeRecoveryDebugContext.$screenshotsEnabled.withValue(output.debug) {
            let (target, install) = try makeInstall()
            try CLIOutputWriter.write(
                install.run(vmName: target, guest: PommeEnvironment.live().guest),
                options: output
            )
        }
    }
}
