import Foundation

// Codes and catalog entries for the "Operations" area. See PommeErrorCatalog.swift.

extension PommeErrorCode {
    static let vmMutationInProgress: Self = "vm-mutation-in-progress"
    static let vmLockUnsafe: Self = "vm-lock-unsafe"
    static let vmLockInvalid: Self = "vm-lock-invalid"
    static let snapshotRestoreFailed: Self = "snapshot-restore-failed"
    static let snapshotRestoreTimedOut: Self = "snapshot-restore-timed-out"
    static let executableIdentityRejected: Self = "executable-identity-rejected"
    static let agentUpdateUnprovisioned: Self = "agent-update-unprovisioned"
    static let agentUpdateBlocked: Self = "agent-update-blocked"
    static let agentUpdateActiveWork: Self = "agent-update-active-work"
    static let agentUpdateUnsupported: Self = "agent-update-unsupported"
    static let agentUpdateTransferMismatch: Self = "agent-update-transfer-mismatch"
    static let agentUpdateApplyFailed: Self = "agent-update-apply-failed"
    static let agentUpdateActivationTimedOut: Self = "agent-update-activation-timed-out"
    static let agentBindingInvalid: Self = "agent-binding-invalid"
    static let agentBindingMissing: Self = "agent-binding-missing"
    static let agentSessionReplaced: Self = "agent-session-replaced"
    static let agentCredentialMissing: Self = "agent-credential-missing"
    static let agentCredentialInvalid: Self = "agent-credential-invalid"
    static let agentArtifactStoreUnavailable: Self = "agent-artifact-store-unavailable"
    static let agentArtifactMissing: Self = "agent-artifact-missing"
    static let agentArtifactRejected: Self = "agent-artifact-rejected"
    static let agentArtifactSignatureRejected: Self = "agent-artifact-signature-rejected"
    static let agentArtifactWriteFailed: Self = "agent-artifact-write-failed"
    static let updateSourceBuild: Self = "update-source-build"
    static let updateUnknownVersion: Self = "update-unknown-version"
    static let updateNoRelease: Self = "update-no-release"
    static let updateLookupFailed: Self = "update-lookup-failed"
    static let updateFailed: Self = "update-failed"
    static let updateVersionMismatch: Self = "update-version-mismatch"
}

extension PommeErrorCatalog {
    static let operations: [Entry] = [
        .init(.vmMutationInProgress, area: "Operations",
              title: "Another Pomme command is changing the VM.",
              cause: "Pomme lets one command at a time create, start, stop, restore, update, or delete a VM.",
              resolution: ["Wait for the other command to finish, then retry."],
              hint: "Wait for the other command to finish, then retry."),
        .init(.vmLockUnsafe, area: "Operations",
              title: "Pomme couldn't open the VM's lock file safely.",
              cause: "Pomme keeps a lock file for each VM so that two commands don't change it at once. The file isn't a regular file, or it has the wrong owner or permissions.",
              resolution: ["Run Pomme as the user who created the VM, not with `sudo`, then retry."]),
        .init(.vmLockInvalid, area: "Operations",
              title: "Pomme's VM lock isn't valid.",
              cause: "The lock that a command holds for a VM was released early, belongs to another VM, or couldn't be passed to the VM helper. This is a bug in Pomme.",
              resolution: ["Retry the command.", "Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.snapshotRestoreFailed, area: "Operations",
              title: "Restoring the snapshot failed.",
              cause: "The VM helper exited before it restored the snapshot and paused the VM.",
              resolution: [
                  "Run `pomme stop NAME`, then run `pomme snapshot restore NAME --snapshot SNAPSHOT` again.",
                  "Run `pomme bug-report NAME` to collect the helper log if it fails again."
              ]),
        .init(.snapshotRestoreTimedOut, area: "Operations",
              title: "Restoring the snapshot timed out.",
              cause: "The VM helper didn't restore the snapshot and pause the VM in time.",
              resolution: ["Run `pomme stop NAME`, then run `pomme snapshot restore NAME --snapshot SNAPSHOT` again."]),
        .init(.executableIdentityRejected, area: "Operations",
              title: "Pomme couldn't verify its own executable.",
              cause: "Pomme reads and digests its own executable so that it can pin the exact agent that it installs in a VM. The file is missing, isn't a regular file, or couldn't be read.",
              resolution: ["Make sure that the `pomme` executable exists and is readable.", "Reinstall Pomme with `pomme update`, then retry."]),
        .init(.agentUpdateUnprovisioned, area: "Operations",
              title: "The VM has no Pomme agent to update.",
              cause: "`pomme agent update` updates only an agent that Pomme installed when it created the VM.",
              resolution: ["Run `pomme agent status NAME` to see the VM's agent workflow."]),
        .init(.agentUpdateBlocked, area: "Operations",
              title: "A retained workflow blocks the agent update.",
              cause: "A SIP, AMFI, or MDM enrollment operation on the VM hasn't finished, and it depends on the current agent.",
              resolution: ["Finish or repeat the retained operation, then run `pomme agent update NAME` again."]),
        .init(.agentUpdateActiveWork, area: "Operations",
              title: "Background jobs or terminal sessions block the agent update.",
              cause: "Restarting the agent would leave running jobs and terminal sessions without a manager.",
              resolution: [
                  "Let the jobs and sessions finish, or stop them with `pomme jobs kill NAME --job ID` and `pomme sessions terminate NAME --session ID`.",
                  "Run `pomme agent update NAME` again."
              ]),
        .init(.agentUpdateUnsupported, area: "Operations",
              title: "The VM's agent can't be updated in place.",
              cause: "The agent in the VM is too old to receive files or run processes.",
              resolution: ["Run `pomme agent repair NAME` to reinstall the agent from Recovery."]),
        .init(.agentUpdateTransferMismatch, area: "Operations",
              title: "The copied agent doesn't match this host's Pomme.",
              cause: "After Pomme copied its executable into the guest, the copy's digest didn't match the original.",
              resolution: ["Run `pomme agent update NAME` again.", "If it fails again, run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.agentUpdateApplyFailed, area: "Operations",
              title: "The guest couldn't install the new agent.",
              cause: "The guest couldn't make the new agent executable or install it. The previous agent is still installed.",
              resolution: ["Run `pomme agent update NAME` again.", "If it fails again, run `pomme agent repair NAME` to reinstall the agent that the VM was created with."]),
        .init(.agentUpdateActivationTimedOut, area: "Operations",
              title: "The updated agent didn't connect in time.",
              cause: "The new agent is installed, but the running agent didn't restart with it in time. It takes effect when the VM restarts.",
              resolution: ["Run `pomme restart NAME`, then run `pomme agent update NAME` again to record the update."]),
        .init(.agentBindingInvalid, area: "Operations",
              title: "Pomme refused a guest agent connection.",
              cause: "A guest agent connected with a role or session that doesn't match the operation in progress. This is a bug in Pomme or a sign that the guest isn't the expected one.",
              resolution: ["Retry the command.", "If it fails again, run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.agentBindingMissing, area: "Operations",
              title: "No session is ready for the guest agent's connection.",
              cause: "A guest agent connected for a Recovery operation before Pomme prepared its session, or after the session ended.",
              resolution: ["Retry the command."]),
        .init(.agentSessionReplaced, area: "Operations",
              title: "A newer guest agent connection replaced this one.",
              cause: "The guest agent reconnected, for example after it restarted, while an operation used the previous connection.",
              resolution: ["Retry the command."],
              hint: "Retry the command."),
        .init(.agentCredentialMissing, area: "Operations",
              title: "The VM's agent credential isn't in the Keychain.",
              cause: "Pomme authenticates to the VM's agent with a credential in your login Keychain, and the item is missing.",
              resolution: ["Make sure that you're signed in as the user who created the VM.", "Run `pomme agent repair NAME` to reinstall the agent and its credential."]),
        .init(.agentCredentialInvalid, area: "Operations",
              title: "The VM's agent credential isn't valid.",
              cause: "The VM's agent credential in your login Keychain has an invalid format or type.",
              resolution: ["Run `pomme agent repair NAME` to reinstall the agent and its credential."]),
        .init(.agentArtifactStoreUnavailable, area: "Operations",
              title: "The agent artifact store isn't available.",
              cause: "Pomme keeps a copy of each agent that it installs in `~/Library/Application Support/pomme/AgentArtifacts`. The directory is missing, isn't yours, or is writable by other users.",
              resolution: ["Make sure that the directory and its parent directories belong to you and aren't writable by other users, then retry."]),
        .init(.agentArtifactMissing, area: "Operations",
              title: "The VM's pinned agent isn't on this Mac.",
              cause: "A Recovery repair or resumed creation installs exactly the agent that the VM was created with. Pomme keeps a copy when it creates a VM, and that copy is missing.",
              resolution: ["Reinstall the Pomme build that created the VM, then retry."]),
        .init(.agentArtifactRejected, area: "Operations",
              title: "The pinned agent copy isn't valid.",
              cause: "The retained agent isn't a private regular file, changed while Pomme read it, or doesn't match the digest that the VM pins.",
              resolution: ["Reinstall the Pomme build that created the VM, then retry.", "If it fails again, run `pomme bug-report NAME` and attach the file to a new issue."]),
        .init(.agentArtifactSignatureRejected, area: "Operations",
              title: "The agent's code signature isn't trusted.",
              cause: "Pomme installs only an agent that has Pomme's Developer ID signature. The executable doesn't have it, or the signature isn't valid.",
              resolution: ["Install a signed Pomme release with `pomme update` or from https://pommevm.dev, then retry."]),
        .init(.agentArtifactWriteFailed, area: "Operations",
              title: "Pomme couldn't save a copy of its agent.",
              cause: "Pomme couldn't write the copy of its executable that it keeps for later agent repairs. The message gives the reason.",
              resolution: ["Read the reason in the message and correct it, then retry."]),
        .init(.updateSourceBuild, area: "Operations",
              title: "A build from source can't update itself.",
              cause: "`pomme update` updates only an install from Homebrew, the install script, the installer package, or the release tarball.",
              resolution: ["Pull the newest source and run `bash Scripts/build-local.sh`."]),
        .init(.updateUnknownVersion, area: "Operations",
              title: "This Pomme's version isn't a release version.",
              cause: "`pomme update` compares release versions, and this executable reports a version that isn't one.",
              resolution: ["Install a Pomme release from https://pommevm.dev."]),
        .init(.updateNoRelease, area: "Operations",
              title: "No Pomme release is published for this install.",
              cause: "The release feed for the channel that this installation follows doesn't list a release yet.",
              resolution: ["Retry later, or install the newest alpha as the message describes."]),
        .init(.updateLookupFailed, area: "Operations",
              title: "Pomme couldn't find the newest release.",
              cause: "The request to the release feed failed, or its reply couldn't be read.",
              resolution: ["Check the network connection, then run `pomme update` again."],
              hint: "Check the network connection, then run `pomme update` again."),
        .init(.updateFailed, area: "Operations",
              title: "The update command failed.",
              cause: "The command that installs the update, such as `brew upgrade` or the install script, exited with an error.",
              resolution: ["Read the command's output for the reason, correct it, then run `pomme update` again."]),
        .init(.updateVersionMismatch, area: "Operations",
              title: "The installed version isn't the expected one.",
              cause: "The update command succeeded, but the installed `pomme` reports a different version than the release that it installed.",
              resolution: ["Run `pomme --version` to check the version.", "Check that `command -v pomme` resolves to the installed path, then run `pomme update` again."])
    ]
}
