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
    case memoryOutsideHostLimits(requested: UInt64, minimum: UInt64, maximum: UInt64)
    case backgroundStartFailed(status: Int32, logURL: URL)
    case backgroundStartTimedOut(pid: Int32, logURL: URL)
    case invalidVMName(String)
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
    case invalidControlResponse(String)
    case incompatibleHelperProtocol(expected: Int, actual: Int?)
    case controlCapabilityUnavailable(String)
    case unsafeHelperTermination(String)
    case guestFileTransferFailed(primary: String, transferredBytes: UInt64, cleanupErrors: [String])
    case guestJobNotFound(String)
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
            PommeHelp.text(.primary)
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
        case .memoryOutsideHostLimits(let requested, let minimum, let maximum):
            "The configured RAM \(byteCountText(requested)) is outside this host's supported range \(byteCountText(minimum))...\(byteCountText(maximum))."
        case .backgroundStartFailed(let status, let logURL):
            "The VM helper exited during startup with status \(status). See \(logURL.path)."
        case .backgroundStartTimedOut(let pid, let logURL):
            "Timed out waiting for VM helper pid \(pid) to open its control socket. See \(logURL.path)."
        case .invalidVMName(let name):
            "Invalid VM name \(name). Use 1-64 ASCII letters, numbers, dots, underscores, or hyphens, starting with a letter or number."
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
enum PommeHelpPage {
    case primary, tui, tools, agentHelp, create, config, vm, guest, files, mdm, ui, security, ipsw
}

enum PommeHelp {
    static func text(_ page: PommeHelpPage) -> String {
        switch page {
        case .primary:
            """
            pomme 0.1.0 — create and control Pomme-owned macOS virtual machines

            Usage: pomme <command> [options]

            Commands:
              create, list, start, stop, restart, pause, resume, delete
              status, inspect, exec, shell, jobs, cp, cat, agent
              sip, amfi, mdm, remote-login, screen-sharing, snapshot, config, ipsw, ui, tui

            Run `pomme <command> --help` for command-specific help.
            """
        case .tui:
            "Usage: pomme tui"
        case .tools:
            "Usage: pomme tools [--format table|json|jsonl|raw]"
        case .agentHelp:
            "pomme-agent-help v1; targets are positional; env=POMME_VM_NAME; agent=status|repair; snapshot=create|list|restore|delete"
        case .create:
            "Usage: pomme create NAME (--version SELECTOR|--restore-image PATH) [--boot none|normal|recovery]\n       pomme create NAME --resume"
        case .config:
            "Usage: pomme config init|validate|render ..."
        case .vm:
            "Usage: pomme start|stop|restart|pause|resume|status|inspect|delete NAME"
        case .guest:
            "Usage: pomme exec NAME -- COMMAND [ARGS...]\n       pomme shell NAME EXPRESSION\n       pomme jobs <action> NAME"
        case .files:
            "Usage: pomme cp SOURCE DESTINATION\n       pomme cat NAME:/absolute/path"
        case .mdm:
            "Usage: pomme mdm NAME --profile PATH [--enrollment-mode supervised|unapproved]"
        case .ui:
            "Usage: pomme ui <action> NAME"
        case .security:
            "Usage: pomme sip|amfi <status|enable|disable> NAME [--final-state STATE]"
        case .ipsw:
            "Usage: pomme ipsw list|download ..."
        }
    }
}
