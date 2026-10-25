import ArgumentParser
import Darwin
import Foundation

/// Detects and repairs the boot firmware that some guest macOS updates
/// install. See `VMBootFirmware`.
struct FirmwareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "firmware",
        abstract: "Inspect and repair the boot firmware of a VM.",
        subcommands: [FirmwareInspectCommand.self, FirmwareRepairCommand.self]
    )
}

struct FirmwareInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show a VM's boot firmware and whether a guest update left the VM short of memory.",
        discussion: """
        Pomme reads the firmware from the auxiliary storage of the VM, so this works while the VM \
        is stopped. While the VM runs normal macOS with a connected Pomme agent, Pomme also asks \
        the guest for its macOS version and usable memory, and bases the diagnosis on them. The \
        diagnosis is `affected`, `likely-affected`, `not-affected`, or `unknown`.
        """
    )

    @Argument(help: "VM names. Uses POMME_VM_NAME when omitted.")
    var names: [String] = []

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let targets = try VMTargetResolver.names(from: names)
        let results = try CLIOutputWriter.batch(targets) { try PommeApplication.firmwareInspect(name: $0) }
        try CLIOutputWriter.write(results, options: output)
    }
}

struct FirmwareRepairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Restore the boot firmware that a VM was installed with.",
        discussion: """
        Use this when `pomme firmware inspect` reports `incompatible-update` for a VM that runs \
        macOS 26 or earlier: a guest update to macOS 26.7 or 15.8 installed the macOS 27 boot \
        firmware, which leaves the guest about 1.75 GB of memory. The VM must be stopped. Pomme \
        saves a copy of the `AuxiliaryStorage` file in the `FirmwareBackups` folder of the VM \
        bundle, then copies the firmware that the VM was installed with over the firmware that the \
        update installed. When the firmware needs no repair, Pomme changes nothing. Never use it on \
        a VM that you upgraded to macOS 27 in the guest.
        """
    )

    @Argument(help: "VM name. Uses POMME_VM_NAME when omitted.")
    var name: String?

    @Flag(name: [.customShort("f"), .customLong("force")], help: "Repair without prompting.")
    var force = false

    @OptionGroup var output: GlobalOptions

    mutating func run() throws {
        let target = try VMTargetResolver.names(from: name.map { [$0] } ?? [], allowMultiple: false)[0]
        let inspection = try PommeApplication.firmwareInspection(name: target)
        if inspection.repairable {
            try FirmwareConfirmation.confirmRepair(vm: target, inspection: inspection, force: force)
        }
        try CLIOutputWriter.write(try PommeApplication.firmwareRepair(name: target), options: output)
    }
}

private enum FirmwareConfirmation {
    static func confirmRepair(vm: String, inspection: VMBootFirmware.Inspection, force: Bool) throws {
        guard !force else { return }
        guard isatty(STDIN_FILENO) == 1 else {
            throw ValidationError("Repair requires an interactive terminal. Pass -f/--force to repair without prompting.")
        }
        let progress = PommeProgressContext.sink
        progress?.pause()
        defer { progress?.resume() }
        fputs(
            "Replace boot firmware \(inspection.active?.version ?? "") of VM '\(vm)' with \(inspection.fallback?.version ?? ""), the firmware it was installed with? Do this only if the VM runs macOS 26 or earlier. Pomme keeps a backup. [y/N] ",
            stderr
        )
        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              response == "y" || response == "yes"
        else {
            throw CleanExit.message("Repair cancelled.")
        }
    }
}
