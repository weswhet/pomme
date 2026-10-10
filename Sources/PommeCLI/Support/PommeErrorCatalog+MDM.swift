import Foundation

// Codes and catalog entries for the "MDM" area. See PommeErrorCatalog.swift.

extension PommeErrorCode {
    static let mdmProfileUnreadable: Self = "mdm-profile-unreadable"
    static let mdmProfileTransferFailed: Self = "mdm-profile-transfer-failed"
    static let mdmAgentUnverified: Self = "mdm-agent-unverified"
    static let mdmSecurityBaselineUnavailable: Self = "mdm-security-baseline-unavailable"
    static let mdmSecurityBaselineUnsupported: Self = "mdm-security-baseline-unsupported"
    static let mdmStagingFailed: Self = "mdm-staging-failed"
    static let mdmEnrollmentFailed: Self = "mdm-enrollment-failed"
    static let mdmEnrollmentOutcomeUnknown: Self = "mdm-enrollment-outcome-unknown"
    static let mdmEvidenceUnavailable: Self = "mdm-evidence-unavailable"
    static let mdmEnrollmentConflict: Self = "mdm-enrollment-conflict"
    static let mdmDowngradeUnsupported: Self = "mdm-downgrade-unsupported"
    static let mdmHelperNotStopped: Self = "mdm-helper-not-stopped"
    static let mdmCleanupFailed: Self = "mdm-cleanup-failed"
    static let mdmRestorationFailed: Self = "mdm-restoration-failed"
    static let mdmOperationPending: Self = "mdm-operation-pending"
    static let mdmPreparationIncomplete: Self = "mdm-preparation-incomplete"
    static let mdmJournalConflict: Self = "mdm-journal-conflict"
    static let mdmJournalDamaged: Self = "mdm-journal-damaged"
    static let mdmJournalChanged: Self = "mdm-journal-changed"
    static let mdmJournalStateInvalid: Self = "mdm-journal-state-invalid"
    static let mdmJournalWriteFailed: Self = "mdm-journal-write-failed"
}

extension PommeErrorCatalog {
    static let mdm: [Entry] = [
        .init(.mdmProfileUnreadable, area: "MDM",
              title: "Pomme couldn't read the MDM enrollment profile.",
              cause: "The `--profile` path doesn't exist, isn't a regular file, is a symbolic link, has more than one hard link, or isn't readable. Pomme reads only a single, regular `.mobileconfig` file.",
              resolution: ["Check that `--profile` names a regular `.mobileconfig` file that you can read.", "If the profile is a link, give the path of the file that it points to."]),
        .init(.mdmProfileTransferFailed, area: "MDM",
              title: "Pomme couldn't copy the MDM profile to the VM.",
              cause: "The copy to the guest's private staging directory failed, or the copy's size or digest didn't match the profile on the host.",
              resolution: ["Run `pomme status NAME` to check that the VM and its guest agent are running.", "Retry `pomme mdm` with the same arguments."]),
        .init(.mdmAgentUnverified, area: "MDM",
              title: "Pomme couldn't verify the guest agent for MDM enrollment.",
              cause: "MDM enrollment runs only through an authenticated, attested PommeAgent that uses protocol version 1, has the enrollment and maintenance capabilities, and matches the signed executable that Pomme recorded for the VM.",
              resolution: ["Run `pomme agent status NAME` to check the agent.", "If the agent is out of date, run `pomme agent update NAME`, then retry `pomme mdm`.", "If the agent still lacks the MDM capabilities, recreate the VM with a current Pomme build. See [Enroll in MDM](/guides/enroll-in-mdm/)."]),
        .init(.mdmSecurityBaselineUnavailable, area: "MDM",
              title: "Pomme couldn't read the VM's security settings before MDM enrollment.",
              cause: "Before it enrolls, Pomme records the VM's System Integrity Protection (SIP) and Apple Mobile File Integrity (AMFI) settings and its run state so that it can restore them. The guest didn't report them in the expected form, or SIP and AMFI weren't turned off as the enrollment helper requires.",
              resolution: ["Run `pomme sip status NAME` and `pomme amfi status NAME` to check the settings.", "Retry `pomme mdm` with the same arguments."]),
        .init(.mdmSecurityBaselineUnsupported, area: "MDM",
              title: "Pomme can't restore the VM's original security settings exactly.",
              cause: "The VM's SIP or AMFI configuration is one that Pomme can't reproduce after enrollment, so Pomme stopped before it changed any security setting.",
              resolution: ["Run `pomme sip status NAME` and `pomme amfi status NAME` to see the current settings.", "Set SIP and AMFI to a standard configuration with `pomme sip` and `pomme amfi`, then retry `pomme mdm`. See [Change SIP and AMFI](/guides/change-sip-and-amfi/)."]),
        .init(.mdmStagingFailed, area: "MDM",
              title: "Pomme couldn't prepare MDM staging in the VM.",
              cause: "The guest agent couldn't create or verify the private, root-owned directory that holds the profile and the enrollment helper.",
              resolution: ["Retry `pomme mdm` with the same arguments.", "If the failure continues, run `pomme agent repair NAME`."]),
        .init(.mdmEnrollmentFailed, area: "MDM",
              title: "MDM enrollment failed in the VM.",
              cause: "The guest couldn't install the enrollment profile, or its reply about the installation wasn't valid. Pomme kept the VM's current state and the staged files so that the command can resume.",
              resolution: ["Run `pomme mdm NAME --profile PATH --debug --format json` to see the failure stage and diagnostics.", "Check that the guest can reach the MDM server, then retry `pomme mdm` with the same arguments."]),
        .init(.mdmEnrollmentOutcomeUnknown, area: "MDM",
              title: "The MDM enrollment's outcome is unknown.",
              cause: "Pomme sent the enrollment to the guest but didn't receive a verified result, so the profile might be installed. Pomme doesn't install the profile again without evidence that the first attempt didn't.",
              resolution: ["Retry `pomme mdm` with the same arguments. Pomme checks the guest's enrollment before it does anything else.", "Check the installed profiles in the guest's System Settings > General > Device Management."]),
        .init(.mdmEvidenceUnavailable, area: "MDM",
              title: "Pomme couldn't verify the MDM enrollment.",
              cause: "After enrollment, Pomme checks the guest's installed profile, enrollment status, user approval, and supervision. The guest's report was missing, malformed, or inconsistent, or it didn't show the enrollment mode that you requested.",
              resolution: ["Retry `pomme mdm` with the same arguments.", "Check the installed profiles in the guest's System Settings > General > Device Management."]),
        .init(.mdmEnrollmentConflict, area: "MDM",
              title: "The VM's MDM enrollment conflicts with the profile.",
              cause: "The guest already has an enrollment profile or MDM server that differs from the profile that you supplied.",
              resolution: ["Supply the profile that the VM is enrolled with, or enroll a different VM.", "See [Enroll in MDM](/guides/enroll-in-mdm/)."]),
        .init(.mdmDowngradeUnsupported, area: "MDM",
              title: "Pomme can't downgrade the MDM enrollment.",
              cause: "The VM's enrollment is already user approved or supervised, and `--enrollment-mode unapproved` would remove that.",
              resolution: ["Run `pomme mdm` without `--enrollment-mode unapproved`."]),
        .init(.mdmHelperNotStopped, area: "MDM",
              title: "Pomme couldn't confirm that the MDM helper stopped.",
              cause: "The temporary enrollment helper in the guest didn't report that it exited, so Pomme kept its staged files and didn't restore the VM's security settings.",
              resolution: ["Check that no enrollment helper process is still running in the guest, for example with `pomme exec NAME -- /bin/ps -ax`.", "Retry `pomme mdm` with the same arguments to finish the enrollment."]),
        .init(.mdmCleanupFailed, area: "MDM",
              title: "Pomme couldn't remove the staged MDM files.",
              cause: "Pomme removes the staged profile and the enrollment helper from the guest after enrollment. A removal or verification step failed. The enrollment might have finished, and Pomme kept the VM's state.",
              resolution: ["Retry `pomme mdm` with the same arguments to finish cleanup and restoration."]),
        .init(.mdmRestorationFailed, area: "MDM",
              title: "Pomme couldn't restore the VM after MDM enrollment.",
              cause: "Pomme couldn't restore and verify the original SIP and AMFI settings or run state. The enrollment might have finished.",
              resolution: ["Retry `pomme mdm` with the same arguments to resume restoration from its journal.", "Run `pomme sip status NAME` and `pomme amfi status NAME` to check the settings."]),
        .init(.mdmOperationPending, area: "MDM",
              title: "An unfinished operation owns this VM.",
              cause: "An earlier `pomme mdm`, `pomme sip`, or `pomme amfi` command stopped before it finished, and its journal must finish first.",
              resolution: ["Repeat the original command with its original arguments to finish it.", "Then retry `pomme mdm`."]),
        .init(.mdmPreparationIncomplete, area: "MDM",
              title: "An MDM preparation step didn't take effect.",
              cause: "A step that `pomme mdm` ran, such as creating the VM or finishing a SIP or AMFI change, reported success, but the VM didn't reach the state that the step should produce.",
              resolution: ["Run `pomme mdm NAME --profile PATH --dry-run` to see the detected state.", "Retry `pomme mdm` with the same arguments to resume."]),
        .init(.mdmJournalConflict, area: "MDM",
              title: "An unfinished MDM enrollment uses different values.",
              cause: "The VM has an unfinished enrollment for a different VM, profile, `--enrollment-mode`, or `--final-security` value. Pomme finishes one enrollment before it starts another.",
              resolution: ["Repeat `pomme mdm` with the original profile, `--enrollment-mode`, and `--final-security` values to finish it."]),
        .init(.mdmJournalDamaged, area: "MDM",
              title: "The MDM enrollment journal is damaged.",
              cause: "Pomme records MDM progress in `MDMEnrollmentJournal.json` in the VM bundle. The file isn't valid JSON for its schema, is too large, or isn't a private regular file that you own.",
              resolution: ["If you edited or copied the file, restore it.", "If the journal came from a newer Pomme build, install that build to finish the enrollment.", "Otherwise, run `pomme bug-report NAME` and attach the file to a new issue."]),
        .init(.mdmJournalChanged, area: "MDM",
              title: "The MDM enrollment journal changed unexpectedly.",
              cause: "The journal on disk no longer matched the copy that Pomme was updating, which means another process changed it.",
              resolution: ["Make sure that no other `pomme` command is running for the VM, then retry `pomme mdm`."]),
        .init(.mdmJournalStateInvalid, area: "MDM",
              title: "The MDM enrollment can't resume from its recorded state.",
              cause: "The journal records a phase that the requested step can't follow, or Pomme tried to change it without holding the VM's lock. This is a bug in Pomme.",
              resolution: ["Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.mdmJournalWriteFailed, area: "MDM",
              title: "Pomme couldn't save the MDM enrollment journal.",
              cause: "Writing, flushing, or replacing `MDMEnrollmentJournal.json` in the VM bundle failed. The message names the step and the reason that macOS gave.",
              resolution: ["Free space on the volume that holds your VMs if it's full.", "Check the ownership and permissions of the VM bundle, then retry `pomme mdm`."]),
    ]
}
