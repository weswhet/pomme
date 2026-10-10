import Foundation

// Codes and catalog entries for the "Guest sessions" area. See PommeErrorCatalog.swift.

extension PommeErrorCode {
    static let guestProcessCleanupUnverified: Self = "guest-process-cleanup-unverified"
    static let guestCredentialPromptFailed: Self = "guest-credential-prompt-failed"
    static let guestCredentialPromptRefused: Self = "guest-credential-prompt-refused"
    static let guestTerminalSessionNotFound: Self = "guest-terminal-session-not-found"
    static let guestTerminalSessionBusy: Self = "guest-terminal-session-busy"
    static let guestTerminalSessionReplaced: Self = "guest-terminal-session-replaced"
    static let guestTerminalSessionStateInvalid: Self = "guest-terminal-session-state-invalid"
    static let guestTerminalSessionTransient: Self = "guest-terminal-session-transient"
    static let guestTerminalSessionStorageFailed: Self = "guest-terminal-session-storage-failed"
}

extension PommeErrorCatalog {
    static let guestSession: [Entry] = [
        .init(.guestProcessCleanupUnverified, area: "Guest sessions",
              title: "Pomme couldn't confirm that the guest process stopped.",
              cause: "The command was interrupted, and Pomme couldn't confirm that the guest process it started has exited.",
              resolution: ["Run `pomme jobs list NAME` to look for the process.", "Stop it with `pomme jobs kill NAME --job ID` if it's still running."]),
        .init(.guestCredentialPromptFailed, area: "Guest sessions",
              title: "The guest command didn't prompt for its credential as expected.",
              cause: "Pomme answers a guest command's credential prompt privately. The command exited before it prompted, didn't prompt in time, prompted more than once, or printed too much output before its prompt.",
              resolution: ["Retry the command.", "Run `pomme log NAME --last 5m` to see the guest's log."]),
        .init(.guestCredentialPromptRefused, area: "Guest sessions",
              title: "Pomme refused to send a credential to the guest command.",
              cause: "The guest command's prompt didn't match the expected prompt, or the command echoed the credential, so Pomme stopped to keep the credential private.",
              resolution: ["Check that the guest is in the expected state, then retry.", "Run `pomme bug-report NAME` and attach the file to a new issue if the failure continues."],
              reportable: true),
        .init(.guestTerminalSessionNotFound, area: "Guest sessions",
              title: "The terminal session doesn't exist.",
              cause: "No terminal session has the ID that you gave. Sessions can end when the guest restarts or when you delete them.",
              resolution: ["Run `pomme sessions list NAME` to see the VM's sessions."]),
        .init(.guestTerminalSessionBusy, area: "Guest sessions",
              title: "Another client is attached to the terminal session.",
              cause: "A terminal session accepts one attachment at a time.",
              resolution: ["Detach the other client, or run `pomme sessions attach NAME --session ID --takeover` to replace it."]),
        .init(.guestTerminalSessionReplaced, area: "Guest sessions",
              title: "Another client took over the terminal session.",
              cause: "Another client attached to the session with `--takeover`, which ended this attachment.",
              resolution: ["Run `pomme sessions attach NAME --session ID --takeover` to attach again."]),
        .init(.guestTerminalSessionStateInvalid, area: "Guest sessions",
              title: "The terminal session's state doesn't allow the operation.",
              cause: "The operation needs the session in a different state. For example, a session that is still running can't be deleted.",
              resolution: ["Run `pomme sessions inspect NAME --session ID` to see its state.", "Stop a running session with `pomme sessions terminate NAME --session ID`."]),
        .init(.guestTerminalSessionTransient, area: "Guest sessions",
              title: "Recovery terminal sessions can't be saved.",
              cause: "Terminal sessions in macOS Recovery exist only while the Recovery agent runs, so their transcripts aren't stored.",
              resolution: ["Copy anything you need from the session before it ends."]),
        .init(.guestTerminalSessionStorageFailed, area: "Guest sessions",
              title: "The terminal session store couldn't complete the operation.",
              cause: "The guest's terminal session store is unavailable, an entry in it isn't valid, or a transcript changed outside the store.",
              resolution: ["Run `pomme sessions list NAME` to check the store.", "If the failure continues, run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true)
    ]
}
