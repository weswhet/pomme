import Foundation

/// The one table of Pomme error codes. Text output, JSON output,
/// `pomme bug-report`, and the generated Errors reference page all read it.
/// Each area keeps its entries in a `PommeErrorCatalog+Area.swift` file next
/// to this one, and `entries` joins them.
enum PommeErrorCatalog {
    struct Entry: Equatable, Sendable {
        let code: PommeErrorCode
        /// The section of the Errors page, such as `VMs` or `Guest agent`.
        let area: String
        /// A short sentence that names the failure.
        let title: String
        /// Why the failure happens, in one or two sentences.
        let cause: String
        /// What resolves it, one step per element.
        let resolution: [String]
        /// A one-line next step for errors that don't supply their own.
        let hint: String?
        /// Whether the failure is unexpected, so the text output also asks
        /// the person to run `pomme bug-report`.
        let reportable: Bool

        init(
            _ code: PommeErrorCode,
            area: String,
            title: String,
            cause: String,
            resolution: [String],
            hint: String? = nil,
            reportable: Bool = false
        ) {
            self.code = code
            self.area = area
            self.title = title
            self.cause = cause
            self.resolution = resolution
            self.hint = hint
            self.reportable = reportable
        }
    }

    static let documentationURL = "https://pommevm.dev/reference/errors/"

    static let entries: [Entry] = {
        let sections: [[Entry]] = [
            general, vm, restoreImage, helper, guest, guestInternal, guestSession,
            provisioning, operations, security, recovery, mdm, uiAutomation
        ]
        return sections.flatMap { $0 }
    }()

    private static let index: [PommeErrorCode: Entry] = Dictionary(
        entries.map { ($0.code, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func entry(for code: PommeErrorCode) -> Entry? { index[code] }

    static func documentationURL(for code: PommeErrorCode) -> String {
        documentationURL + "#" + code.rawValue
    }

    /// The catalog as the JSON array that `pomme --pomme-error-catalog`
    /// prints for the documentation generator.
    static func jsonObject() -> [[String: Any]] {
        entries.map { entry in
            [
                "code": entry.code.rawValue,
                "area": entry.area,
                "title": entry.title,
                "cause": entry.cause,
                "resolution": entry.resolution,
                "hint": entry.hint.map { $0 as Any } ?? NSNull(),
                "reportable": entry.reportable
            ]
        }
    }
}

// MARK: - General

extension PommeErrorCode {
    static let internalError: Self = "internal-error"
    static let operationFailed: Self = "operation-failed"
    static let invalidRequest: Self = "invalid-request"
    static let invalidArguments: Self = "invalid-arguments"
    static let operationCancelled: Self = "operation-cancelled"
    static let timedOut: Self = "timed-out"
    static let terminalRequired: Self = "terminal-required"
    static let dataInvalid: Self = "data-invalid"
    static let configInvalid: Self = "config-invalid"
    static let systemError: Self = "system-error"
    static let systemCallFailed: Self = "system-call-failed"
    static let permissionDenied: Self = "permission-denied"
    static let fileNotFound: Self = "file-not-found"
    static let fileError: Self = "file-error"
    static let hostFileUnavailable: Self = "host-file-unavailable"
    static let hostDiskFull: Self = "host-disk-full"
    static let hostDiskSpaceInsufficient: Self = "host-disk-space-insufficient"
    static let hostUnsupported: Self = "host-unsupported"
    static let hostUpdateRequired: Self = "host-update-required"
    static let hostCommandFailed: Self = "host-command-failed"
    static let networkError: Self = "network-error"
    static let keychainError: Self = "keychain-error"
    static let credentialUnavailable: Self = "credential-unavailable"
    static let securityConfigurationInvalid: Self = "security-configuration-invalid"
}

extension PommeErrorCatalog {
    static let general: [Entry] = [
        .init(.internalError, area: "General",
              title: "Pomme hit an unexpected error.",
              cause: "An error reached the command without a description. This is a bug in Pomme.",
              resolution: ["Run `pomme bug-report` and attach the file it writes to a new issue."],
              hint: "This is a bug in Pomme.",
              reportable: true),
        .init(.operationFailed, area: "General",
              title: "The operation failed.",
              cause: "An operation reported a failure without a more specific code.",
              resolution: ["Read the message for the reason.", "If the reason isn't clear, run `pomme bug-report` and attach the file to a new issue."],
              reportable: true),
        .init(.invalidRequest, area: "General",
              title: "A value in the request isn't valid.",
              cause: "An argument, flag value, or path doesn't meet the command's rules. The message names the value and the rule.",
              resolution: ["Correct the value that the message names.", "Run the command with `--help` to see the accepted values."]),
        .init(.invalidArguments, area: "General",
              title: "The arguments aren't valid.",
              cause: "The command line doesn't match the command's usage.",
              resolution: ["Run `pomme help COMMAND` to see the usage."]),
        .init(.operationCancelled, area: "General",
              title: "The operation was cancelled.",
              cause: "You pressed Control-C, or another process cancelled the operation.",
              resolution: ["Run the command again if you didn't mean to cancel it."]),
        .init(.timedOut, area: "General",
              title: "The operation timed out.",
              cause: "The operation didn't finish within its time limit.",
              resolution: ["Retry with a larger `--timeout` value.", "Run `pomme status NAME` to check that the VM is responsive."]),
        .init(.terminalRequired, area: "General",
              title: "The command needs an interactive terminal.",
              cause: "The command prompts or draws a full-screen interface, and standard input or output isn't a terminal.",
              resolution: ["Run the command in Terminal, or use the non-interactive form that its `--help` describes."]),
        .init(.dataInvalid, area: "General",
              title: "Pomme couldn't read structured data.",
              cause: "A JSON document, such as a reply from the VM helper or a file in a VM bundle, has a missing key or a value of the wrong type.",
              resolution: ["If the data came from a file that you edited, restore it.", "Otherwise, run `pomme bug-report` and attach the file to a new issue."],
              reportable: true),
        .init(.configInvalid, area: "General",
              title: "The config file isn't valid.",
              cause: "The file named in the message has a syntax error, an unknown key, or a value of the wrong type.",
              resolution: ["Correct the key that the message names.", "See [Config file](/reference/config-file/) for the accepted keys."]),
        .init(.systemError, area: "General",
              title: "A macOS framework reported an error.",
              cause: "A system framework failed. The message gives its reason, and the error's causes give its domain and number.",
              resolution: ["Read the reason in the message.", "If it doesn't explain the failure, run `pomme bug-report` and attach the file to a new issue."]),
        .init(.systemCallFailed, area: "General",
              title: "A system call failed.",
              cause: "A low-level operation, such as opening a socket or a file, failed. The message names the call and the reason that macOS gave.",
              resolution: ["Read the reason in the message.", "If it doesn't explain the failure, run `pomme bug-report` and attach the file to a new issue."]),
        .init(.permissionDenied, area: "General",
              title: "Permission was denied.",
              cause: "macOS refused access to a file, directory, or resource.",
              resolution: ["Check the ownership and permissions of the path in the message.", "Run Pomme as the user who created the VM, not with `sudo`."]),
        .init(.fileNotFound, area: "General",
              title: "A file doesn't exist.",
              cause: "A file or directory that the operation needs is missing.",
              resolution: ["Check the path in the message."]),
        .init(.fileError, area: "General",
              title: "A file operation failed.",
              cause: "Pomme couldn't read or write a file. The message gives the reason.",
              resolution: ["Check the path and the reason in the message."]),
        .init(.hostFileUnavailable, area: "General",
              title: "A host file can't be used.",
              cause: "The host path that you gave is missing, is a directory or a symbolic link, or isn't readable.",
              resolution: ["Give the path of a regular, readable file."]),
        .init(.hostDiskFull, area: "General",
              title: "The disk is out of space.",
              cause: "The volume that holds your VMs, or the volume that Pomme was writing to, has no free space.",
              resolution: ["Free space on the volume. Each macOS VM needs as much free space as its disk size, which is at least 40 GB.", "Run `pomme list` and delete VMs that you no longer need with `pomme delete NAME`."],
              hint: "Free space on the volume that holds your VMs, then retry."),
        .init(.hostDiskSpaceInsufficient, area: "General",
              title: "There isn't enough free space to create the VM.",
              cause: "Before it downloads or writes anything, `pomme create` and `pomme template create` compare the free space on each volume they use with what the creation needs: the rest of the restore image download, about 35 GB for an installed macOS system (or the disk size, if it's smaller), and, for a VM cloned from a template, about 5 GB for the clone's own changes. The message lists each part.",
              resolution: ["Free at least the amount that the hint names on that volume.", "Run `pomme list` and delete VMs that you no longer need with `pomme delete NAME`.", "Run `pomme create --dry-run` to see the space check without creating anything."],
              hint: "Free space on the volume that the message names, then retry."),
        .init(.hostUnsupported, area: "General",
              title: "This Mac can't run Pomme VMs.",
              cause: "Virtualization.framework isn't available. Pomme needs a Mac with Apple silicon.",
              resolution: ["Run Pomme on a Mac with Apple silicon. See [Requirements](/get-started/requirements/)."]),
        .init(.hostUpdateRequired, area: "General",
              title: "This Mac needs a software update.",
              cause: "The restore image needs newer system software on this Mac than it has.",
              resolution: ["Install the available updates in System Settings > General > Software Update, then retry."]),
        .init(.hostCommandFailed, area: "General",
              title: "A host operation failed.",
              cause: "An operation on this Mac, such as a file copy or a tool that Pomme runs, failed. The message gives the reason.",
              resolution: ["Read the reason in the message and correct it.", "If the reason isn't clear, run `pomme bug-report` and attach the file to a new issue."]),
        .init(.networkError, area: "General",
              title: "A network request failed.",
              cause: "Pomme couldn't reach a server, such as Apple's restore image catalog.",
              resolution: ["Check the network connection, then retry."],
              hint: "Check the network connection, then retry."),
        .init(.keychainError, area: "General",
              title: "A Keychain operation failed.",
              cause: "Pomme stores VM credentials in your login Keychain. macOS refused the request; the message gives the Keychain's reason.",
              resolution: ["Unlock your login Keychain, then retry.", "If macOS asks whether `pomme` can access an item, allow it."]),
        .init(.credentialUnavailable, area: "General",
              title: "A required credential isn't available.",
              cause: "The operation needs the guest owner's credential, and Pomme couldn't find it in the Keychain, the environment, or a prompt.",
              resolution: ["Run the command in an interactive terminal so that Pomme can prompt for it.", "See [Change SIP and AMFI](/guides/change-sip-and-amfi/)."]),
        .init(.securityConfigurationInvalid, area: "General",
              title: "The security configuration isn't valid.",
              cause: "A security setting or its combination with other flags isn't supported.",
              resolution: ["Correct the setting that the message names."])
    ]
}

// MARK: - VMs

extension PommeErrorCode {
    static let vmNotFound: Self = "vm-not-found"
    static let vmNotSpecified: Self = "vm-not-specified"
    static let vmNotRunning: Self = "vm-not-running"
    static let vmRunning: Self = "vm-running"
    static let vmRunningOtherMode: Self = "vm-running-other-mode"
    static let vmPausedOtherMode: Self = "vm-paused-other-mode"
    static let vmStateInvalid: Self = "vm-state-invalid"
    static let vmBundleDamaged: Self = "vm-bundle-damaged"
    static let vmHardwareUnsupported: Self = "vm-hardware-unsupported"
    static let vmMemoryOutOfRange: Self = "vm-memory-out-of-range"
    static let vmDeleteRefused: Self = "vm-delete-refused"
    static let vmConfigurationInvalid: Self = "vm-configuration-invalid"
    static let vmDiskImageInvalid: Self = "vm-disk-image-invalid"
    static let vmLimitReached: Self = "vm-limit-reached"
    static let vmSaveFailed: Self = "vm-save-failed"
    static let vmStartFailed: Self = "vm-start-failed"
    static let virtualizationError: Self = "virtualization-error"
    static let virtualizationUnsupported: Self = "virtualization-unsupported"
    static let snapshotNotFound: Self = "snapshot-not-found"
}

extension PommeErrorCatalog {
    static let vm: [Entry] = [
        .init(.vmNotFound, area: "VMs",
              title: "The VM doesn't exist.",
              cause: "No Pomme VM has the name that you gave.",
              resolution: ["Run `pomme list` to see your VMs.", "Create the VM with `pomme create NAME`."]),
        .init(.vmNotSpecified, area: "VMs",
              title: "No VM was named.",
              cause: "The command needs a VM name, and none was given or set in `POMME_VM_NAME`.",
              resolution: ["Pass the VM name, or set `POMME_VM_NAME`."]),
        .init(.vmNotRunning, area: "VMs",
              title: "The VM isn't running.",
              cause: "The command needs a running VM, and the VM's helper isn't running.",
              resolution: ["Start the VM with `pomme start NAME`."],
              hint: "Start it with `pomme start NAME`."),
        .init(.vmRunning, area: "VMs",
              title: "The VM is running.",
              cause: "The command needs a stopped VM.",
              resolution: ["Stop the VM with `pomme stop NAME`, then retry."]),
        .init(.vmRunningOtherMode, area: "VMs",
              title: "The VM is running in the other boot mode.",
              cause: "`pomme start` asked for normal or Recovery boot, and the VM is already running in the other one.",
              resolution: ["Stop the VM with `pomme stop NAME`, then start it in the boot mode that you want."]),
        .init(.vmPausedOtherMode, area: "VMs",
              title: "The VM is paused in the other boot mode.",
              cause: "`pomme start` resumes a paused VM only in the boot mode that it was paused in.",
              resolution: ["Stop the VM with `pomme stop NAME`, then start it in the boot mode that you want.", "To continue in the same mode, run `pomme start` without changing the boot mode."]),
        .init(.vmStateInvalid, area: "VMs",
              title: "The VM's state doesn't allow this operation.",
              cause: "The operation needs the VM in a different state, such as stopped, running, or paused. The message names the state that it needs.",
              resolution: ["Run `pomme status NAME` to see the VM's state.", "Change it with `pomme start`, `pomme stop`, `pomme pause`, or `pomme resume`, then retry."]),
        .init(.vmBundleDamaged, area: "VMs",
              title: "The VM bundle is damaged.",
              cause: "A file in the VM bundle, such as its hardware model or machine identifier, is missing or invalid.",
              resolution: ["Restore the VM from a backup or a snapshot, or create it again."],
              reportable: true),
        .init(.vmHardwareUnsupported, area: "VMs",
              title: "This Mac can't run the VM's hardware model.",
              cause: "The VM was created for a hardware model that this Mac doesn't support, usually because it was created on a newer Mac.",
              resolution: ["Run the VM on the Mac that created it, or create a new VM on this Mac."]),
        .init(.vmMemoryOutOfRange, area: "VMs",
              title: "The memory size is out of range.",
              cause: "The requested memory is below the guest's minimum or outside the range that this Mac supports.",
              resolution: ["Pass a `--memory` value within the range that the message gives, such as `--memory 4GB`."]),
        .init(.vmDeleteRefused, area: "VMs",
              title: "Pomme refused to delete the VM.",
              cause: "Pomme deletes only a verified Pomme-owned VM, and only when the confirmation matches its name.",
              resolution: ["Check the name with `pomme list`, then retry `pomme delete NAME`."]),
        .init(.vmConfigurationInvalid, area: "VMs",
              title: "The VM's configuration isn't valid.",
              cause: "Virtualization.framework rejected the VM's configuration on this Mac.",
              resolution: ["Run `pomme inspect NAME` to check its CPU, memory, and disk settings.", "Lower the VM's memory if it exceeds what this Mac supports."]),
        .init(.vmDiskImageInvalid, area: "VMs",
              title: "The VM's disk image can't be used.",
              cause: "Virtualization.framework couldn't open the VM's disk image. It might be damaged or in use by another process.",
              resolution: ["Make sure that no other process has the VM open.", "Restore the VM from a snapshot, or create it again."]),
        .init(.vmLimitReached, area: "VMs",
              title: "Too many macOS VMs are running.",
              cause: "macOS limits how many macOS VMs can run at the same time on one Mac.",
              resolution: ["Stop another VM with `pomme stop NAME`, then retry.", "Run `pomme list` to see which VMs are running."]),
        .init(.vmSaveFailed, area: "VMs",
              title: "Saving or restoring the VM's state failed.",
              cause: "Virtualization.framework couldn't save or restore the VM's memory state.",
              resolution: ["Stop the VM with `pomme stop NAME`, then start it again."]),
        .init(.vmStartFailed, area: "VMs",
              title: "The VM couldn't start.",
              cause: "Virtualization.framework failed to start the VM. The message gives its reason.",
              resolution: ["Read the reason in the message.", "Check the helper log in the VM bundle, or run `pomme bug-report NAME`."],
              reportable: true),
        .init(.virtualizationError, area: "VMs",
              title: "Virtualization.framework reported an error.",
              cause: "The framework that runs the VM failed. The error's causes give its `VZErrorDomain` code.",
              resolution: ["Retry the operation.", "If it fails again, run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.virtualizationUnsupported, area: "VMs",
              title: "This Mac doesn't support the virtualization feature.",
              cause: "The operation needs a Virtualization.framework feature that this Mac or macOS version doesn't have.",
              resolution: ["Update macOS on this Mac, or run the operation on a Mac that supports it."]),
        .init(.snapshotNotFound, area: "VMs",
              title: "The snapshot doesn't exist.",
              cause: "The VM has no snapshot with the name that you gave.",
              resolution: ["Run `pomme snapshot list NAME` to see the VM's snapshots."])
    ]
}

// MARK: - Restore images

extension PommeErrorCode {
    static let restoreImageUnsupported: Self = "restore-image-unsupported"
    static let restoreImageNotDownloaded: Self = "restore-image-not-downloaded"
    static let restoreImageDownloadFailed: Self = "restore-image-download-failed"
    static let restoreImageCatalogFailed: Self = "restore-image-catalog-failed"
    static let restoreImageUnknownDevice: Self = "restore-image-unknown-device"
    static let restoreImageInvalid: Self = "restore-image-invalid"
    static let macosInstallFailed: Self = "macos-install-failed"
}

extension PommeErrorCatalog {
    static let restoreImage: [Entry] = [
        .init(.restoreImageUnsupported, area: "Restore images",
              title: "The restore image doesn't support this Mac.",
              cause: "The restore image has no configuration that this Mac can run.",
              resolution: ["Choose a newer restore image with `pomme ipsw list`."]),
        .init(.restoreImageNotDownloaded, area: "Restore images",
              title: "The restore image isn't downloaded.",
              cause: "The selected restore image is remote, and the command needs a local copy.",
              resolution: ["Download it with `pomme ipsw download`, or pass a local file with `--restore-image`."]),
        .init(.restoreImageDownloadFailed, area: "Restore images",
              title: "The restore image download failed.",
              cause: "Apple's server returned an error status for the download.",
              resolution: ["Check the network connection, then retry the download."]),
        .init(.restoreImageCatalogFailed, area: "Restore images",
              title: "The restore image catalog couldn't be loaded.",
              cause: "Apple's restore image catalog returned an error status.",
              resolution: ["Check the network connection, then retry."]),
        .init(.restoreImageUnknownDevice, area: "Restore images",
              title: "The device identifier isn't known.",
              cause: "The restore image catalog has no entry for the device identifier that you gave.",
              resolution: ["Run `pomme ipsw list` to see the available images."]),
        .init(.restoreImageInvalid, area: "Restore images",
              title: "The restore image can't be used.",
              cause: "Virtualization.framework couldn't load the restore image or its catalog.",
              resolution: ["Download the image again with `pomme ipsw download`, then retry."]),
        .init(.macosInstallFailed, area: "Restore images",
              title: "The macOS installation failed.",
              cause: "Virtualization.framework couldn't install macOS from the restore image into the VM.",
              resolution: ["Check that the volume has enough free space for the VM's disk.", "Download the restore image again, then run `pomme create NAME --resume`."],
              reportable: true)
    ]
}

// MARK: - VM helper

extension PommeErrorCode {
    static let helperStartFailed: Self = "helper-start-failed"
    static let helperStartTimedOut: Self = "helper-start-timed-out"
    static let helperCommandFailed: Self = "helper-command-failed"
    static let helperUnknownCommand: Self = "helper-unknown-command"
    static let helperTimedOut: Self = "helper-timed-out"
    static let helperProtocolError: Self = "helper-protocol-error"
    static let helperIncompatible: Self = "helper-incompatible"
    static let helperIdentityUnverified: Self = "helper-identity-unverified"
    static let helperSocketPathTooLong: Self = "helper-socket-path-too-long"
}

extension PommeErrorCatalog {
    static let helper: [Entry] = [
        .init(.helperStartFailed, area: "VM helper",
              title: "The VM helper exited while it started.",
              cause: "Each running VM has a helper process. It exited before it opened its control socket, usually because the VM couldn't start.",
              resolution: ["Read `pomme-helper.log` in the VM bundle; the message gives its path.", "Run `pomme bug-report NAME` and attach the file to a new issue if the log doesn't explain the failure."],
              reportable: true),
        .init(.helperStartTimedOut, area: "VM helper",
              title: "The VM helper didn't start in time.",
              cause: "The helper process didn't open its control socket before the time limit.",
              resolution: ["Retry with a larger `--timeout` value.", "Read `pomme-helper.log` in the VM bundle; the message gives its path."]),
        .init(.helperCommandFailed, area: "VM helper",
              title: "The VM helper couldn't run the command.",
              cause: "The running VM's helper reported a failure without a more specific code. The message gives its reason.",
              resolution: ["Read the reason in the message.", "Run `pomme bug-report NAME` and attach the file to a new issue if the reason isn't clear."],
              reportable: true),
        .init(.helperUnknownCommand, area: "VM helper",
              title: "The VM helper doesn't know the command.",
              cause: "The VM helper is older or newer than this `pomme` and doesn't support the command.",
              resolution: ["Restart the VM with `pomme stop NAME` and `pomme start NAME` so that its helper matches this `pomme`."]),
        .init(.helperTimedOut, area: "VM helper",
              title: "The VM helper didn't respond in time.",
              cause: "A request to the running VM's helper didn't finish within its time limit.",
              resolution: ["Retry with a larger `--timeout` value.", "Run `pomme status NAME` to check that the helper is responsive."]),
        .init(.helperProtocolError, area: "VM helper",
              title: "The VM helper sent an invalid reply.",
              cause: "A reply from the running VM's helper was malformed or incomplete.",
              resolution: ["Restart the VM with `pomme stop NAME` and `pomme start NAME`.", "Run `pomme bug-report NAME` and attach the file to a new issue if it happens again."],
              reportable: true),
        .init(.helperIncompatible, area: "VM helper",
              title: "The VM helper doesn't match this version of Pomme.",
              cause: "The running VM's helper started from a different version of Pomme and speaks another control protocol version or lacks a feature.",
              resolution: ["Restart the VM with `pomme stop NAME` and `pomme start NAME`."]),
        .init(.helperIdentityUnverified, area: "VM helper",
              title: "Pomme couldn't verify the VM helper.",
              cause: "Pomme stops a helper only after it confirms that the process is the helper it started.",
              resolution: ["Run `pomme status NAME`. If the VM is stuck, quit its helper process in Activity Monitor."]),
        .init(.helperSocketPathTooLong, area: "VM helper",
              title: "The control socket path is too long.",
              cause: "macOS limits Unix socket paths to 104 bytes, and the VM bundle's path is longer.",
              resolution: ["Move the VMs to a shorter path, or use a shorter VM name."])
    ]
}

// MARK: - Guest agent

extension PommeErrorCode {
    static let guestAgentUnavailable: Self = "guest-agent-unavailable"
    static let guestAgentConnecting: Self = "guest-agent-connecting"
    static let guestAgentDisconnected: Self = "guest-agent-disconnected"
    static let guestAgentTimedOut: Self = "guest-agent-timed-out"
    static let guestAgentProtocolError: Self = "guest-agent-protocol-error"
    static let guestAgentUpdatePending: Self = "guest-agent-update-pending"
    static let guestAuthenticationFailed: Self = "guest-authentication-failed"
    static let guestOperationFailed: Self = "guest-operation-failed"
    static let guestCommandNotFound: Self = "guest-command-not-found"
    static let guestNotFound: Self = "guest-not-found"
    static let guestInvalidRequest: Self = "guest-invalid-request"
    static let guestOperationUnsupported: Self = "guest-operation-unsupported"
    static let guestIOError: Self = "guest-io-error"
    static let guestPermissionDenied: Self = "guest-permission-denied"
    static let guestRemoteLoginFullDiskAccessRequired: Self = "guest-remote-login-full-disk-access-required"
    static let guestRemoteLoginVerificationFailed: Self = "guest-remote-login-verification-failed"
    static let guestRecoveryOperationFailed: Self = "guest-recovery-operation-failed"
    static let guestFeatureUnsupported: Self = "guest-feature-unsupported"
    static let guestFileTransferFailed: Self = "guest-file-transfer-failed"
    static let guestJobNotFound: Self = "guest-job-not-found"
}

extension PommeErrorCatalog {
    static let guest: [Entry] = [
        .init(.guestAgentUnavailable, area: "Guest agent",
              title: "The guest agent isn't connected.",
              cause: "PommeAgent runs inside the guest and connects to the host after macOS starts. It hasn't connected yet, or it isn't installed.",
              resolution: ["Wait for the guest to finish starting; `pomme status NAME` reports when the agent connects.", "If it never connects, see [Repair the agent](/guides/repair-the-agent/)."],
              hint: "Run `pomme status NAME` to see when the agent connects."),
        .init(.guestAgentConnecting, area: "Guest agent",
              title: "The guest agent is still connecting.",
              cause: "PommeAgent is authenticating with the host.",
              resolution: ["Retry in a moment."]),
        .init(.guestAgentDisconnected, area: "Guest agent",
              title: "The guest agent disconnected.",
              cause: "The connection to PommeAgent closed before it replied, often because the guest restarted, shut down, or went to sleep.",
              resolution: ["Run `pomme status NAME`, then retry when the agent is connected."]),
        .init(.guestAgentTimedOut, area: "Guest agent",
              title: "The guest agent didn't respond in time.",
              cause: "PommeAgent didn't reply before the time limit, often because the guest is busy or still starting.",
              resolution: ["Retry with a larger `--timeout` value.", "Run `pomme status NAME` to check the agent's connection."]),
        .init(.guestAgentProtocolError, area: "Guest agent",
              title: "The guest agent sent an invalid reply.",
              cause: "A message from PommeAgent didn't follow the agent protocol, often because the agent and `pomme` versions differ.",
              resolution: ["Update the agent with `pomme agent update NAME`.", "See [Repair the agent](/guides/repair-the-agent/)."],
              reportable: true),
        .init(.guestAgentUpdatePending, area: "Guest agent",
              title: "A guest agent update is waiting to finish.",
              cause: "A new PommeAgent was installed and is waiting to activate.",
              resolution: ["Run `pomme agent update NAME` to finish the update, or restart the guest."]),
        .init(.guestAuthenticationFailed, area: "Guest agent",
              title: "The guest agent rejected the host's credential.",
              cause: "The credential that the host presented doesn't match the agent's, or it expired.",
              resolution: ["Run `pomme agent status NAME`.", "See [Repair the agent](/guides/repair-the-agent/) to reinstall the agent's credential."]),
        .init(.guestOperationFailed, area: "Guest agent",
              title: "The guest couldn't complete the operation.",
              cause: "PommeAgent reported a failure. The message gives the guest's reason.",
              resolution: ["Read the reason in the message.", "Run `pomme log NAME --last 5m` to see the guest's log."]),
        .init(.guestCommandNotFound, area: "Guest agent",
              title: "The command doesn't exist in the guest.",
              cause: "The executable that you gave to `pomme exec` isn't at that path in the guest, or isn't in the guest's `PATH`.",
              resolution: ["Give the full path of the executable, such as `/usr/bin/sw_vers`.", "Check the path with `pomme exec NAME -- /bin/ls -l PATH`."]),
        .init(.guestNotFound, area: "Guest agent",
              title: "The guest item doesn't exist.",
              cause: "A file, directory, user, group, or job that the operation names doesn't exist in the guest.",
              resolution: ["Check the name or path in the message."]),
        .init(.guestInvalidRequest, area: "Guest agent",
              title: "The guest agent rejected the request.",
              cause: "PommeAgent rejected a value in the request. The message gives the reason.",
              resolution: ["Correct the value that the message names.", "If you didn't give the value, update the agent with `pomme agent update NAME`."]),
        .init(.guestOperationUnsupported, area: "Guest agent",
              title: "The guest agent doesn't support the operation.",
              cause: "The installed PommeAgent is older than this `pomme`, or the operation isn't available in the guest's current boot mode.",
              resolution: ["Update the agent with `pomme agent update NAME`."]),
        .init(.guestIOError, area: "Guest agent",
              title: "A guest file operation failed.",
              cause: "PommeAgent couldn't read or write a file in the guest. The message gives the path and reason.",
              resolution: ["Check the path, its permissions, and the guest's free disk space."]),
        .init(.guestPermissionDenied, area: "Guest agent",
              title: "The guest denied permission.",
              cause: "macOS in the guest refused access to a file, directory, or executable.",
              resolution: ["Check the permissions of the path in the message, or run the operation as a user who has access."]),
        .init(.guestRemoteLoginFullDiskAccessRequired, area: "Guest agent",
              title: "Changing Remote Login needs Full Disk Access.",
              cause: "macOS lets a process change Remote Login only when it has Full Disk Access.",
              resolution: ["See [Enable remote access](/guides/enable-remote-access/)."]),
        .init(.guestRemoteLoginVerificationFailed, area: "Guest agent",
              title: "Pomme couldn't verify the Remote Login change.",
              cause: "The guest's Remote Login setting didn't match the requested value after the change.",
              resolution: ["Check Remote Login in the guest's Sharing settings, then retry."]),
        .init(.guestRecoveryOperationFailed, area: "Guest agent",
              title: "A Recovery operation in the guest failed.",
              cause: "The Pomme agent in macOS Recovery couldn't complete a security operation. The causes give its failure code.",
              resolution: ["Run `pomme sip status NAME` to see the VM's security state.", "Run `pomme bug-report NAME` and attach the file to a new issue."],
              reportable: true),
        .init(.guestFeatureUnsupported, area: "Guest agent",
              title: "The guest doesn't support the feature.",
              cause: "The installed PommeAgent doesn't support the feature.",
              resolution: ["Update the agent with `pomme agent update NAME`, or configure the feature in the guest."]),
        .init(.guestFileTransferFailed, area: "Guest agent",
              title: "The file transfer failed.",
              cause: "Copying a file between the host and the guest stopped partway. The message gives the reason and how many bytes were copied.",
              resolution: ["Read the reason in the message, then retry the copy."]),
        .init(.guestJobNotFound, area: "Guest agent",
              title: "The guest job doesn't exist.",
              cause: "No detached guest job has the ID that you gave. Jobs end when the guest restarts.",
              resolution: ["Run `pomme jobs list NAME` to see the VM's jobs."])
    ]
}
