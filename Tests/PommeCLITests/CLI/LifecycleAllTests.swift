import ArgumentParser
import Foundation
import Testing

/// `-a/--all` selects VMs from the inventory instead of naming them. These
/// tests stay offline: they exercise the filter over list entries and the
/// parse-time conflict check, never the live inventory.
@Suite("Lifecycle --all")
struct LifecycleAllTests {
    private static var entries: [[String: Any]] {
        [
            ["name": "alpha", "vmState": "running"],
            ["name": "bravo", "vmState": "stopped"],
            ["name": "charlie", "vmState": "paused"],
            ["name": "delta", "vmState": "error"],
            ["name": "echo", "vmState": "running"]
        ]
    }

    /// The state sets that stop, pause, resume, and delete pass, in that order.
    private static let stateCases: [(states: Set<String>?, expected: [String])] = [
        (["running", "paused"], ["alpha", "charlie", "echo"]),
        (["running"], ["alpha", "echo"]),
        (["paused"], ["charlie"]),
        (nil, ["alpha", "bravo", "charlie", "delta", "echo"])
    ]

    @Test("Each command selects only the VMs it applies to, in list order", arguments: stateCases)
    func filtersByState(states: Set<String>?, expected: [String]) {
        #expect(VMTargetResolver.allNames(from: Self.entries, states: states) == expected)
    }

    @Test("No matching VMs is an empty selection")
    func emptySelection() {
        #expect(VMTargetResolver.allNames(from: [], states: ["running"]).isEmpty)
        #expect(VMTargetResolver.allNames(from: []).isEmpty)
        #expect(VMTargetResolver.allNames(from: Self.entries, states: ["starting"]).isEmpty)
    }

    @Test("-a and --all parse without VM names", arguments: [
        StopCommand.self as ParsableCommand.Type,
        PauseCommand.self,
        ResumeCommand.self,
        DeleteCommand.self
    ])
    func parsesAll(_ command: ParsableCommand.Type) throws {
        for flag in ["-a", "--all"] {
            let parsed = try command.parse([flag])
            switch parsed {
            case let stop as StopCommand: #expect(stop.all && stop.names.isEmpty)
            case let pause as PauseCommand: #expect(pause.all && pause.names.isEmpty)
            case let resume as ResumeCommand: #expect(resume.all && resume.names.isEmpty)
            case let delete as DeleteCommand: #expect(delete.all && delete.names.isEmpty)
            default: Issue.record("Unexpected command \(parsed).")
            }
        }
    }

    @Test("--all conflicts with VM names", arguments: [
        StopCommand.self as ParsableCommand.Type,
        PauseCommand.self,
        ResumeCommand.self,
        DeleteCommand.self
    ])
    func allConflictsWithNames(_ command: ParsableCommand.Type) {
        do {
            _ = try command.parse(["-a", "dev"])
            Issue.record("\(command._commandName) accepted --all with a VM name.")
        } catch {
            #expect(command.fullMessage(for: error).contains("--all conflicts with VM names."))
        }
    }

    @Test("Commands without --all still reject it", arguments: [
        StartCommand.self as ParsableCommand.Type,
        RestartCommand.self,
        StatusCommand.self,
        InspectCommand.self
    ])
    func otherCommandsHaveNoAll(_ command: ParsableCommand.Type) {
        #expect(throws: (any Error).self) {
            _ = try command.parse(["--all"])
        }
    }
}
