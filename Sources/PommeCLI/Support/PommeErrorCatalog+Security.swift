import Foundation

// Codes and catalog entries for the "SIP and AMFI" area. See PommeErrorCatalog.swift.

extension PommeErrorCode {
    static let securityStatusUnverified: Self = "security-status-unverified"
    static let securityAgentUnverified: Self = "security-agent-unverified"
    static let securityAgentUnsupported: Self = "security-agent-unsupported"
    static let securityCommandIncomplete: Self = "security-command-incomplete"
    static let securityPrivateInputFailed: Self = "security-private-input-failed"
    static let securityOwnerNotFresh: Self = "security-owner-not-fresh"
    static let securityOwnerAccountConflict: Self = "security-owner-account-conflict"
    static let securityOwnerUnverified: Self = "security-owner-unverified"
    static let securityOwnerPreparationFailed: Self = "security-owner-preparation-failed"
    static let securityAutoLoginUnavailable: Self = "security-auto-login-unavailable"
    static let securityOwnerLoginUnverified: Self = "security-owner-login-unverified"
    static let securityDesktopUnverified: Self = "security-desktop-unverified"
    static let securityRebootUnverified: Self = "security-reboot-unverified"
    static let securityChangeUnverified: Self = "security-change-unverified"
    static let securityRecoveryCommandFailed: Self = "security-recovery-command-failed"
    static let securityRollbackUnverified: Self = "security-rollback-unverified"
    static let securityRestorationIncomplete: Self = "security-restoration-incomplete"
    static let securityOperationPending: Self = "security-operation-pending"
    static let securityRequestMismatch: Self = "security-request-mismatch"
    static let securityJournalDamaged: Self = "security-journal-damaged"
    static let securityJournalWriteFailed: Self = "security-journal-write-failed"
    static let securityCredentialInvalid: Self = "security-credential-invalid"
    static let securityCredentialConflict: Self = "security-credential-conflict"
    static let securityStateDamaged: Self = "security-state-damaged"
    static let securityStateStale: Self = "security-state-stale"
    static let securityStateConflict: Self = "security-state-conflict"
    static let securityStateWriteFailed: Self = "security-state-write-failed"
    static let amfiRequiresSIPDisabled: Self = "amfi-requires-sip-disabled"
    static let amfiBaselineMissing: Self = "amfi-baseline-missing"
}

extension PommeErrorCatalog {
    private static let securityArea = "SIP and AMFI"
    private static let securityGuide = "See [Change SIP and AMFI](/guides/change-sip-and-amfi/)."
    private static let securityResumeStep = "Repeat the same `pomme sip` or `pomme amfi` action with the same `--final-state` value to resume. See [Change SIP and AMFI](/guides/change-sip-and-amfi/#resume-an-interrupted-change)."
    private static let securityStatusStep = "Run `pomme sip status NAME` and `pomme amfi status NAME` to see the VM's security state."
    private static let securityBugStep = "If it happens again, run `pomme bug-report NAME` and attach the file to a new issue."

    static let security: [Entry] = [
        .init(.securityStatusUnverified, area: securityArea,
              title: "Pomme couldn't verify the VM's security state.",
              cause: "Pomme reads the SIP and AMFI state from the guest and accepts only a reply that it can parse exactly. The reply was missing, incomplete, or in an unexpected format.",
              resolution: [securityStatusStep, "Run `pomme agent status NAME` to check that the guest agent is connected."]),
        .init(.securityAgentUnverified, area: securityArea,
              title: "Pomme couldn't authenticate the guest agent.",
              cause: "SIP and AMFI changes use the guest agent that Pomme installed when it created the VM. The agent didn't answer, or it didn't prove the identity that Pomme recorded for it.",
              resolution: ["Run `pomme agent status NAME` to check the agent.", "Run `pomme agent repair NAME` if the agent is missing or damaged, then retry."]),
        .init(.securityAgentUnsupported, area: securityArea,
              title: "The VM's guest agent doesn't support this workflow.",
              cause: "The Pomme agent in the VM is older than this `pomme` and lacks a capability that the SIP or AMFI workflow needs. Pomme doesn't replace the agent during the workflow.",
              resolution: ["Run `pomme agent update NAME` to install the current agent, then retry.", "If the update isn't possible, create a new VM with this version of Pomme."]),
        .init(.securityCommandIncomplete, area: securityArea,
              title: "A guest command didn't finish cleanly.",
              cause: "A command that Pomme ran in the guest during the security workflow timed out, was cancelled, or returned incomplete output. Pomme keeps its progress.",
              resolution: [securityResumeStep]),
        .init(.securityPrivateInputFailed, area: securityArea,
              title: "Pomme couldn't pass the owner's credential to a guest command.",
              cause: "Some guest commands read the owner's credential from a private terminal. The command didn't show the expected prompt, echoed its input, or exited early, so Pomme stopped without retrying the credential.",
              resolution: [securityResumeStep, securityBugStep]),
        .init(.securityOwnerNotFresh, area: securityArea,
              title: "Pomme can't create an owner account on this VM.",
              cause: "Pomme creates the guest owner only on a VM that it created and that it can prove has no other user accounts or earlier provisioning. This VM didn't pass that check.",
              resolution: ["Provide the existing owner's credentials. See [Change SIP and AMFI](/guides/change-sip-and-amfi/#vms-with-an-existing-owner)."]),
        .init(.securityOwnerAccountConflict, area: securityArea,
              title: "An account with the owner's name already exists.",
              cause: "The guest already has an account with the name that Pomme uses for the owner, and Pomme can't prove that it's the account it created earlier.",
              resolution: ["Provide that account's credentials, or remove the account in the guest. See [Change SIP and AMFI](/guides/change-sip-and-amfi/#vms-with-an-existing-owner)."]),
        .init(.securityOwnerUnverified, area: securityArea,
              title: "Pomme couldn't verify the owner account.",
              cause: "The guest didn't accept the owner's credentials, or the account isn't an administrator that owns the startup volume.",
              resolution: ["Check the user name and credential that you provided.", securityGuide]),
        .init(.securityOwnerPreparationFailed, area: securityArea,
              title: "Pomme couldn't prepare the owner account.",
              cause: "A step that creates, checks, or signs in the guest owner failed or returned evidence that Pomme couldn't verify. Pomme keeps the account and its progress.",
              resolution: [securityResumeStep, securityBugStep]),
        .init(.securityAutoLoginUnavailable, area: securityArea,
              title: "macOS refused automatic login for the owner.",
              cause: "The workflow signs in the owner automatically so that it can verify changes after a restart. macOS refused, for example because FileVault, Touch ID, Apple Pay, App Store purchase protection, or a management policy is on.",
              resolution: ["Turn off the setting that the message names in the guest, then repeat the same command.", securityGuide]),
        .init(.securityOwnerLoginUnverified, area: securityArea,
              title: "Pomme couldn't confirm that the owner signed in.",
              cause: "After a normal restart, the guest didn't show the owner's desktop within the time limit. Pomme keeps the account, its credential, and the workflow's progress.",
              resolution: [securityResumeStep]),
        .init(.securityDesktopUnverified, area: securityArea,
              title: "Pomme couldn't confirm that the guest desktop is ready.",
              cause: "Pomme waits for the owner's desktop session before it continues. The guest agent didn't report a ready desktop. The message names the step that failed.",
              resolution: [securityResumeStep]),
        .init(.securityRebootUnverified, area: securityArea,
              title: "Pomme couldn't verify the guest restart.",
              cause: "To apply a change, Pomme restarts the guest and checks that it booted again with a new boot session. The restart request, the stop, the start, or the check afterward failed. Pomme keeps the workflow's progress.",
              resolution: ["Run `pomme status NAME` to see the VM's state.", securityResumeStep]),
        .init(.securityChangeUnverified, area: securityArea,
              title: "Pomme couldn't verify the security change.",
              cause: "After Pomme changed SIP or AMFI, it read the setting again and couldn't confirm the requested value. Pomme keeps the workflow's progress so that the next attempt can inspect it.",
              resolution: [securityStatusStep, securityResumeStep]),
        .init(.securityRecoveryCommandFailed, area: securityArea,
              title: "A security command in Recovery failed.",
              cause: "The Pomme agent in macOS Recovery ran `csrutil`, `bputil`, or `nvram`, and the command failed, timed out, or showed an unexpected prompt. Pomme keeps the workflow's progress so that the next attempt can inspect it.",
              resolution: [securityStatusStep, securityResumeStep]),
        .init(.securityRollbackUnverified, area: securityArea,
              title: "Pomme couldn't verify the rollback of a security change.",
              cause: "A security change failed, and Pomme couldn't confirm that it restored the recorded boot policy and NVRAM values. Pomme keeps the workflow's progress.",
              resolution: [securityStatusStep, securityResumeStep, securityBugStep],
              reportable: true),
        .init(.securityRestorationIncomplete, area: securityArea,
              title: "Pomme couldn't restore the VM's run state.",
              cause: "After the security workflow, Pomme couldn't prove that cleanup finished or that the VM returned to the requested final state. Pomme keeps the owner account, its credential, and the workflow's progress.",
              resolution: ["Run `pomme status NAME` to see the VM's state.", securityResumeStep],
              hint: "Run `pomme status NAME`, then repeat the same command."),
        .init(.securityOperationPending, area: securityArea,
              title: "Another security operation is unfinished.",
              cause: "An earlier SIP or AMFI operation on this VM didn't finish, and Pomme doesn't start a different one until it does.",
              resolution: ["Repeat the earlier operation's command with the same `--final-state` value to finish it. See [Change SIP and AMFI](/guides/change-sip-and-amfi/#resume-an-interrupted-change)."]),
        .init(.securityRequestMismatch, area: securityArea,
              title: "The command doesn't match the unfinished security operation.",
              cause: "The VM has an unfinished SIP or AMFI operation, and the command asks for a different action or final state. Pomme can't change a retained operation.",
              resolution: ["Repeat the original command exactly, with the same action and `--final-state` value. See [Change SIP and AMFI](/guides/change-sip-and-amfi/#resume-an-interrupted-change)."]),
        .init(.securityJournalDamaged, area: securityArea,
              title: "The security workflow journal can't be used.",
              cause: "Pomme records each SIP and AMFI step in a journal in the VM bundle. The journal is missing, too large, has unsafe permissions, belongs to another VM, or is damaged.",
              resolution: ["Check that the VM bundle's files are owned by your account and aren't writable by others.", "Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.securityJournalWriteFailed, area: securityArea,
              title: "Pomme couldn't save the security workflow journal.",
              cause: "Pomme writes and synchronizes the journal before each step so that it can resume after an interruption. Writing or synchronizing the file failed.",
              resolution: ["Check that the volume that holds the VM has free space and is writable.", securityResumeStep]),
        .init(.securityCredentialInvalid, area: securityArea,
              title: "The stored owner credential can't be used.",
              cause: "Pomme keeps the guest owner's credential in your login Keychain. The item, or the reference to it in the journal, isn't in the format that Pomme writes.",
              resolution: ["Provide the owner's credentials another way. See [Change SIP and AMFI](/guides/change-sip-and-amfi/#vms-with-an-existing-owner)."]),
        .init(.securityCredentialConflict, area: securityArea,
              title: "The owner credential's Keychain item belongs to something else.",
              cause: "The Keychain item that Pomme uses for this VM's owner already exists and belongs to another VM or wasn't created by Pomme. Pomme doesn't overwrite it.",
              resolution: ["Open Keychain Access, find the item that names the VM's UUID, and remove it if you no longer need it."]),
        .init(.securityStateDamaged, area: securityArea,
              title: "The VM's security state file can't be used.",
              cause: "The security state file in the VM bundle is damaged, uses an unsupported format, isn't private to your account, or belongs to another VM.",
              resolution: ["Check that the VM bundle's files are owned by your account and aren't writable by others.", "Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.securityStateStale, area: securityArea,
              title: "The VM's security state is too old to resume.",
              cause: "Pomme resumes a security restoration only within 24 hours of the state that it recorded.",
              resolution: [securityStatusStep, "Run the SIP or AMFI command again to start a new operation."]),
        .init(.securityStateConflict, area: securityArea,
              title: "The VM's security state doesn't allow this step.",
              cause: "The security state file records a step that conflicts with the requested one, for example because a restoration isn't verified yet. This is a bug in Pomme.",
              resolution: [securityStatusStep, "Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.securityStateWriteFailed, area: securityArea,
              title: "Pomme couldn't save the VM's security state.",
              cause: "Writing or removing the security state file in the VM bundle failed. The causes give the reason.",
              resolution: ["Check that the volume that holds the VM has free space and is writable, then retry."]),
        .init(.amfiRequiresSIPDisabled, area: securityArea,
              title: "Changing AMFI requires SIP to be off.",
              cause: "Pomme writes and verifies AMFI boot arguments only while SIP is off.",
              resolution: ["Run `pomme sip disable NAME` first.", "Restore AMFI with `pomme amfi enable NAME` before you turn SIP on again.", securityGuide],
              hint: "Run `pomme sip disable NAME` first."),
        .init(.amfiBaselineMissing, area: securityArea,
              title: "Pomme has no recorded AMFI baseline to restore.",
              cause: "`pomme amfi enable` restores the exact boot policy and boot arguments that Pomme recorded before it turned off AMFI. No recording exists for this VM, and Pomme doesn't guess one.",
              resolution: [securityStatusStep, securityGuide])
    ]
}
