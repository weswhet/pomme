import Foundation

// Codes and catalog entries for the "Guest agent" area. See PommeErrorCatalog.swift.

extension PommeErrorCode {
    static let guestAgentRootRequired: Self = "guest-agent-root-required"
    static let guestAgentLaunchFailed: Self = "guest-agent-launch-failed"
    static let guestFileCommitUnverified: Self = "guest-file-commit-unverified"
    static let guestMDMFailed: Self = "guest-mdm-failed"
    static let guestMDMTimedOut: Self = "guest-mdm-timed-out"
    static let guestMDMOutcomeUnknown: Self = "guest-mdm-outcome-unknown"
    static let guestMDMStagingFailed: Self = "guest-mdm-staging-failed"
    static let guestMDMObservationFailed: Self = "guest-mdm-observation-failed"
    static let guestMDMHelperFailed: Self = "guest-mdm-helper-failed"
    static let guestOwnerCredentialUnavailable: Self = "guest-owner-credential-unavailable"
    static let guestOwnerCredentialInvalid: Self = "guest-owner-credential-invalid"
    static let guestSetupAssistantPreferencesFailed: Self = "guest-setup-assistant-preferences-failed"
    static let guestRecoveryAgentRequired: Self = "guest-recovery-agent-required"
    static let guestRecoveryTimedOut: Self = "guest-recovery-timed-out"
    static let guestRecoveryNVRAMUnavailable: Self = "guest-recovery-nvram-unavailable"
    static let guestRecoveryEnvironmentUnverified: Self = "guest-recovery-environment-unverified"
    static let guestRecoveryTransitionPending: Self = "guest-recovery-transition-pending"
    static let guestRecoveryVerificationFailed: Self = "guest-recovery-verification-failed"
    static let guestRecoveryDataVolumeUnavailable: Self = "guest-recovery-data-volume-unavailable"
}

extension PommeErrorCatalog {
    static let guestInternal: [Entry] = [
        .init(.guestAgentRootRequired, area: "Guest agent",
              title: "The operation needs the guest's root agent.",
              cause: "The request reached a PommeAgent process that doesn't run as root. Pomme sends privileged requests only to the root agent, so this is a bug in Pomme.",
              resolution: ["Run `pomme agent repair NAME` to reinstall the agent.", "If the failure continues, run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.guestAgentLaunchFailed, area: "Guest agent",
              title: "The guest agent couldn't start.",
              cause: "PommeAgent rejected its launch arguments, couldn't verify its own code or credential, or couldn't open its connection to the host.",
              resolution: ["Run `pomme agent status NAME` to check the agent.", "Run `pomme agent repair NAME` to reinstall it."]),
        .init(.guestFileCommitUnverified, area: "Guest agent",
              title: "Pomme couldn't verify the end of a file replacement in the guest.",
              cause: "The new file is in place, but PommeAgent couldn't confirm that it removed the previous file from the staging path. A leftover staging file might remain next to the destination.",
              resolution: ["Check the destination's directory in the guest and remove any leftover staging file.", "Run `pomme cat NAME PATH` to confirm the destination's contents."]),
        .init(.guestMDMFailed, area: "Guest agent",
              title: "The guest couldn't complete the MDM operation.",
              cause: "PommeAgent couldn't enroll, observe, or clean up an MDM profile in the guest. The message gives the step that failed.",
              resolution: ["Read the step in the message.", "Run `pomme log NAME --last 5m` to see the guest's log, then retry `pomme mdm`."]),
        .init(.guestMDMTimedOut, area: "Guest agent",
              title: "The guest MDM operation timed out.",
              cause: "Enrolling or checking an MDM profile in the guest didn't finish within its time limit, often because the MDM server didn't respond.",
              resolution: ["Check that the guest can reach the MDM server, then retry `pomme mdm`."]),
        .init(.guestMDMOutcomeUnknown, area: "Guest agent",
              title: "The MDM enrollment's outcome is unknown.",
              cause: "The enrollment stopped at a point where Pomme can't tell whether the guest installed the profile. Pomme kept the enrollment identity in place.",
              resolution: ["Check the installed profiles in the guest's System Settings > General > Device Management before you retry.", "Retry `pomme mdm` only when the profile isn't installed."]),
        .init(.guestMDMStagingFailed, area: "Guest agent",
              title: "The guest couldn't stage the MDM profile.",
              cause: "PommeAgent keeps the MDM profile in a private, root-owned directory. The directory or the profile didn't have the required owner and permissions, or PommeAgent couldn't remove the staged profile.",
              resolution: ["Retry `pomme mdm`.", "If the failure continues, run `pomme agent repair NAME`."]),
        .init(.guestMDMObservationFailed, area: "Guest agent",
              title: "The guest couldn't list its MDM profiles.",
              cause: "The guest's `profiles` command failed, returned too much output, or didn't exit.",
              resolution: ["Retry the command.", "Run `pomme log NAME --last 5m` to see the guest's log."]),
        .init(.guestMDMHelperFailed, area: "Guest agent",
              title: "The guest's MDM enrollment helper failed.",
              cause: "The temporary helper that installs the MDM profile in the guest rejected its request, files, or code signature, or the enrollment failed.",
              resolution: ["Read the reason in the message.", "Retry `pomme mdm`. If the failure continues, run `pomme bug-report NAME` and attach the file to a new issue."]),
        .init(.guestOwnerCredentialUnavailable, area: "Guest agent",
              title: "The guest has no automatic-login credential for the owner.",
              cause: "Pomme reads the owner's credential from the guest's automatic-login setting. The guest has no automatic-login account, or it's a different account.",
              resolution: ["Turn on automatic login for the owner account in the guest's System Settings > Users & Groups.", "See [Change SIP and AMFI](/guides/change-sip-and-amfi/)."]),
        .init(.guestOwnerCredentialInvalid, area: "Guest agent",
              title: "The guest's automatic-login credential can't be used.",
              cause: "The automatic-login file isn't the root-owned file that macOS writes, or Pomme couldn't decode it.",
              resolution: ["Turn automatic login off and on again in the guest's System Settings > Users & Groups, then retry."]),
        .init(.guestSetupAssistantPreferencesFailed, area: "Guest agent",
              title: "The guest couldn't update its Setup Assistant preferences.",
              cause: "PommeAgent skips Setup Assistant screens by writing the owner's preferences. It couldn't find the owner account, or reading or writing a preference file failed.",
              resolution: ["Restart the guest with `pomme restart NAME` so that PommeAgent tries again.", "Run `pomme log NAME --last 5m` to see the guest's log."]),
        .init(.guestRecoveryAgentRequired, area: "Guest agent",
              title: "The operation needs the Recovery agent.",
              cause: "A security operation reached a PommeAgent that isn't running in macOS Recovery as root. Pomme sends these operations only to the Recovery agent, so this is a bug in Pomme.",
              resolution: ["Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.guestRecoveryTimedOut, area: "Guest agent",
              title: "The Recovery security command timed out.",
              cause: "A command that the Recovery agent runs, such as `csrutil`, didn't finish within its time limit.",
              resolution: ["Retry the `pomme sip` or `pomme amfi` command.", "Run `pomme sip status NAME` to check the VM's security state."]),
        .init(.guestRecoveryNVRAMUnavailable, area: "Guest agent",
              title: "The Recovery agent can't change NVRAM.",
              cause: "macOS Recovery denied a write to the VM's boot arguments, or this Recovery version hasn't passed Pomme's NVRAM write and read-back check.",
              resolution: ["Run `pomme amfi status NAME` to check the current state.", "See [Change SIP and AMFI](/guides/change-sip-and-amfi/)."]),
        .init(.guestRecoveryEnvironmentUnverified, area: "Guest agent",
              title: "Pomme couldn't verify the Recovery environment.",
              cause: "The guest isn't running in an authenticated macOS Recovery, or its startup volume isn't the one that the request named.",
              resolution: ["Stop the VM with `pomme stop NAME`, then retry the command so that Pomme starts Recovery again."]),
        .init(.guestRecoveryTransitionPending, area: "Guest agent",
              title: "An earlier security change is unfinished.",
              cause: "A previous `pomme sip` or `pomme amfi` change stopped partway, and the Recovery agent must finish or roll it back first.",
              resolution: ["Repeat the earlier command in the same direction so that Pomme can finish it.", "Run `pomme amfi status NAME` to see the state."]),
        .init(.guestRecoveryVerificationFailed, area: "Guest agent",
              title: "Pomme couldn't verify the security change.",
              cause: "After it changed or rolled back the VM's security settings, the Recovery agent read back a value that didn't match.",
              resolution: ["Run `pomme sip status NAME` and `pomme amfi status NAME` to see the current state.", "Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.guestRecoveryDataVolumeUnavailable, area: "Guest agent",
              title: "The Recovery agent couldn't find the guest's Data volume.",
              cause: "In macOS Recovery, PommeAgent needs exactly one System and Data volume pair from the expected volume group. `diskutil` failed, or reported none, several, or an unsafe mount.",
              resolution: ["Stop the VM with `pomme stop NAME`, then retry.", "If the failure continues, run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true)
    ]
}
