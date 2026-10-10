import Foundation

// Codes and catalog entries for the "Recovery" area. See PommeErrorCatalog.swift.

extension PommeErrorCode {
    static let recoveryRequestRejected: Self = "recovery-request-rejected"
    static let recoveryAuthenticationFailed: Self = "recovery-authentication-failed"
    static let recoveryTimedOut: Self = "recovery-timed-out"
    static let recoveryLauncherRejected: Self = "recovery-launcher-rejected"
    static let recoveryStagingUnsafe: Self = "recovery-staging-unsafe"
    static let recoveryWorkspaceUnverified: Self = "recovery-workspace-unverified"
    static let recoverySessionInvalid: Self = "recovery-session-invalid"
    static let recoveryOperationFailed: Self = "recovery-operation-failed"
    static let recoveryAgentFailed: Self = "recovery-agent-failed"
    static let recoveryCleanupUnverified: Self = "recovery-cleanup-unverified"
    static let recoveryRunStateUnavailable: Self = "recovery-run-state-unavailable"
    static let recoveryFinalStateUnverified: Self = "recovery-final-state-unverified"
    static let recoverySecurityStateRejected: Self = "recovery-security-state-rejected"
}

extension PommeErrorCatalog {
    private static let recoveryArea = "Recovery"
    private static let recoveryStatusStep = "Run `pomme status NAME` to see the VM's state."
    private static let recoveryRetryStep = "Run the same command again. Each attempt starts a new Recovery session."

    static let recovery: [Entry] = [
        .init(.recoveryRequestRejected, area: recoveryArea,
              title: "Pomme rejected its own Recovery request.",
              cause: "Before Pomme starts macOS Recovery, it binds the request to one VM, one executable, and one operation. A value in that binding was missing, out of range, or didn't match the VM. This is a bug in Pomme.",
              resolution: [recoveryRetryStep, "If it happens again, run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.recoveryAuthenticationFailed, area: recoveryArea,
              title: "The Recovery agent didn't authenticate.",
              cause: "The Pomme agent that runs in macOS Recovery proves its identity with a one-time credential that expires after a few minutes. The credential expired, was already used, or didn't match.",
              resolution: [recoveryRetryStep, "If the VM is slow to reach Recovery, stop other VMs to free memory and CPU, then retry."],
              hint: "Run the same command again to start a new Recovery session."),
        .init(.recoveryTimedOut, area: recoveryArea,
              title: "A Recovery step didn't finish in time.",
              cause: "macOS Recovery didn't reach the expected screen, the Recovery agent didn't connect, or a Recovery command didn't finish within its time limit.",
              resolution: [recoveryStatusStep, "Stop the VM with `pomme stop NAME`, then run the same command again.", "Stop other VMs to free memory and CPU if the VM is slow."]),
        .init(.recoveryLauncherRejected, area: recoveryArea,
              title: "Pomme couldn't verify the agent it copies into Recovery.",
              cause: "Pomme copies its own signed executable into macOS Recovery. The code signature, digest, or file identity of that copy didn't match the running `pomme`, or it changed while Pomme read it.",
              resolution: ["Reinstall Pomme with `pomme update`, then run the command again.", "If you built Pomme yourself, sign it with the same identity as the installed build."]),
        .init(.recoveryStagingUnsafe, area: recoveryArea,
              title: "The Recovery staging directory isn't private.",
              cause: "Pomme stages files for macOS Recovery in a directory that only your account can write. The directory, or a file in it, has other permissions, another owner, or an unexpected file.",
              resolution: ["Check the ownership and permissions of the VM bundle with `ls -la`.", "Run Pomme as the user who created the VM, not with `sudo`."]),
        .init(.recoveryWorkspaceUnverified, area: recoveryArea,
              title: "Pomme couldn't verify the Recovery workspace.",
              cause: "The Recovery agent reported a workspace, disk attachment, or volume that doesn't match what Pomme prepared, so Pomme stopped before it changed anything.",
              resolution: ["Stop the VM with `pomme stop NAME`, then run the same command again.", "If it happens again, run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.recoverySessionInvalid, area: recoveryArea,
              title: "The Recovery session reached an unexpected state.",
              cause: "A Recovery session runs its steps in a fixed order and is used once. A step ran out of order, the session was reused, or its directory share was already attached. This is a bug in Pomme.",
              resolution: ["Stop the VM with `pomme stop NAME`, then run the same command again.", "Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.recoveryOperationFailed, area: recoveryArea,
              title: "The Recovery operation didn't finish.",
              cause: "The Pomme agent in macOS Recovery didn't complete the requested operation. The causes give the reason when one is known.",
              resolution: [recoveryStatusStep, recoveryRetryStep, "If it happens again, run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.recoveryAgentFailed, area: recoveryArea,
              title: "Pomme couldn't start its agent in Recovery.",
              cause: "Pomme starts a Pomme agent in macOS Recovery through Recovery's Terminal. The agent didn't start, didn't authenticate, or stopped responding.",
              resolution: [recoveryStatusStep, "Stop the VM with `pomme stop NAME`, then run the same command again.", "Run the command with `--debug` to save screenshots of each Recovery step."]),
        .init(.recoveryCleanupUnverified, area: recoveryArea,
              title: "Pomme couldn't confirm that Recovery cleanup finished.",
              cause: "After a Recovery operation, Pomme removes the files and directory share that it staged and detaches any disk image. It couldn't confirm that every item was removed, so it didn't change the VM's final state.",
              resolution: [recoveryStatusStep, "Stop the VM with `pomme stop NAME`, then run the same command again; Pomme cleans up the earlier session first."],
              hint: "Run `pomme stop NAME`, then run the same command again."),
        .init(.recoveryRunStateUnavailable, area: recoveryArea,
              title: "Pomme couldn't read the VM's run state.",
              cause: "Before Pomme starts Recovery, it records whether the VM is running, paused, or stopped so that it can restore that state. It couldn't read the state.",
              resolution: [recoveryStatusStep, "Run the command again after the VM finishes starting or stopping."]),
        .init(.recoveryFinalStateUnverified, area: recoveryArea,
              title: "Pomme couldn't confirm the VM's final state.",
              cause: "After the Recovery operation, Pomme asked the VM to reach the requested final state, such as stopped or running normally, and couldn't confirm that it did.",
              resolution: [recoveryStatusStep, "Start or stop the VM yourself with `pomme start NAME` or `pomme stop NAME`."],
              hint: "Run `pomme status NAME` to see the VM's state."),
        .init(.recoverySecurityStateRejected, area: recoveryArea,
              title: "Recovery reported a security state that Pomme can't use.",
              cause: "The boot policy, NVRAM values, or recorded security baseline that the Recovery agent read or was asked to write didn't pass validation, so Pomme didn't change it.",
              resolution: ["Run `pomme sip status NAME` and `pomme amfi status NAME` to see the VM's security state.", "Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true)
    ]
}
