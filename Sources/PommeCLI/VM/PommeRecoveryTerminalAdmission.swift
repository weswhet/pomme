import Darwin
import Foundation
@preconcurrency import Virtualization

/// Host-only Recovery navigation artifacts. This is intentionally separate
/// from guest-agent and provisioning data: the directory is a private,
/// retained diagnostic artifact, not guest protocol state or journal input.
struct PommeRecoveryDebugScreenshotMetadata: Equatable, Sendable {
    let directory: String?
    let files: [String]
    let warnings: [String]

    init(directory: String?, files: [String], warnings: [String]) {
        self.directory = directory
        self.files = files
        self.warnings = warnings
    }

    init?(recorder: PommeRecoveryNavigationScreenshotRecorder?) async {
        guard let recorder else { return nil }
        self.init(
            directory: await recorder.directory()?.path,
            files: await recorder.savedFiles().map(\.lastPathComponent),
            warnings: await recorder.warnings()
        )
    }

    var controlPayload: [String: Any] {
        var payload: [String: Any] = [
            "recoveryDebugScreenshotFiles": files,
            "recoveryDebugScreenshotWarnings": warnings,
        ]
        if let directory { payload["recoveryDebugScreenshotDirectory"] = directory }
        return payload
    }
}

/// Control responses normally carry terminal failures as a bounded JSON
/// result. Preserve host-only screenshot metadata on that existing route so
/// the invoking CLI can render it without extending PommeAgentProtocol or the
/// public output schema.
struct PommeRecoveryTerminalAdmissionControlFailure: Error, LocalizedError, Sendable {
    let message: String
    let debugMetadata: PommeRecoveryDebugScreenshotMetadata

    init(_ error: any Swift.Error, debugMetadata: PommeRecoveryDebugScreenshotMetadata) {
        message = error.localizedDescription
        self.debugMetadata = debugMetadata
    }

    var errorDescription: String? { message }
}

/// State captured by the ordinary-Recovery VSOCK listener before the first
/// terminal is admitted. The token is installed only after the host has
/// built and attached the exact request-bound staging share; it remains in
/// memory for the life of this Recovery helper and is never Codable.
final class PommeRecoveryTerminalAdmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var binding: PommeAgentVSOCKBinding?

    func install(token: String, binding: PommeAgentVSOCKBinding) {
        lock.withLock {
            self.token = token
            self.binding = binding
        }
    }

    func clear() {
        lock.withLock {
            token = nil
            binding = nil
        }
    }

    func secret(for role: PommeAgentVSOCKRole) throws -> String {
        guard role == .recoveryRuntime,
              let token = lock.withLock({ token })
        else { throw PommeAgentVSOCKError.missingBinding }
        return token
    }

    func sessionBinding(for role: PommeAgentVSOCKRole) throws -> PommeAgentVSOCKBinding {
        guard role == .recoveryRuntime,
              let binding = lock.withLock({ binding })
        else { throw PommeAgentVSOCKError.missingBinding }
        return binding
    }
}

/// The ordinary Recovery VM owns one empty, private, read-only share from
/// boot. Keeping the device present avoids mutating the VM configuration after
/// start; admission only swaps its host-side share to the request staging root
/// and clears it again after the terminal authority authenticates.
final class PommeRecoveryTerminalBootstrapShare: @unchecked Sendable {
    let rootURL: URL
    let deviceConfiguration: VZVirtioFileSystemDeviceConfiguration

    init(parentURL: URL, vmUUID: UUID) throws {
        let parent = parentURL.standardizedFileURL
        guard parent.path == parent.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw RunnerError.hostCommandFailed("Recovery terminal bootstrap storage is not stable.")
        }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        guard Self.privateDirectory(parent) else {
            throw RunnerError.hostCommandFailed("Recovery terminal bootstrap storage is not private.")
        }

        let name = "pomme-terminal-bootstrap-\(vmUUID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        let root = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        guard Self.privateDirectory(root),
              (try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)).isEmpty
        else {
            try? FileManager.default.removeItem(at: root)
            throw RunnerError.hostCommandFailed("Recovery terminal bootstrap storage is not empty.")
        }

        try VZVirtioFileSystemDeviceConfiguration.validateTag(
            PommeRecoveryStagingBuilder.terminalBootstrapTag
        )
        let device = VZVirtioFileSystemDeviceConfiguration(
            tag: PommeRecoveryStagingBuilder.terminalBootstrapTag
        )
        device.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: root, readOnly: true)
        )
        guard device.share != nil else {
            try? FileManager.default.removeItem(at: root)
            throw RunnerError.hostCommandFailed("Recovery terminal bootstrap share could not be created.")
        }
        rootURL = root
        deviceConfiguration = device
    }

    func removeHostRoot() throws {
        guard Self.privateDirectory(rootURL),
              (try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)).isEmpty
        else { throw RunnerError.hostCommandFailed("Recovery terminal bootstrap cleanup was not empty.") }
        guard Darwin.rmdir(rootURL.path) == 0 else {
            throw RunnerError.hostCommandFailed("Recovery terminal bootstrap cleanup failed.")
        }
    }

    private static func privateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
            && info.st_uid == geteuid()
            && info.st_mode & S_IFMT == S_IFDIR
            && info.st_mode & 0o777 == 0o700
            && url.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Virtualization references are confined to the runtime's queue. This
/// wrapper makes that ownership boundary explicit when the Recovery
/// admission actor is created under complete Swift 6 concurrency checking.
struct PommeRecoveryTerminalVirtualizationContext: @unchecked Sendable {
    let vm: VZVirtualMachine
    let configuration: VZVirtualMachineConfiguration
    let queue: DispatchQueue
}

/// Performs the one-time ordinary-Recovery terminal admission. Once the
/// launcher has authenticated, the host staging share is removed and this
/// actor retains only the coordinator/state needed for reconnects. The
/// terminal manager then owns all post-admission process and transcript state.
actor PommeRecoveryTerminalAdmission {
    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case unavailable
        case alreadyAttempted
        case launcherRejected
        case authenticationTimedOut
        case cleanupFailed

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Recovery terminal admission is unavailable."
            case .alreadyAttempted:
                "Recovery terminal admission has already been attempted."
            case .launcherRejected:
                "Recovery terminal bootstrap was rejected."
            case .authenticationTimedOut:
                "Recovery terminal authority did not authenticate in time."
            case .cleanupFailed:
                "Recovery terminal admission cleanup could not be proven complete."
            }
        }
    }

    private enum Phase { case idle, admitting, admitted, failed, cleaned }

    private let plan: PommeProvisioningPlan
    private let profileResolver: @Sendable () throws -> PommeRecoveryProfileEvidence
    private let vm: VZVirtualMachine
    private let configuration: VZVirtualMachineConfiguration
    private let queue: DispatchQueue
    private let coordinator: PommeAgentVSOCKCoordinator
    private let state: PommeRecoveryTerminalAdmissionState
    private let bootstrapShare: PommeRecoveryTerminalBootstrapShare
    private let executableResolver: @Sendable () throws -> URL
    private var phase: Phase = .idle
    private var staging: PommeRecoveryStaging?
    private var debugScreenshotRecorder: PommeRecoveryNavigationScreenshotRecorder?

    init(
        plan: PommeProvisioningPlan,
        profileResolver: @escaping @Sendable () throws -> PommeRecoveryProfileEvidence,
        virtualization: PommeRecoveryTerminalVirtualizationContext,
        coordinator: PommeAgentVSOCKCoordinator,
        state: PommeRecoveryTerminalAdmissionState,
        bootstrapShare: PommeRecoveryTerminalBootstrapShare,
        executableResolver: @escaping @Sendable () throws -> URL
    ) {
        self.plan = plan
        self.profileResolver = profileResolver
        self.vm = virtualization.vm
        self.configuration = virtualization.configuration
        self.queue = virtualization.queue
        self.coordinator = coordinator
        self.state = state
        self.bootstrapShare = bootstrapShare
        self.executableResolver = executableResolver
    }

    func ensure(
        sessionID: UUID,
        recoveryDebugScreenshots: Bool = false
    ) async throws -> PommeRecoveryDebugScreenshotMetadata? {
        switch phase {
        case .idle:
            break
        case .admitted:
            // This request did not drive Recovery navigation. In particular,
            // a later non-debug terminal must not receive another caller's
            // prior artifact directory.
            return nil
        case .admitting, .failed, .cleaned:
            throw Error.alreadyAttempted
        }
        phase = .admitting

        do {
            let profile = try profileResolver()
            let issuedAt = Date()
            let credential = try await PommeRecoveryCredentialIssuer.issue(
                lifetime: Self.admissionLifetime,
                now: issuedAt
            )
            let request = try PommeRecoverySessionRequest(
                requestID: sessionID,
                vmUUID: plan.vm.uuid,
                operation: .terminalSession,
                issuedAt: issuedAt,
                expiresAt: credential.expiresAt,
                executableSHA256: plan.recoveryAgent.executableDigest,
                payloadSHA256: PommeRecoveryCrypto.emptySHA256,
                requestedFinalState: .recovery,
                credential: credential
            )
            let executable = try executableResolver()
            let bootstrap = try PommeRecoveryVirtioFSBootstrapBuilder().build(
                .init(
                    request: request,
                    signedExecutableURL: executable,
                    credential: credential,
                    temporaryParentURL: bootstrapParentURL()
                )
            )
            staging = bootstrap.staging

            try bootstrap.staging.attachShare(to: vm, on: queue)
            let binding = PommeAgentVSOCKBinding(vmID: request.vmUUID, sessionID: request.requestID)
            state.install(
                token: String(decoding: credential.hexadecimalDataForStaging(), as: UTF8.self),
                binding: binding
            )

            var interaction = try PommeTahoeRecoveryInteraction(evidence: profile)
            let backend = VirtualizationPrivateHeadlessBackend(
                virtualMachine: vm,
                configuration: configuration,
                queue: queue
            )
            if recoveryDebugScreenshots {
                debugScreenshotRecorder = PommeRecoveryNavigationScreenshotRecorder(
                    vmName: plan.vm.name,
                    capture: { timeout in try await backend.recoveryFrame(timeout: timeout) }
                )
            } else {
                debugScreenshotRecorder = nil
            }
            let terminal = PommeRecoveryVirtualizationKeyboardPort(
                backend: backend,
                timeout: Constants.defaultRecoveryAgentTimeout,
                screenshotRecorder: debugScreenshotRecorder
            )
            let disposition = await interaction.driveToTerminalAndLaunch(
                using: terminal,
                capabilityProbes: bootstrap.terminalPlan.capabilityProbes,
                launcherCommand: bootstrap.terminalPlan.command
            )
            guard disposition == .terminalLauncherSubmitted else {
                throw Error.launcherRejected
            }
            try await waitForAuthentication()

            try bootstrap.staging.clearShare(from: vm, on: queue)
            try bootstrap.staging.removeHostArtifacts()
            staging = nil
            phase = .admitted
            return await PommeRecoveryDebugScreenshotMetadata(recorder: debugScreenshotRecorder)
        } catch {
            let cleanupComplete = await abandonAdmission()
            let outcome: any Swift.Error = cleanupComplete ? error : PommeRecoveryTerminalAdmission.Error.cleanupFailed
            if let debugMetadata = await PommeRecoveryDebugScreenshotMetadata(recorder: debugScreenshotRecorder) {
                throw PommeRecoveryTerminalAdmissionControlFailure(outcome, debugMetadata: debugMetadata)
            }
            if let admissionError = outcome as? PommeRecoveryTerminalAdmission.Error {
                throw admissionError
            }
            throw Error.unavailable
        }
    }

    func cleanup() async -> Bool {
        guard phase != .cleaned else { return true }
        var complete = true
        if let staging {
            do {
                try staging.clearShare(from: vm, on: queue)
                try staging.removeHostArtifacts()
                self.staging = nil
            } catch {
                complete = false
            }
        }
        state.clear()
        do {
            try bootstrapShare.removeHostRoot()
        } catch {
            complete = false
        }
        phase = complete ? .cleaned : .failed
        return complete
    }

    private func abandonAdmission() async -> Bool {
        let complete = await cleanup()
        coordinator.teardown()
        if !complete { phase = .failed }
        return complete
    }

    private func waitForAuthentication() async throws {
        let deadline = Date().addingTimeInterval(Constants.defaultRecoveryAgentTimeout)
        while Date() < deadline {
            if coordinator.isAuthenticated(as: .recoveryRuntime) { return }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw Error.authenticationTimedOut
    }

    private func bootstrapParentURL() throws -> URL {
        try applicationSupportRoot(create: true)
            .appendingPathComponent("RecoveryStaging", isDirectory: true)
    }

    private static let admissionLifetime: TimeInterval = 5 * 60
}
