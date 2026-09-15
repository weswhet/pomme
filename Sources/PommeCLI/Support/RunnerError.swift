import Foundation
import Darwin

enum RunnerError: LocalizedError {
    case usage
    case unsupportedHost
    case noSupportedConfiguration
    case restoreImageNeedsDownload
    case tuiRequiresInteractiveTerminal
    case downloadFailed(statusCode: Int)
    case invalidSize(flag: String, value: String)
    case memoryBelowGuestMinimum(requested: UInt64, minimum: UInt64)
    case memoryBelowProvisionalFloor(requested: UInt64, minimum: UInt64)
    case memoryOutsideHostLimits(requested: UInt64, minimum: UInt64, maximum: UInt64)
    case backgroundStartFailed(status: Int32, logURL: URL)
    case backgroundStartTimedOut(pid: Int32, logURL: URL)
    case invalidIdentifier(kind: PommeIdentifierKind, value: String)
    case missingVMNameForCreate
    case bundleCreateUnsupported
    case namedVMNotFound(String)
    case noDefaultRunningVM
    case ambiguousVMSelection([VMReference])
    case missingBundleFile(String)
    case vmDestroyRequiresNamedVM
    case vmDestroyConfirmationMismatch(String)
    case invalidHardwareModel
    case unsupportedHardwareModel
    case invalidMachineIdentifier
    case noRunningVM(URL)
    case controlCommandFailed(String)
    case invalidControlCommand(String)
    case socketPathTooLong(String)
    case posix(function: String, code: Int32)
    case virtualMachineState(String)
    case guestAgentProbeTimedOut
    case invalidGuestCommand(String)
    case guestAgentUnavailable
    case guestAgentDisconnected
    case guestAgentTimedOut(String)
    case guestAgentError(String)
    case guestAgentProtocol(String)
    case guestScreenSharingUnavailable
    case invalidControlResponse(String)
    case incompatibleHelperProtocol(expected: Int, actual: Int?)
    case controlCapabilityUnavailable(String)
    case unsafeHelperTermination(String)
    case guestFileTransferFailed(primary: String, transferredBytes: UInt64, cleanupErrors: [String])
    case guestJobNotFound(String)
    case snapshotNotFound(vm: String, name: String)
    case invalidDockerCommand(String)
    case invalidUICommand(String)
    case invalidCopyEndpoint(String)
    case unsupportedCopy(String)
    case hostCommandFailed(String)
    case runningVMBlocksRecovery(VMReference)
    case missingSIPPassword
    case invalidSIPBootstrapConfiguration(String)
    case sipCredentialUnavailable(String)
    case keychainError(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "The arguments are not valid. Run 'pomme --help' for usage."
        case .unsupportedHost:
            "Virtualization.framework is not available on this host."
        case .noSupportedConfiguration:
            "The restore image has no supported configuration for this host."
        case .restoreImageNeedsDownload:
            "The selected restore image is remote. Download it first or pass --restore-image."
        case .tuiRequiresInteractiveTerminal:
            "TUI requires an interactive terminal. Use --help for non-interactive usage."
        case .downloadFailed(let statusCode):
            "The restore image download failed with HTTP \(statusCode)."
        case .invalidSize(let flag, let value):
            "\(flag) requires a positive size such as 60GB, 8192MB, or a raw byte count. Got \(value)."
        case .memoryBelowGuestMinimum(let requested, let minimum):
            "The configured RAM \(byteCountText(requested)) is below the guest minimum \(byteCountText(minimum))."
        case .memoryBelowProvisionalFloor(let requested, let minimum):
            "The configured RAM \(byteCountText(requested)) is below the provisional guest minimum \(byteCountText(minimum)). The restore image's exact minimum is enforced once the image is present; no supported image needs less."
        case .memoryOutsideHostLimits(let requested, let minimum, let maximum):
            "The configured RAM \(byteCountText(requested)) is outside this host's supported range \(byteCountText(minimum))...\(byteCountText(maximum))."
        case .backgroundStartFailed(let status, let logURL):
            "The VM helper exited during startup with status \(status). See \(logURL.path)."
        case .backgroundStartTimedOut(let pid, let logURL):
            "Timed out waiting for VM helper pid \(pid) to open its control socket. See \(logURL.path)."
        case .invalidIdentifier(let kind, let value):
            "Invalid \(kind.rawValue) \(value). Use 1-64 ASCII letters, numbers, dots, underscores, or hyphens, starting with a letter or number."
        case .missingVMNameForCreate:
            "Direct creation requires a VM name: `pomme create <name>`."
        case .bundleCreateUnsupported:
            "An existing VM bundle cannot be a creation target. Use `pomme create <name>`."
        case .namedVMNotFound(let name):
            "No Pomme-owned VM named \(name) exists. Create it with `pomme create \(name)` or run `pomme list`."
        case .noDefaultRunningVM:
            "Specify a VM name or set POMME_VM_NAME."
        case .ambiguousVMSelection(let references):
            "Specify a VM name. Running VMs: \(vmReferenceListText(references))."
        case .missingBundleFile(let name):
            "The VM bundle is missing \(name)."
        case .vmDestroyRequiresNamedVM:
            "Only a verified Pomme-owned VM can be deleted."
        case .vmDestroyConfirmationMismatch(let name):
            "Deletion confirmation did not match \(name)."
        case .invalidHardwareModel:
            "The VM bundle has an invalid hardware model."
        case .unsupportedHardwareModel:
            "The VM bundle's hardware model is unsupported on this host."
        case .invalidMachineIdentifier:
            "The VM bundle has an invalid machine identifier."
        case .noRunningVM(let socketURL):
            "No running VM helper is listening at \(socketURL.path). Start it with `pomme start <name>`."
        case .controlCommandFailed(let response):
            "The running VM helper rejected the command: \(response)"
        case .invalidControlCommand(let command):
            "Unknown control command: \(command)"
        case .socketPathTooLong(let path):
            "The control socket path is too long: \(path)"
        case .posix(let function, let code):
            "\(function) failed: \(String(cString: strerror(code)))"
        case .virtualMachineState(let message), .invalidGuestCommand(let message),
             .invalidDockerCommand(let message), .invalidUICommand(let message),
             .unsupportedCopy(let message), .hostCommandFailed(let message):
            message
        case .guestAgentProbeTimedOut:
            "Timed out connecting to PommeAgent."
        case .guestAgentUnavailable:
            "PommeAgent is not connected on port \(Constants.pommeAgentPort)."
        case .guestAgentDisconnected:
            "The authenticated agent connection closed before a response arrived."
        case .guestAgentTimedOut(let operation):
            "Timed out waiting for agent operation \(operation)."
        case .guestAgentError(let message):
            "Agent error: \(message)"
        case .guestAgentProtocol(let message):
            "PommeAgentProtocol error: \(message)"
        case .guestScreenSharingUnavailable:
            "Screen Sharing is unavailable through Pomme because this guest agent does not support it. Configure it in the guest’s Sharing settings instead."
        case .invalidControlResponse(let response):
            "The VM helper returned an invalid response: \(response)"
        case .incompatibleHelperProtocol(let expected, let actual):
            if let actual {
                "The VM helper uses unsupported control protocol v\(actual); version \(expected) is required. Restart the helper."
            } else {
                "The VM helper did not identify PommeControlProtocol v\(expected). Restart the helper."
            }
        case .controlCapabilityUnavailable(let capability):
            "The VM helper does not advertise required capability `\(capability)`."
        case .unsafeHelperTermination(let reason):
            "Refusing to terminate the helper because its identity could not be verified: \(reason)"
        case .guestFileTransferFailed(let primary, let transferredBytes, let cleanupErrors):
            if cleanupErrors.isEmpty {
                "Guest file transfer failed after \(transferredBytes) bytes: \(primary)"
            } else {
                "Guest file transfer failed after \(transferredBytes) bytes: \(primary). Cleanup errors: \(cleanupErrors.joined(separator: "; "))"
            }
        case .guestJobNotFound(let jobID):
            "No detached guest job exists with id \(jobID)."
        case .snapshotNotFound(let vm, let name):
            "No snapshot named \(name) exists for \(vm)."
        case .invalidCopyEndpoint(let endpoint):
            "Invalid copy endpoint: \(endpoint)"
        case .runningVMBlocksRecovery(let reference):
            "Stop \(reference.displayName) before starting a Recovery transaction."
        case .missingSIPPassword:
            "The SIP workflow requires a configured Keychain or environment credential, or a secure interactive prompt."
        case .invalidSIPBootstrapConfiguration(let message), .sipCredentialUnavailable(let message):
            message
        case .keychainError(let message):
            "Host Keychain error: \(message)"
        }
    }
}
