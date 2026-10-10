import Foundation

// Codes and catalog entries for the "Display automation" area. See PommeErrorCatalog.swift.

extension PommeErrorCode {
    // The VM display and its private input interface.
    static let displayInterfaceMismatch: Self = "display-interface-mismatch"
    static let displayNotReady: Self = "display-not-ready"
    static let displayUnavailable: Self = "display-unavailable"
    static let displayGeometryUnsupported: Self = "display-geometry-unsupported"
    static let displayInputUnavailable: Self = "display-input-unavailable"
    static let displayInputInterrupted: Self = "display-input-interrupted"
    static let displayInputTimeout: Self = "display-input-timeout"
    static let displayFrameTimeout: Self = "display-frame-timeout"
    static let displayFrameInvalid: Self = "display-frame-invalid"

    // Recovery screen navigation.
    static let uiRecoveryUnsupportedBuild: Self = "ui-recovery-unsupported-build"
    static let uiRecoveryUnsupportedLocale: Self = "ui-recovery-unsupported-locale"
    static let uiRecoveryReviewPending: Self = "ui-recovery-review-pending"
    static let uiRecoveryProfileMismatch: Self = "ui-recovery-profile-mismatch"
    static let uiRecoveryOwnershipUnverified: Self = "ui-recovery-ownership-unverified"
    static let uiRecoveryUnqualified: Self = "ui-recovery-unqualified"
    static let uiRecoveryScreenUnrecognized: Self = "ui-recovery-screen-unrecognized"
    static let uiRecoveryScreenUnstable: Self = "ui-recovery-screen-unstable"
    static let uiRecoveryTimedOut: Self = "ui-recovery-timed-out"
    static let uiRecoveryNoInput: Self = "ui-recovery-no-input"
    static let uiRecoveryInputUnconfirmed: Self = "ui-recovery-input-unconfirmed"
    static let uiRecoveryTerminalUnverified: Self = "ui-recovery-terminal-unverified"
    static let uiRecoveryCleanupRequired: Self = "ui-recovery-cleanup-required"
    static let uiRecoveryUnsafeCommand: Self = "ui-recovery-unsafe-command"
    static let uiRecoverySequenceInvalid: Self = "ui-recovery-sequence-invalid"
    static let uiDebugScreenshotFailed: Self = "ui-debug-screenshot-failed"
}

extension PommeErrorCatalog {
    private static let recoveryTroubleshooting =
        "See [Recovery navigation stops](/resources/troubleshooting/#recovery-navigation-stops)."
    private static let debugRetry =
        "Run the same command again with `--debug` to save a screenshot before each Recovery action."

    static let uiAutomation: [Entry] = [
        .init(.displayInterfaceMismatch, area: "Display automation",
              title: "Pomme can't use this Mac's VM display interface.",
              cause: "Pomme reads the VM screen and sends keyboard and pointer input through an interface in Virtualization.framework that only some macOS versions provide. The version on this Mac doesn't match any version that Pomme supports. This is a bug in Pomme or a macOS change that Pomme doesn't support yet.",
              resolution: ["Update Pomme with `pomme update`, then retry.", "If the error continues, run `pomme bug-report` and attach the file to a new issue."],
              hint: "Update Pomme with `pomme update`, then retry.",
              reportable: true),
        .init(.displayNotReady, area: "Display automation",
              title: "The VM display isn't ready yet.",
              cause: "The VM is still starting and hasn't published its display or input devices.",
              resolution: ["Wait for the VM to finish starting, then retry.", "Run `pomme status NAME` to check the VM's state."],
              hint: "Wait for the VM to finish starting, then retry."),
        .init(.displayUnavailable, area: "Display automation",
              title: "The VM display isn't available.",
              cause: "The running VM has no display that Pomme can read, or the display went away during the operation.",
              resolution: ["Run `pomme status NAME` to check that the VM is running.", "Restart the VM with `pomme restart NAME`, then retry."]),
        .init(.displayGeometryUnsupported, area: "Display automation",
              title: "The VM display has an unsupported size.",
              cause: "Pomme automates only a VM display of 1280 by 800 pixels, the size that Pomme gives the VMs it creates.",
              resolution: ["Run `pomme inspect NAME` to check the display configuration.", "Create a new VM with `pomme create NAME`, which uses the supported size."]),
        .init(.displayInputUnavailable, area: "Display automation",
              title: "The VM keyboard or pointer isn't available.",
              cause: "The running VM doesn't accept keyboard or pointer input yet, or its input devices don't match the ones that Pomme configures.",
              resolution: ["Wait for the VM to finish starting, then retry.", "Restart the VM with `pomme restart NAME`, then retry."]),
        .init(.displayInputInterrupted, area: "Display automation",
              title: "Input to the VM was interrupted.",
              cause: "The VM's input devices changed or went away while Pomme was sending keys or pointer events. Some input might have reached the VM.",
              resolution: ["Take a screenshot with `pomme ui screenshot` to check the VM's screen.", "Retry the command."]),
        .init(.displayInputTimeout, area: "Display automation",
              title: "Input to the VM timed out.",
              cause: "The VM didn't accept the keys or pointer events before the time limit. Some input might have reached the VM.",
              resolution: ["Take a screenshot with `pomme ui screenshot` to check the VM's screen.", "Retry with a larger `--timeout` value."]),
        .init(.displayFrameTimeout, area: "Display automation",
              title: "The VM display didn't send a frame in time.",
              cause: "Pomme waited for the VM to draw its screen, and no frame arrived before the time limit. This can happen while the VM is still starting.",
              resolution: ["Wait for the VM to finish starting, then retry.", "Retry with a larger `--timeout` value."]),
        .init(.displayFrameInvalid, area: "Display automation",
              title: "Pomme couldn't read the VM display.",
              cause: "A frame from the VM display was blank, had the wrong size, or couldn't be decoded. A blank frame is normal while the VM starts.",
              resolution: ["Wait for the VM to finish starting, then retry.", "If the error continues, run `pomme bug-report` and attach the file to a new issue."]),

        .init(.uiRecoveryUnsupportedBuild, area: "Display automation",
              title: "Pomme can't navigate Recovery for this macOS build.",
              cause: "Pomme types into the macOS Recovery screens only for macOS builds whose screens it knows. The VM's macOS build isn't one of them.",
              resolution: ["Create the VM from a supported macOS version. See [Requirements](/get-started/requirements/)."]),
        .init(.uiRecoveryUnsupportedLocale, area: "Display automation",
              title: "Pomme can't navigate Recovery in this language.",
              cause: "Pomme recognizes the macOS Recovery screens only in English.",
              resolution: ["Create the VM with English as its language."]),
        .init(.uiRecoveryReviewPending, area: "Display automation",
              title: "Recovery navigation for this macOS build isn't available yet.",
              cause: "Pomme recorded the Recovery screens for this macOS build, and their review isn't finished, so Pomme doesn't send input to them.",
              resolution: ["Create the VM from a supported macOS version. See [Requirements](/get-started/requirements/).", "Update Pomme with `pomme update` to get newly supported builds."]),
        .init(.uiRecoveryProfileMismatch, area: "Display automation",
              title: "The Recovery navigation profile doesn't match its record.",
              cause: "The Recovery navigation profile in this Pomme build doesn't match the reviewed record that it must match. This is a bug in Pomme.",
              resolution: ["Update Pomme with `pomme update`.", "Run `pomme bug-report` and attach the file to a new issue."],
              reportable: true),
        .init(.uiRecoveryOwnershipUnverified, area: "Display automation",
              title: "Pomme couldn't confirm that it owns the VM.",
              cause: "Before Pomme types into Recovery, it checks that the running VM is the one that it created. The check failed, so Pomme sent no input.",
              resolution: ["Run `pomme inspect NAME` to check the VM.", "Stop the VM with `pomme stop NAME`, then retry."]),
        .init(.uiRecoveryUnqualified, area: "Display automation",
              title: "Recovery navigation isn't qualified for this VM.",
              cause: "The VM's macOS build, language, display size, or ownership doesn't meet the rules for Recovery navigation, so Pomme sent no input.",
              resolution: ["Run `pomme inspect NAME` to check the VM's macOS version.", recoveryTroubleshooting]),
        .init(.uiRecoveryScreenUnrecognized, area: "Display automation",
              title: "Pomme didn't recognize the Recovery screen.",
              cause: "The VM showed a Recovery screen that Pomme didn't expect, so Pomme stopped before it sent more input. Pomme keeps the VM so that you can resume.",
              resolution: [debugRetry, recoveryTroubleshooting]),
        .init(.uiRecoveryScreenUnstable, area: "Display automation",
              title: "The Recovery screen didn't settle.",
              cause: "The VM screen kept changing, so Pomme couldn't confirm which Recovery screen it showed. Pomme keeps the VM so that you can resume.",
              resolution: ["Run the same command again.", debugRetry]),
        .init(.uiRecoveryTimedOut, area: "Display automation",
              title: "Recovery didn't reach the expected screen in time.",
              cause: "Pomme waited for a Recovery screen, and the VM didn't show it before the time limit. The VM host might be busy.",
              resolution: ["Run the same command again.", debugRetry, recoveryTroubleshooting]),
        .init(.uiRecoveryNoInput, area: "Display automation",
              title: "Recovery navigation stopped before it sent any input.",
              cause: "Pomme stopped before it sent any keys to Recovery, so the VM didn't change.",
              resolution: ["Run the same command again.", debugRetry]),
        .init(.uiRecoveryInputUnconfirmed, area: "Display automation",
              title: "The VM didn't confirm the Recovery input.",
              cause: "Pomme sent a key to Recovery and couldn't confirm that the VM received it, so Pomme stopped instead of sending it again.",
              resolution: ["Stop the VM with `pomme stop NAME`, then run the same command again."]),
        .init(.uiRecoveryTerminalUnverified, area: "Display automation",
              title: "Pomme couldn't confirm that Terminal opened in Recovery.",
              cause: "Pomme opened Terminal in Recovery and couldn't read the marker that proves Terminal is ready, so Pomme didn't type a command.",
              resolution: ["Stop the VM with `pomme stop NAME`, then run the same command again.", debugRetry]),
        .init(.uiRecoveryCleanupRequired, area: "Display automation",
              title: "Recovery needs cleanup before Pomme can continue.",
              cause: "An earlier Recovery action might have reached the VM, and Pomme couldn't confirm its result. Pomme doesn't send more input until the Recovery session restarts.",
              resolution: ["Stop the VM with `pomme stop NAME`, then run the same command again."],
              hint: "Stop the VM with `pomme stop NAME`, then run the same command again."),
        .init(.uiRecoveryUnsafeCommand, area: "Display automation",
              title: "Pomme refused to type a Recovery command.",
              cause: "A command or marker that Pomme was about to type in Recovery contains characters that Pomme can't type safely. This is a bug in Pomme.",
              resolution: ["Run `pomme bug-report` and attach the file to a new issue."],
              reportable: true),
        .init(.uiRecoverySequenceInvalid, area: "Display automation",
              title: "Recovery navigation ran out of order.",
              cause: "Pomme's Recovery navigation tried a step out of sequence and stopped before it sent that input. This is a bug in Pomme.",
              resolution: ["Stop the VM with `pomme stop NAME`, then run the same command again.", "Run `pomme bug-report` and attach the file to a new issue."],
              reportable: true),
        .init(.uiDebugScreenshotFailed, area: "Display automation",
              title: "Pomme couldn't save a Recovery debug screenshot.",
              cause: "With `--debug`, Pomme saves a screenshot before each Recovery action. Encoding or writing one failed. Navigation continues without it.",
              resolution: ["Check that the host's temporary directory has free space and is writable."])
    ]
}
