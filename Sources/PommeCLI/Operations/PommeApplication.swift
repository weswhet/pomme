import CryptoKit
import Darwin
import Foundation

struct PommeOperationResult: Sendable {
    let title: String
    let vmName: String?
    let ok: Bool
    let hostExitCode: Int32
    let text: String
    private var payloadValue: [String: JSONValue]

    var payload: [String: Any] {
        get { payloadValue.mapValues(\.publicValue) }
        set { payloadValue = Self.convertPayload(newValue) }
    }

    init(
        title: String,
        vmName: String?,
        ok: Bool,
        hostExitCode: Int32,
        text: String,
        payload: [String: Any]
    ) {
        self.title = title
        self.vmName = vmName
        self.ok = ok
        self.hostExitCode = hostExitCode
        self.text = text
        self.payloadValue = Self.convertPayload(payload)
    }

    private static func convertPayload(_ payload: [String: Any]) -> [String: JSONValue] {
        do {
            return try payload.mapValues(JSONValue.init(any:))
        } catch {
            preconditionFailure("Public output payload was not JSON-safe: \(error.localizedDescription)")
        }
    }
}

private actor PommeMDMRestorationProof {
    private var securityMatched = false

    func recordSecurityMatch() { securityMatched = true }
    func isSecurityMatched() -> Bool { securityMatched }
}

enum PommeApplication {
    private static let provisioningServicesLock = NSLock()
    nonisolated(unsafe) private static var provisioningServices = makeProvisioningServices()
    private static let recoveryIntegrationLock = NSLock()
    nonisolated(unsafe) private static var recoveryIntegrationFactory: PommeRecoveryIntegrationFactory?

    static func installProvisioningServices(_ services: PommeProvisioningApplicationServices) {
        provisioningServicesLock.lock()
        provisioningServices = services
        provisioningServicesLock.unlock()
    }

    /// Installs the production Core bridge explicitly at process startup.
    /// Tests may replace it with a deterministic service without bypassing the
    /// immutable plan and journal owned by PommeCore.
    static func installDefaultProvisioningServices() {
        installProvisioningServices(makeProvisioningServices())
    }

    /// Installs the per-request Recovery factory used by SIP, AMFI, and
    /// Recovery-only repair/install operations. A fixed session cannot be a
    /// production dependency because its credential is single-use and bound
    /// to one immutable VM/operation tuple.
    static func installRecoveryIntegrationFactory(_ factory: PommeRecoveryIntegrationFactory?) {
        recoveryIntegrationLock.lock()
        recoveryIntegrationFactory = factory
        recoveryIntegrationLock.unlock()
        let adapter: (@Sendable (PommeProvisioningPlan, PommeProvisioningFinalState) async throws -> String)?
        if let factory {
            adapter = { plan, finalState in
                try await executeProvisioningRecovery(
                    factory: factory,
                    plan: plan,
                    finalState: finalState
                )
            }
        } else {
            adapter = nil
        }
        PommeCore.installProvisioningRecoveryAdapter(adapter)
    }

    /// Compatibility seam for deterministic tests. Production bootstrap must
    /// install a factory so every invocation receives a fresh credential.
    static func installRecoveryIntegration(_ integration: PommeRecoveryIntegration?) {
        installRecoveryIntegrationFactory(integration.map(PommeRecoveryIntegrationFactory.fixed))
    }

    private static func currentRecoveryIntegrationFactory() throws -> PommeRecoveryIntegrationFactory {
        recoveryIntegrationLock.lock()
        defer { recoveryIntegrationLock.unlock() }
        guard let recoveryIntegrationFactory else {
            throw PommeProvisioningError.unavailableIntegration("authenticated Recovery session")
        }
        return recoveryIntegrationFactory
    }

    /// Bridges the immutable provisioning plan to the request-bound Recovery
    /// integration.  The plan is the complete payload: it contains no
    /// credential material, and the Recovery adapter is responsible for
    /// authenticating the one-shot request before touching the guest.
    private static func executeProvisioningRecovery(
        factory: PommeRecoveryIntegrationFactory,
        plan: PommeProvisioningPlan,
        finalState: PommeProvisioningFinalState
    ) async throws -> String {
        let requestedFinalState: VMFinalState
        switch finalState {
        case .stopped:
            requestedFinalState = .stopped
        case .normalRunning:
            requestedFinalState = .normal
        case .recoveryRunning:
            requestedFinalState = .recovery
        }

        let payload = try PommeProvisioningCoding.encode(plan)
        let reference = VMReference(
            name: plan.vm.name,
            bundle: BundleLayout(rootURL: URL(fileURLWithPath: plan.vm.bundlePath))
        )
        let integration = try await factory.make(
            reference: reference,
            operation: .installAgent
        )
        let execution = try await integration.installAgent(
            payload: payload,
            finalState: requestedFinalState
        )
        let evidence = execution.evidence
        guard evidence.authenticated,
              evidence.requestBound,
              evidence.credentialConsumed,
              evidence.vmUUID == plan.vm.uuid,
              evidence.listenerPort == PommeRecoveryListenerPort.bootstrap.rawValue,
              evidence.lifecycle == .finalized,
              execution.cleanup.isComplete,
              execution.finalState == requestedFinalState
        else {
            throw PommeProvisioningError.unavailableIntegration(
                "verified request-bound Recovery agent installation"
            )
        }

        let installed: [String: JSONValue]
        do {
            guard let object = try JSONDecoder().decode(
                JSONValue.self,
                from: execution.output
            ).objectValue else {
                throw PommeProvisioningError.unavailableIntegration(
                    "verified Recovery agent installation receipt"
                )
            }
            installed = object
        } catch let error as PommeProvisioningError {
            throw error
        } catch {
            throw PommeProvisioningError.unavailableIntegration(
                "verified Recovery agent installation receipt"
            )
        }
        guard Set(installed.keys) == ["executableSHA256", "volumeGroupUUID", "capabilities"],
              installed["executableSHA256"]?.stringValue == plan.normalAgent.executableDigest,
              let rawVolumeGroup = installed["volumeGroupUUID"]?.stringValue,
              let volumeGroupUUID = UUID(uuidString: rawVolumeGroup),
              rawVolumeGroup == volumeGroupUUID.uuidString.lowercased(),
              let capabilities = installed["capabilities"]?.arrayValue?.compactMap(\.stringValue),
              PommeCore.supportsProvisioningAgentCapabilities(capabilities)
        else {
            throw PommeProvisioningError.unavailableIntegration(
                "verified Recovery agent installation receipt"
            )
        }
        try PommeCore.persistProvisioningStartupVolumeGroup(volumeGroupUUID, for: plan)

        var receipt = Data("pomme-recovery-agent-v1".utf8)
        receipt.append(payload)
        receipt.append(execution.output)
        return PommeProvisioningDigest.sha256(receipt)
    }

    private static func makeProvisioningServices() -> PommeProvisioningApplicationServices {
        .init(
            resume: { name in
                try await VMBundleMutationLease.withLease(name: name) { lease in
                    try await PommeCore.resumeProvisioning(name: name, lease: lease)
                }
            },
            agentStatus: { name in try await PommeCore.provisioningAgentStatus(name: name) },
            agentRepair: { name, finalState in
                try await VMBundleMutationLease.withLease(name: name) { lease in
                    try await PommeCore.repairProvisioning(
                        name: name,
                        finalState: finalState,
                        lease: lease
                    )
                }
            }
        )
    }

    static func createResume(name: String) async throws -> PommeOperationResult {
        try await currentProvisioningServices().resume(try validateVMName(name))
    }

    static func agentStatus(name: String) async throws -> PommeOperationResult {
        let validatedName = try validateVMName(name)
        let status = try await currentProvisioningServices().agentStatus(validatedName)
        return .init(
            title: "Agent Status",
            vmName: validatedName,
            ok: true,
            hostExitCode: 0,
            text: "OK agent=\(status.connection.rawValue) role=\(status.role.rawValue)",
            payload: [
                "ok": true,
                "name": validatedName,
                "guestAgent": [
                    "connection": status.connection.rawValue,
                    "role": status.role.rawValue,
                    "protocolVersion": status.protocolVersion,
                    "executableDigest": status.executableDigest,
                    "capabilities": status.capabilities,
                    "updateState": status.updateState
                ],
                "hostExitCode": 0
            ]
        )
    }

    static func agentRepair(name: String, finalState: String) async throws -> PommeOperationResult {
        guard finalState == PommeAgentRepairFinalState.previous.rawValue else {
            throw PommeProvisioningError.unavailableIntegration("agent repair final state")
        }
        return try await currentProvisioningServices().agentRepair(try validateVMName(name), .previous)
    }

    private static func currentProvisioningServices() -> PommeProvisioningApplicationServices {
        provisioningServicesLock.lock()
        defer { provisioningServicesLock.unlock() }
        return provisioningServices
    }

    static func namedReference(_ name: String, requireExists: Bool = true) throws -> VMReference {
        try namedVMReference(name, requireExists: requireExists)
    }

    static func listVMsPayload() throws -> [String: Any] {
        try PommeCore.listVMsPayload()
    }

    static func status(name: String) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        let payload = try PommeCore.vmStatusPayload(reference: reference)
        return result(title: "Status", reference: reference, payload: payload, text: formatStatus(payload))
    }

    static func inspect(name: String) throws -> PommeOperationResult {
        let reference = try namedReference(name, requireExists: false)
        let payload = try PommeCore.vmInspectPayload(reference: reference)
        return result(title: "Inspect", reference: reference, payload: payload, text: formatInspect(payload))
    }

    static func health(name: String) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        let payload = try PommeCore.vmHealthPayload(reference: reference)
        return result(title: "Health", reference: reference, payload: payload, text: formatHealth(payload))
    }

    static func capabilities(name: String) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        let payload = try PommeCore.vmCapabilitiesPayload(reference: reference)
        return result(title: "Capabilities", reference: reference, payload: payload, text: formatCapabilities(payload))
    }

    static func stop(name: String, force: Bool = false, lease: VMBundleMutationLease? = nil) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name, inherited: lease) { _ in
        let reference = try namedReference(name)
        let statusPayload = try PommeCore.vmStatusPayload(reference: reference)
        if statusPayload["helperRunning"] as? Bool != true {
            var payload = statusPayload
            payload["ok"] = true
            payload["operation"] = "stop"
            payload["hostExitCode"] = 0
            payload["forceRequested"] = force
            payload["response"] = "VM is already stopped."
            return result(
                title: "Stop",
                reference: reference,
                payload: payload,
                text: "VM is already stopped."
            )
        }
        let payload = try PommeCore.controlCommandPayload(force ? .forceStop : .stop, reference: reference)
        var resultPayload = payload
        resultPayload["forceRequested"] = force
        return result(title: "Stop", reference: reference, payload: resultPayload, text: stringValue(payload["response"]))
        }
    }

    static func pause(name: String, lease: VMBundleMutationLease? = nil) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name, inherited: lease) { _ in
        let reference = try namedReference(name)
        let payload = try PommeCore.controlCommandPayload(.pause, reference: reference)
        return result(title: "Pause", reference: reference, payload: payload, text: stringValue(payload["response"]))
        }
    }

    static func resume(name: String, lease: VMBundleMutationLease? = nil) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name, inherited: lease) { _ in
        let reference = try namedReference(name)
        let payload = try PommeCore.controlCommandPayload(.resume, reference: reference)
        return result(title: "Resume", reference: reference, payload: payload, text: stringValue(payload["response"]))
        }
    }

    // MARK: - Named snapshots

    static func snapshotsList(name: String) throws -> [VMSnapshotRecord] {
        let reference = try namedReference(name)
        return try VMSnapshotStore.list(bundle: reference.bundle)
    }

    static func snapshotCreate(name: String, snapshot: String) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name) { lease in
            let reference = try namedReference(name)
            guard try !VMSecurityStateStore(bundle: reference.bundle).hasState() else {
                throw RunnerError.virtualMachineState("Snapshots are unavailable while a SecurityState transaction is active.")
            }
            let status = try vmStatusForSnapshot(reference: reference)
            let state = stringValue(status["vmState"])
            let mode = BootMode(rawValue: stringValue(status["bootMode"]))
            guard mode == .normal, (state == "running" || state == "paused") else {
                throw RunnerError.virtualMachineState("Snapshot creation requires a running or paused normal macOS VM.")
            }
            let didPause = state == "running"
            let stage = try VMSnapshotStore.prepare(bundle: reference.bundle, name: snapshot)
            var pausedForCapture = false
            do {
                if didPause {
                    _ = try pause(name: name, lease: lease)
                    pausedForCapture = true
                }
                _ = try PommeCore.sendControlObject([
                    "command": "snapshot-save",
                    "stageName": stage.lastPathComponent
                ], bundle: reference.bundle)
                let record = try VMSnapshotStore.complete(
                    bundle: reference.bundle, name: snapshot, stage: stage,
                    sourceState: didPause ? "running" : "paused"
                )
                if didPause {
                    _ = try resume(name: name, lease: lease)
                    pausedForCapture = false
                }
                let payload: [String: Any] = [
                    "ok": true, "operation": "snapshot-create", "name": name,
                    "snapshot": snapshotPayload(record), "bundlePath": reference.bundle.rootURL.path,
                    "hostExitCode": 0
                ]
                return result(title: "Snapshot Create", reference: reference, payload: payload,
                              text: "Created snapshot \(record.name).")
            } catch {
                try? FileManager.default.removeItem(at: stage)
                if pausedForCapture {
                    do {
                        _ = try resume(name: name, lease: lease)
                    } catch let resumeError {
                        throw RunnerError.virtualMachineState(
                            "Snapshot creation failed and the original running state could not be restored: \(error.localizedDescription); resume: \(resumeError.localizedDescription)"
                        )
                    }
                }
                throw error
            }
        }
    }

    static func snapshotRestore(name: String, snapshot: String, allowDrift: Bool = false) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name) { lease in
            let reference = try namedReference(name)
            guard try !VMSecurityStateStore(bundle: reference.bundle).hasState() else {
                throw RunnerError.virtualMachineState("Snapshots are unavailable while a SecurityState transaction is active.")
            }
            let status = try vmStatusForSnapshot(reference: reference)
            let mode = BootMode(rawValue: stringValue(status["bootMode"]))
            guard mode != .recovery else { throw RunnerError.virtualMachineState("Cannot restore a snapshot while booted in macOS Recovery.") }
            let manifest = try VMSnapshotStore.manifest(bundle: reference.bundle, name: snapshot)
            let drift = try VMSnapshotStore.drift(bundle: reference.bundle, manifest: manifest)
            let identityDrift = drift.filter { ["vmUUID", "configuration", "hardwareModel", "machineIdentifier"].contains($0) }
            guard identityDrift.isEmpty else {
                throw RunnerError.virtualMachineState("Snapshot configuration identity mismatch: \(identityDrift.joined(separator: ", ")).")
            }
            guard allowDrift || drift.isEmpty else {
                throw RunnerError.virtualMachineState("Snapshot drift detected: \(drift.joined(separator: ", ")). Re-run with explicit drift authorization.")
            }
            let priorState = stringValue(status["vmState"])
            let helperWasRunning = status["helperRunning"] as? Bool == true
            guard !helperWasRunning || priorState == "running" || priorState == "paused" else {
                throw RunnerError.virtualMachineState("Snapshot restore requires a stable running, paused, or stopped VM state.")
            }
            var rollback: URL?
            var rollbackCaptured = false
            var pausedForRollbackCapture = false
            var helperStopped = !helperWasRunning
            do {
                if helperWasRunning {
                    rollback = try VMSnapshotStore.prepareRollback(bundle: reference.bundle)
                    if priorState == "running" {
                        _ = try pause(name: name, lease: lease)
                        pausedForRollbackCapture = true
                    }
                    _ = try PommeCore.sendControlObject([
                        "command": "snapshot-save",
                        "stageName": rollback!.lastPathComponent
                    ], bundle: reference.bundle)
                    rollbackCaptured = true
                    _ = try stop(name: name, force: true, lease: lease)
                    helperStopped = true
                    pausedForRollbackCapture = false
                }
                try VMSnapshotStore.installMachineState(bundle: reference.bundle, name: snapshot)
                _ = try PommeCore.startRequiredSnapshotRestorePayload(reference: reference)
                if let rollback { try? FileManager.default.removeItem(at: rollback) }
                let payload: [String: Any] = [
                    "ok": true, "operation": "snapshot-restore", "name": name,
                    "snapshot": snapshotPayload(manifest.record), "drift": drift,
                    "finalState": "paused", "hostExitCode": 0
                ]
                return result(title: "Snapshot Restore", reference: reference, payload: payload,
                              text: "Restored snapshot \(snapshot); VM is paused.")
            } catch let restoreError {
                if !helperStopped {
                    if pausedForRollbackCapture {
                        do {
                            _ = try resume(name: name, lease: lease)
                        } catch let resumeError {
                            throw RunnerError.virtualMachineState(
                                "Snapshot restore failed before stopping the original VM, and its running state could not be restored: \(restoreError.localizedDescription); resume: \(resumeError.localizedDescription)"
                            )
                        }
                    }
                    if let rollback { try? FileManager.default.removeItem(at: rollback) }
                    throw restoreError
                }

                do {
                    // A named helper may have reached paused state before a
                    // later host-side failure. Prove it stopped before either
                    // cleanup or rollback installation.
                    _ = try stop(name: name, force: true, lease: lease)
                    try VMSnapshotStore.removeRequiredRestoreArtifacts(bundle: reference.bundle)
                    if let rollback, rollbackCaptured {
                        try VMSnapshotStore.installRollbackMachineState(bundle: reference.bundle, stage: rollback)
                        _ = try PommeCore.startRequiredSnapshotRestorePayload(reference: reference)
                        if priorState == "running" {
                            _ = try resume(name: name, lease: lease)
                        }
                        try FileManager.default.removeItem(at: rollback)
                    } else if let rollback {
                        try FileManager.default.removeItem(at: rollback)
                    }
                } catch let rollbackError {
                    throw RunnerError.virtualMachineState(
                        "Snapshot restore failed and rollback could not be proven; retained recovery artifacts must be inspected before reuse: \(restoreError.localizedDescription); rollback: \(rollbackError.localizedDescription)"
                    )
                }
                throw restoreError
            }
        }
    }

    static func snapshotDelete(name: String, snapshot: String) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name) { _ in
            let reference = try namedReference(name)
            try VMSnapshotStore.delete(bundle: reference.bundle, name: snapshot)
            let payload: [String: Any] = ["ok": true, "operation": "snapshot-delete", "name": name, "snapshot": snapshot, "hostExitCode": 0]
            return result(title: "Snapshot Delete", reference: reference, payload: payload,
                          text: "Deleted snapshot \(snapshot).")
        }
    }

    private static func vmStatusForSnapshot(reference: VMReference) throws -> [String: Any] {
        let status = try PommeCore.vmStatusPayload(reference: reference)
        guard status["ok"] as? Bool != false else {
            throw RunnerError.virtualMachineState(stringValue(status["error"]))
        }
        return status
    }

    private static func snapshotPayload(_ record: VMSnapshotRecord) -> [String: Any] {
        [
            "name": record.name, "createdAt": ISO8601DateFormatter().string(from: record.createdAt),
            "sourceState": record.sourceState, "drift": record.drift,
            "machineStateBytes": record.machineStateBytes, "diskBytes": record.diskBytes,
            "auxiliaryStorageBytes": record.auxiliaryStorageBytes
        ]
    }

    static func boot(name: String, mode: BootMode, options: CLIOptions = CLIOptions(), lease: VMBundleMutationLease? = nil) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name, inherited: lease) { _ in
        let reference = try namedReference(name)
        let payload = try PommeCore.stopAndStartPayload(
            reference: reference,
            bootMode: mode,
            user: options.sipUser,
            password: options.sipPassword,
            bootstrapOptions: options.sipBootstrap,
            timeout: options.timeout,
            debug: options.debug
        )
        return result(title: mode == .normal ? "Start Normal" : "Boot Recovery", reference: reference, payload: payload, text: formatBoot(payload))
        }
    }

    static func restart(
        name: String,
        mode: BootMode?,
        options: CLIOptions = CLIOptions(),
        lease: VMBundleMutationLease? = nil
    ) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name, inherited: lease) { scope in
        let statusResult = try status(name: name)
        let statusMode = BootMode(rawValue: stringValue(statusResult.payload["bootMode"])) ?? .normal
        let selectedMode = mode ?? statusMode
        let stopResult = try stop(name: name, lease: scope)
        let bootResult = try boot(name: name, mode: selectedMode, options: options, lease: scope)

        var payload = bootResult.payload
        payload["operation"] = "restart"
        payload["preservedMode"] = mode == nil
        payload["steps"] = [statusResult.payload, stopResult.payload, bootResult.payload]
        return result(
            title: "Restart",
            reference: try namedReference(name),
            payload: payload,
            text: formatBoot(payload)
        )
        }
    }

    static func destroy(name: String) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        let payload = try PommeCore.destroyVMPayload(reference: reference, confirmation: name)
        return result(title: "Destroy", reference: reference, payload: payload, text: "OK destroyed name=\(name) bundle=\(stringValue(payload["bundlePath"]))")
    }

    static func detailedInspect(name: String) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        let inspectPayload = try PommeCore.vmInspectPayload(reference: reference)
        let healthPayload = try PommeCore.vmHealthPayload(reference: reference)
        let capabilitiesPayload: [String: Any]
        do {
            capabilitiesPayload = try PommeCore.vmCapabilitiesPayload(reference: reference)
        } catch {
            capabilitiesPayload = [
                "ok": true,
                "available": false,
                "capabilities": [],
                "detail": "Guest capabilities are available while the VM is running.",
                "unavailableReason": error.localizedDescription
            ]
        }

        var payload = inspectPayload
        payload["health"] = healthPayload
        payload["capabilities"] = capabilitiesPayload
        // A stopped VM is still fully inspectable from its persisted bundle. Health and
        // guest capabilities remain diagnostics in that state rather than turning an
        // otherwise successful inspection into a failure.
        payload["ok"] = inspectPayload["ok"] as? Bool ?? true

        let text = [
            formatInspect(inspectPayload),
            formatHealth(healthPayload),
            formatCapabilities(capabilitiesPayload)
        ].joined(separator: "\n")
        return result(title: "Inspect", reference: reference, payload: payload, text: text)
    }

    static func foregroundCommand(
        name: String,
        request: GuestCommandRequest
    ) throws -> PommeOperationResult {
        try VMBundleMutationLease.withLease(name: name) { _ in
        let reference = try namedReference(name)
        var payload = try request.pty
            ? PommeCore.sendControlObject(request.controlPayload, bundle: reference.bundle)
            : PommeCore.sendForegroundControlObject(request.controlPayload, bundle: reference.bundle)
        payload["operation"] = "process.start"
        payload["name"] = name
        let ok = payload["ok"] as? Bool == true
        let text = agentResponseText(payload)
        return result(title: "Exec", reference: reference, payload: payload,
                      text: payload["foreground"] as? Bool == true ? text : (text.isEmpty ? (ok ? "OK" : "ERROR") : text))
        }
    }

    static func guestRequest(
        name: String,
        request: GuestCLIRequest,
        title: String
    ) throws -> PommeOperationResult {
        return try VMBundleMutationLease.withLease(name: name) { _ in
            try guestRequestUnchecked(name: name, request: request, title: title)
        }
    }

    private static func guestRequestUnchecked(name: String, request: GuestCLIRequest, title: String) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        let payload = try PommeCore.sendControlObject(request.controlPayload, bundle: reference.bundle)
        let text = payload["stdout"] as? String
            ?? payload["error"] as? String
            ?? payload["state"] as? String
            ?? "OK"
        return result(title: title, reference: reference, payload: payload, text: text)
    }

    static func ui(name: String, request: GuestUIRequest) throws -> PommeOperationResult {
        if request.operation == .screenshot {
            return try uiUnchecked(name: name, request: request)
        }
        return try VMBundleMutationLease.withLease(name: name) { _ in
            try uiUnchecked(name: name, request: request)
        }
    }

    private static func uiUnchecked(name: String, request: GuestUIRequest) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        let payload = try PommeCore.sendControlObject(
            request.controlPayload,
            bundle: reference.bundle
        )
        let text = payload["error"] as? String ?? (payload["ok"] as? Bool == false ? "UI operation failed." : "OK")
        return result(title: "UI", reference: reference, payload: payload, text: text)
    }

    static func create(
        name: String,
        restoreArgs: [String],
        diskSize: String,
        memory: String,
        startMode: StartMode
    ) async throws -> PommeOperationResult {
        try await VMBundleMutationLease.withLease(name: name) { lease in
        let reference = try namedReference(name, requireExists: false)
        let bundleExists = FileManager.default.fileExists(atPath: reference.bundle.rootURL.path)
        guard !bundleExists else {
            throw RunnerError.hostCommandFailed(
                "A managed VM named \(name) already exists. Delete it explicitly before creating a replacement."
            )
        }
        var options = try createOptions(
            name: name,
            restoreArgs: restoreArgs,
            diskSize: diskSize,
            memory: memory,
            resume: false,
            startMode: startMode
        )
        options.create = true
        let payload = try await PommeCore.createVMPayload(
            arguments: options,
            reference: reference,
            lease: lease
        )
        return result(title: "Create VM", reference: reference, payload: payload, text: formatCreate(payload))
        }
    }

    static func configuredCreate(plan: VMCreationPlan) async throws -> PommeOperationResult {
        try await VMBundleMutationLease.withLease(name: plan.name) { lease in
        var options = CLIOptions()
        options.vmName = plan.name
        options.create = true
        options.restoreImageVersionSelection = plan.firmware.buildid
        options.ipswDeviceIdentifier = plan.config.ipswDevice
        options.resumeDownload = true
        if let boot = plan.config.boot, boot != .none {
            options.start = true
            options.bootMode = boot == .normal ? .normal : .recovery
        }
        if let diskSize = plan.config.hardware?.diskSize {
            options.sizeOptions.diskSizeBytes = try parseSize(diskSize, flag: "hardware.diskSize")
            options.hasCustomSizeOptions = true
        }
        if let memory = plan.config.hardware?.memory {
            options.sizeOptions.memorySizeBytes = try parseSize(memory, flag: "hardware.memory")
            options.hasCustomSizeOptions = true
        }

        let reference = try namedReference(plan.name, requireExists: false)
        let payload = try await PommeCore.createConfiguredVMPayload(
            config: plan.config,
            arguments: options,
            reference: reference,
            lease: lease
        )
        return result(
            title: "Create VM",
            reference: reference,
            payload: payload,
            text: payload["ok"] as? Bool == true
                ? "OK created name=\(plan.name) version=\(plan.firmware.version)"
                : "ERROR: \(stringValue(payload["error"]))"
        )
        }
    }

    static func sip(
        name: String,
        action: SIPAction,
        bootstrap: Bool,
        lease: VMBundleMutationLease? = nil
    ) async throws -> PommeOperationResult {
        _ = bootstrap
        return try await sipWorkflow(name: name, action: action, finalState: .previous, lease: lease)
    }

    static func sipWorkflow(
        name: String,
        action: SIPAction,
        finalState: VMFinalState,
        force: Bool = false
    ) async throws -> PommeOperationResult {
        try await sipWorkflow(name: name, action: action, finalState: finalState, force: force, lease: nil)
    }

    private static func sipWorkflow(
        name: String,
        action: SIPAction,
        finalState: VMFinalState,
        force: Bool = false,
        lease: VMBundleMutationLease?
    ) async throws -> PommeOperationResult {
        try await VMBundleMutationLease.withLease(name: name, inherited: lease) { acquiredLease in
            let reference = try namedReference(name)
            if action != .status {
                let operation: PommeSecurityWorkflowOperation = action == .enable ? .sipEnable : .sipDisable
                let payload = try await PommeSecurityWorkflow.runLive(
                    reference: reference, operation: operation, finalState: finalState,
                    force: force, lease: acquiredLease,
                    recoveryFactory: currentRecoveryIntegrationFactory()
                )
                return result(
                    title: action == .enable ? "Enable SIP" : "Disable SIP",
                    reference: reference, payload: payload.publicValue as? [String: Any] ?? [:],
                    text: formatSecurityPayload(payload.publicValue as? [String: Any] ?? [:])
                )
            }
            let integration = try await currentRecoveryIntegrationFactory().make(
                reference: reference,
                operation: .sip(action)
            )
            let execution = try await integration.sip(
                action: action,
                payload: try recoverySecurityPayload(
                    reference: reference,
                    sipAction: action
                ),
                finalState: finalState
            )
            let payload = recoveryExecutionPayload(
                operation: "sip." + action.rawValue,
                reference: reference,
                execution: execution
            )
            let title = action == .status ? "SIP Status" : (action == .disable ? "Disable SIP" : "Enable SIP")
            return result(title: title, reference: reference, payload: payload, text: formatSecurityPayload(payload))
        }
    }

    static func amfi(
        name: String,
        action: AMFIAction,
        bootstrap: Bool,
        lease: VMBundleMutationLease? = nil
    ) async throws -> PommeOperationResult {
        _ = bootstrap
        return try await amfiWorkflow(name: name, action: action, finalState: .previous, lease: lease)
    }

    static func amfiWorkflow(
        name: String,
        action: AMFIAction,
        finalState: VMFinalState,
        force: Bool = false
    ) async throws -> PommeOperationResult {
        try await amfiWorkflow(name: name, action: action, finalState: finalState, force: force, lease: nil)
    }

    private static func amfiWorkflow(
        name: String,
        action: AMFIAction,
        finalState: VMFinalState,
        force: Bool = false,
        lease: VMBundleMutationLease?
    ) async throws -> PommeOperationResult {
        try await VMBundleMutationLease.withLease(name: name, inherited: lease) { acquiredLease in
            let reference = try namedReference(name)
            if action != .status {
                let operation: PommeSecurityWorkflowOperation = action == .enable ? .amfiEnable : .amfiDisable
                let payload = try await PommeSecurityWorkflow.runLive(
                    reference: reference, operation: operation, finalState: finalState,
                    force: force, lease: acquiredLease,
                    recoveryFactory: currentRecoveryIntegrationFactory()
                )
                return result(
                    title: action == .enable ? "Enable AMFI" : "Disable AMFI",
                    reference: reference, payload: payload.publicValue as? [String: Any] ?? [:],
                    text: formatSecurityPayload(payload.publicValue as? [String: Any] ?? [:])
                )
            }
            let integration = try await currentRecoveryIntegrationFactory().make(
                reference: reference,
                operation: .amfi(action)
            )
            let execution = try await integration.amfi(
                action: action,
                payload: try recoverySecurityPayload(
                    reference: reference,
                    amfiAction: action
                ),
                finalState: finalState
            )
            let payload = recoveryExecutionPayload(
                operation: "amfi." + action.rawValue,
                reference: reference,
                execution: execution
            )
            let title = action == .status ? "AMFI Status" : (action == .disable ? "Disable AMFI" : "Enable AMFI")
            return result(title: title, reference: reference, payload: payload, text: formatSecurityPayload(payload))
        }
    }

    /// Mutation credentials are accepted only from Pomme's dedicated
    /// environment pair or an exact UUID/account Keychain item. They never
    /// enter argv, the Recovery request file, public output, or diagnostics.
    private static func recoverySecurityAuthorization(
        reference: VMReference
    ) throws -> PommeGuestSecurityCredentials {
        let environment = ProcessInfo.processInfo.environment
        let environmentUser = environment["POMME_AUTHORIZED_USER"]
        let environmentPassword = environment["POMME_AUTHORIZED_PASSWORD"]
        if environmentUser != nil || environmentPassword != nil {
            guard let user = environmentUser, !user.isEmpty,
                  let password = environmentPassword, !password.isEmpty else {
                throw RunnerError.sipCredentialUnavailable(
                    "Set both POMME_AUTHORIZED_USER and POMME_AUTHORIZED_PASSWORD for a Recovery security mutation."
                )
            }
            _ = try validateGuestAccountName(user, flag: "POMME_AUTHORIZED_USER")
            return try PommeGuestSecurityCredentials(username: user, password: password)
        }

        let metadata = try metadataPayload(bundle: reference.bundle)
        guard let user = metadata[Constants.guestKCPasswordUserMetadataKey] as? String,
              !user.isEmpty,
              user != "agent-token" else {
            throw RunnerError.sipCredentialUnavailable(
                "A Recovery security mutation requires POMME_AUTHORIZED_USER and POMME_AUTHORIZED_PASSWORD or an exact Pomme VM owner credential in Keychain."
            )
        }
        _ = try validateGuestAccountName(user, flag: "stored Pomme owner credential")
        let service = try pommeCredentialService(for: reference)
        guard let password = try findHostKeychainPassword(
            service: service,
            account: user,
            keychainPath: nil
        ), !password.isEmpty else {
            throw RunnerError.sipCredentialUnavailable(
                "The exact Pomme VM owner credential is unavailable in Keychain."
            )
        }
        return try PommeGuestSecurityCredentials(username: user, password: password)
    }

    private static func recoverySecurityPayload(
        reference: VMReference,
        sipAction: SIPAction
    ) throws -> Data {
        guard sipAction != .status else { return Data() }
        let authorization = try recoverySecurityAuthorization(reference: reference)
        return try PommeProvisioningCoding.encode(JSONValue.object([
            "authorizedUser": .string(authorization.username),
            "password": .string(authorization.password)
        ]))
    }

    private static func recoverySecurityPayload(
        reference: VMReference,
        amfiAction: AMFIAction
    ) throws -> Data {
        guard amfiAction != .status else { return Data() }
        let authorization = try recoverySecurityAuthorization(reference: reference)
        let metadata = try metadataPayload(bundle: reference.bundle)
        guard let rawVolumeGroup = metadata["startupVolumeGroupUUID"] as? String,
              let volumeGroupUUID = UUID(uuidString: rawVolumeGroup),
              rawVolumeGroup == volumeGroupUUID.uuidString.lowercased() else {
            throw RunnerError.hostCommandFailed(
                "The Pomme VM has no verified startup volume-group identity. Repair its agent installation before changing AMFI."
            )
        }
        return try PommeProvisioningCoding.encode(JSONValue.object([
            "authorizedUser": .string(authorization.username),
            "password": .string(authorization.password),
            "volumeGroupUUID": .string(rawVolumeGroup)
        ]))
    }

    static func mdmEnroll(
        name: String,
        profilePath: String,
        guestPath: String?,
        timeout: TimeInterval
    ) async throws -> PommeOperationResult {
        guard timeout.isFinite, timeout >= 1, timeout <= 300 else {
            throw RunnerError.invalidControlCommand("mdm.enroll timeout")
        }
        return try await VMBundleMutationLease.withLease(name: name) { _ in
            let reference = try namedReference(name)
            let profileURL = URL(fileURLWithPath: PommeCore.absoluteHostPath(profilePath)).standardizedFileURL
            guard regularFile(profileURL) else {
                throw RunnerError.hostCommandFailed("The MDM profile does not exist.")
            }
            let expectedDigest = try PommeCore.expectedProvisionedAgentDigest(
                reference: reference
            )
            let transport = PommeMDMEnrollmentAgentDependencies(
                describe: {
                    try await authenticatedMDMAgentDescription(
                        reference: reference,
                        timeout: timeout
                    )
                },
                perform: { operation in
                    if case .prepareStaging = operation {
                        let description = try await authenticatedMDMAgentDescription(
                            reference: reference,
                            timeout: timeout
                        )
                        _ = try MDMEnrollmentAgentGate.verify(
                            description,
                            expectedExecutableDigest: expectedDigest
                        )
                    }
                    return try performAuthenticatedAgentOperation(
                        reference: reference,
                        operation: operation.wireName,
                        payload: try operation.payload()
                    )
                },
                transferProfile: { source, destination in
                    try transferMDMProfile(
                        reference: reference,
                        source: source,
                        destination: destination
                    )
                }
            )
            let state = makeLiveMDMStatePort(reference: reference)
            let transaction = PommeMDMEnrollmentTransaction(
                agent: transport,
                state: state,
                profileURL: profileURL,
                guestPath: guestPath,
                timeout: timeout,
                expectedExecutableDigest: expectedDigest
            )
            let enrolled = try await transaction.execute()
            let agent: [String: Any] = [
                "role": GuestAgentStatusV1.Role.normal.rawValue,
                "protocol": PommeAgentProtocol.name,
                "version": PommeAgentProtocol.version,
                "capabilities": enrolled.agentCapabilities
            ]
            return mdmResult(
                title: "MDM enrollment",
                operation: "mdm-enroll",
                reference: reference,
                ok: true,
                agent: agent,
                steps: [
                    ["name": "verifyPommeAgent", "ok": true],
                    ["name": "captureBaseline", "ok": true],
                    ["name": "prepareStaging", "ok": true],
                    ["name": "transferProfile", "ok": true],
                    ["name": "enroll", "ok": true],
                    ["name": "cleanupProfile", "ok": true],
                    ["name": "restoreBaseline", "ok": true]
                ],
                result: [
                    "profileIdentifier": enrolled.profileIdentifier,
                    "transferredBytes": enrolled.transferredBytes,
                    "transferredSHA256": enrolled.transferredSHA256
                ]
            )
        }
    }

    private static func performAuthenticatedAgentOperation(
        reference: VMReference,
        operation: String,
        payload: JSONValue = .object([:])
    ) throws -> JSONValue {
        let response = try PommeCore.sendControlObject(
            [
                "command": "agent.perform",
                "operation": operation,
                "payload": payload.publicValue
            ],
            bundle: reference.bundle
        )
        guard response["ok"] as? Bool == true,
              PommeCore.hostExitCode(from: response) == 0,
              let result = response["result"] else {
            throw RunnerError.hostCommandFailed(
                "The authenticated PommeAgent operation did not complete."
            )
        }
        return try JSONValue(any: result)
    }

    private static func authenticatedMDMAgentDescription(
        reference: VMReference,
        timeout: TimeInterval
    ) async throws -> MDMEnrollmentAgentDescription {
        let deadline = Date().addingTimeInterval(min(max(timeout, 1), 300))
        while true {
            do {
                let value = try performAuthenticatedAgentOperation(
                    reference: reference,
                    operation: "agent.describe"
                )
                return try MDMEnrollmentAgentDescription.fromAuthenticatedDescribe(value)
            } catch {
                guard Date() < deadline else {
                    throw PommeMDMEnrollmentError.agentUnavailable
                }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private static func transferMDMProfile(
        reference: VMReference,
        source: URL,
        destination: String
    ) throws -> PommeMDMProfileTransferReceipt {
        guard try MDMProfileStaging.destination(requestedPath: destination) == destination else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PommeMDMEnrollmentError.invalidProfile }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0 else {
            throw PommeMDMEnrollmentError.invalidProfile
        }

        var remoteFileID: String?
        do {
            let opened = try performAuthenticatedAgentOperation(
                reference: reference,
                operation: "file.open",
                payload: .object([
                    "path": .string(destination),
                    "mode": .string("stageWrite")
                ])
            )
            guard let openObject = opened.objectValue,
                  Set(openObject.keys) == ["fileID", "staged"],
                  let fileID = openObject["fileID"]?.stringValue,
                  let canonicalID = UUID(uuidString: fileID),
                  canonicalID.uuidString.lowercased() == fileID,
                  openObject["staged"] == .bool(true) else {
                throw PommeMDMEnrollmentError.invalidTransfer
            }
            remoteFileID = fileID

            var hasher = SHA256()
            var transferred = 0
            var buffer = [UInt8](
                repeating: 0,
                count: PommeAgentProtocol.maximumFileChunkBytes
            )
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw PommeMDMEnrollmentError.transferFailed }
                if count == 0 { break }
                let chunk = Data(buffer.prefix(count))
                hasher.update(data: chunk)
                let written = try performAuthenticatedAgentOperation(
                    reference: reference,
                    operation: "file.write",
                    payload: .object([
                        "fileID": .string(fileID),
                        "dataBase64": .string(chunk.base64EncodedString())
                    ])
                )
                guard let object = written.objectValue,
                      Set(object.keys) == ["count"],
                      object["count"] == .integer(Int64(count)) else {
                    throw PommeMDMEnrollmentError.invalidTransfer
                }
                transferred += count
            }
            let flushed = try performAuthenticatedAgentOperation(
                reference: reference,
                operation: "file.flush",
                payload: .object(["fileID": .string(fileID)])
            )
            guard flushed == .object([:]) else {
                throw PommeMDMEnrollmentError.invalidTransfer
            }

            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  transferred == Int(before.st_size) else {
                throw PommeMDMEnrollmentError.invalidTransfer
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let committed = try performAuthenticatedAgentOperation(
                reference: reference,
                operation: "file.commit",
                payload: .object([
                    "fileID": .string(fileID),
                    "expectedBytes": .integer(Int64(transferred)),
                    "expectedSHA256": .string(digest)
                ])
            )
            guard committed == .object([
                "committed": .bool(true),
                "bytes": .integer(Int64(transferred)),
                "sha256": .string(digest)
            ]) else {
                throw PommeMDMEnrollmentError.invalidTransfer
            }
            remoteFileID = nil
            return try .init(
                destination: destination,
                bytes: transferred,
                sha256: digest
            )
        } catch {
            if let remoteFileID {
                _ = try? performAuthenticatedAgentOperation(
                    reference: reference,
                    operation: "file.abort",
                    payload: .object(["fileID": .string(remoteFileID)])
                )
            }
            if let error = error as? PommeMDMEnrollmentError { throw error }
            throw PommeMDMEnrollmentError.transferFailed
        }
    }

    private static func makeLiveMDMStatePort(
        reference: VMReference
    ) -> PommeMDMEnrollmentStateDependencies {
        let proof = PommeMDMRestorationProof()
        return .init(
            capture: {
                let runState = try PommeCore.stableVMRunState(reference: reference)
                guard runState == .running(.normal) else {
                    throw PommeMDMEnrollmentError.baselineCaptureFailed
                }
                do {
                    let sip = try await recoverySecurityStatusOutput(
                        reference: reference,
                        operation: .sip(.status),
                        finalState: .normal
                    )
                    let amfi = try await recoverySecurityStatusOutput(
                        reference: reference,
                        operation: .amfi(.status),
                        finalState: .normal
                    )
                    return .init(sip: sip, amfi: amfi, runState: runState)
                } catch {
                    // Baseline capture has not returned yet, so the outer MDM
                    // transaction cannot restore it. Rescue the independently
                    // captured lifecycle state here and prove it before
                    // surfacing a redacted baseline failure.
                    do {
                        if try !PommeCore.provesStableVMRunState(
                            runState,
                            reference: reference
                        ) {
                            try await PommeCore.restoreStableVMRunState(
                                runState,
                                reference: reference
                            )
                        }
                        guard try PommeCore.provesStableVMRunState(
                            runState,
                            reference: reference
                        ) else { throw PommeMDMEnrollmentError.restorationFailed }
                    } catch {
                        throw PommeMDMEnrollmentError.restorationFailed
                    }
                    throw PommeMDMEnrollmentError.baselineCaptureFailed
                }
            },
            restore: { baseline in
                try await PommeCore.restoreStableVMRunState(
                    baseline.runState,
                    reference: reference
                )
                let finalState = mdmFinalState(for: baseline.runState)
                let sip = try await recoverySecurityStatusOutput(
                    reference: reference,
                    operation: .sip(.status),
                    finalState: finalState
                )
                let amfi = try await recoverySecurityStatusOutput(
                    reference: reference,
                    operation: .amfi(.status),
                    finalState: finalState
                )
                guard sip == baseline.sip, amfi == baseline.amfi else {
                    throw PommeMDMEnrollmentError.restorationFailed
                }
                await proof.recordSecurityMatch()
            },
            verify: { baseline in
                guard await proof.isSecurityMatched() else { return false }
                return try PommeCore.provesStableVMRunState(
                    baseline.runState,
                    reference: reference
                )
            }
        )
    }

    private static func mdmFinalState(for state: VMRunStateSnapshot) -> VMFinalState {
        switch state {
        case .stopped: .stopped
        case .running(.normal): .normal
        case .running(.recovery): .recovery
        case .paused: .paused
        }
    }

    private static func recoverySecurityStatusOutput(
        reference: VMReference,
        operation: PommeRecoveryOperation,
        finalState: VMFinalState
    ) async throws -> Data {
        let integration = try await currentRecoveryIntegrationFactory().make(
            reference: reference,
            operation: operation
        )
        let execution: PommeRecoveryExecutionResult
        switch operation {
        case .sip(.status):
            execution = try await integration.sip(
                action: .status,
                payload: Data(),
                finalState: finalState
            )
        case .amfi(.status):
            execution = try await integration.amfi(
                action: .status,
                payload: Data(),
                finalState: finalState
            )
        default:
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        guard execution.evidence.authenticated,
              execution.evidence.requestBound,
              execution.evidence.credentialConsumed,
              execution.evidence.lifecycle == .finalized,
              execution.cleanup.isComplete,
              execution.finalState == finalState else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: execution.output)
        guard let object = value.objectValue,
              object["verified"] == .bool(true) else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        switch operation {
        case .sip(.status):
            guard Set(object.keys) == ["operation", "sipEnabled", "sipDisabled", "verified"],
                  object["operation"] == .string("sip.status") else {
                throw PommeMDMEnrollmentError.baselineCaptureFailed
            }
        case .amfi(.status):
            guard Set(object.keys) == [
                "operation", "amfiBootArgActive", "amfiDisabled",
                "bootPolicyAllowsCustomBootArgs", "securityMode", "verified"
            ], object["operation"] == .string("amfi.status") else {
                throw PommeMDMEnrollmentError.baselineCaptureFailed
            }
        default:
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        return try PommeProvisioningCoding.encode(value)
    }

    static func mdmApprove(
        name: String,
        profileIdentifier: String,
        timeout: TimeInterval
    ) async throws -> PommeOperationResult {
        guard timeout.isFinite, timeout >= 1, timeout <= 300, !profileIdentifier.isEmpty else {
            throw RunnerError.invalidControlCommand("mdm.approve request")
        }
        return try await VMBundleMutationLease.withLease(name: name) { _ in
            let reference = try namedReference(name)
            let description = try await authenticatedMDMAgentDescription(
                reference: reference,
                timeout: timeout
            )
            let expectedDigest = try PommeCore.expectedProvisionedAgentDigest(
                reference: reference
            )
            let agent = try MDMEnrollmentAgentGate.verify(
                description,
                expectedExecutableDigest: expectedDigest
            )
            let operation = PommeMDMEnrollmentAgentOperation.approve(
                profileIdentifier: profileIdentifier,
                timeout: timeout
            )
            let response = try performAuthenticatedAgentOperation(
                reference: reference,
                operation: operation.wireName,
                payload: try operation.payload()
            )
            try PommeMDMEnrollmentAgentResponse.approval(response)
            return mdmResult(
                title: "MDM user-intent approval",
                operation: "mdm-user-approval",
                reference: reference,
                ok: true,
                agent: agent,
                steps: [["name": "verifyPommeAgent", "ok": true], ["name": "approve", "ok": true]],
                result: response.publicValue
            )
        }
    }

    private static func mdmResult(
        title: String,
        operation: String,
        reference: VMReference,
        ok: Bool,
        agent: [String: Any],
        steps: [[String: Any]],
        result: Any? = nil,
        error: String? = nil
    ) -> PommeOperationResult {
        var payload: [String: Any] = [
            "ok": ok,
            "operation": operation,
            "name": reference.name as Any,
            "agent": agent,
            "steps": steps,
            "hostExitCode": ok ? 0 : 1
        ]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        return Self.result(
            title: title,
            reference: reference,
            payload: payload,
            text: ok ? "OK " + operation : "ERROR: " + (error ?? "PommeAgent operation failed.")
        )
    }

    private static func regularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return false }
        return true
    }

    private static func createOptions(
        name: String,
        restoreArgs: [String],
        diskSize: String,
        memory: String,
        resume: Bool,
        startMode: StartMode
    ) throws -> CLIOptions {
        var options = CLIOptions()
        options.vmName = try validateVMName(name)
        options.sizeOptions.diskSizeBytes = try parseSize(diskSize, flag: "--disk-size")
        options.sizeOptions.memorySizeBytes = try parseSize(memory, flag: "--ram")
        options.hasCustomSizeOptions = true
        options.resumeDownload = resume

        var index = 0
        while index < restoreArgs.count {
            switch restoreArgs[index] {
            case "--version":
                guard index + 1 < restoreArgs.count else {
                    throw RunnerError.usage
                }
                options.restoreImageVersionSelection = restoreArgs[index + 1]
                index += 2
            case "--ipsw-device":
                guard index + 1 < restoreArgs.count else {
                    throw RunnerError.usage
                }
                options.ipswDeviceIdentifier = restoreArgs[index + 1]
                index += 2
            case "--restore-image":
                guard index + 1 < restoreArgs.count else {
                    throw RunnerError.usage
                }
                options.restoreImagePath = restoreArgs[index + 1]
                index += 2
            default:
                throw RunnerError.usage
            }
        }

        switch startMode {
        case .none:
            break
        case .normal:
            options.start = true
            options.bootMode = .normal
        case .recovery:
            options.start = true
            options.bootMode = .recovery
        }
        return options
    }

    private static func parseSize(_ value: String, flag: String) throws -> UInt64 {
        guard let bytes = ByteSizeParser.parse(value) else {
            throw RunnerError.invalidSize(flag: flag, value: value)
        }
        return bytes
    }

    private static func recoveryExecutionPayload(
        operation: String,
        reference: VMReference,
        execution: PommeRecoveryExecutionResult
    ) -> [String: Any] {
        let evidence = execution.evidence
        let cleanup = execution.cleanup
        var payload: [String: Any] = [
            "ok": true,
            "operation": operation,
            "name": reference.name as Any,
            "recovery": [
                "requestID": evidence.requestID.uuidString.lowercased(),
                "vmUUID": evidence.vmUUID.uuidString.lowercased(),
                "listenerPort": evidence.listenerPort,
                "authenticated": evidence.authenticated,
                "requestBound": evidence.requestBound,
                "credentialConsumed": evidence.credentialConsumed,
                "lifecycle": evidence.lifecycle.rawValue
            ],
            "cleanup": [
                "shareRemoved": cleanup.shareRemoved,
                "launcherRemoved": cleanup.launcherRemoved,
                "credentialRemoved": cleanup.credentialRemoved,
                "listenerClosed": cleanup.listenerClosed,
                "sensitiveFramesCleared": cleanup.sensitiveFramesCleared,
                "unknownStateRejected": cleanup.unknownStateRejected
            ],
            "finalState": execution.finalState.rawValue,
            "finalStateVerified": true,
            "outputBytes": execution.output.count,
            "outputDigest": PommeProvisioningDigest.sha256(execution.output),
            "hostExitCode": 0
        ]
        let output = safeRecoveryOutput(execution.output)
        if !output.isEmpty { payload["output"] = output }
        return payload
    }

    private static func safeRecoveryOutput(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let redacted = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { line -> String in
                let value = String(line)
                let lowered = value.lowercased()
                if lowered.contains("token") || lowered.contains("password") || lowered.contains("secret") {
                    return "[redacted]"
                }
                return value
            }
            .joined(separator: " ")
        return String(redacted.prefix(4 * 1024))
    }

    private static func agentResponseText(_ payload: [String: Any]) -> String {
        var chunks: [String] = []
        if let frames = payload["streamFrames"] as? [[String: Any]] {
            for frame in frames {
                guard let stream = frame["stream"] as? String,
                      stream == PommeAgentProtocol.Stream.stdout.rawValue
                        || stream == PommeAgentProtocol.Stream.stderr.rawValue
                else { continue }
                if let encoded = frame["dataBase64"] as? String,
                   let data = Data(base64Encoded: encoded) {
                    chunks.append(String(decoding: data, as: UTF8.self))
                }
            }
        }
        if chunks.isEmpty, let result = payload["result"] as? [String: Any] {
            if let output = result["output"] as? String { chunks.append(output) }
            if let message = result["message"] as? String { chunks.append(message) }
        }
        if chunks.isEmpty, let error = payload["error"] as? String { chunks.append(error) }
        return chunks.joined()
    }

    private static func result(title: String, reference: VMReference, payload: [String: Any], text: String) -> PommeOperationResult {
        PommeOperationResult(
            title: title,
            vmName: reference.name,
            ok: payload["ok"] as? Bool ?? true,
            hostExitCode: PommeCore.hostExitCode(from: payload, default: payload["ok"] as? Bool == false ? 1 : 0),
            text: text,
            payload: payload
        )
    }

    private static func formatStatus(_ payload: [String: Any]) -> String {
        let jobs = payload["jobs"] as? [[String: Any]] ?? []
        let bootMode = stringValue(payload["bootMode"]).isEmpty ? BootMode.normal.rawValue : stringValue(payload["bootMode"])
        var lines = ["VM \(stringValue(payload["vmState"])) boot=\(bootMode) helper=\(stringValue(payload["helperRunning"])) jobs=\(jobs.count)"]
        lines.append(formatGuestAgent(payload["guestAgent"] as? [String: Any]))
        lines.append(contentsOf: jobs.map(jobSummary))
        return lines.joined(separator: "\n")
    }

    private static func formatInspect(_ payload: [String: Any]) -> String {
        var lines = [
            "bundle: \(stringValue(payload["bundlePath"]))",
            "controlSocket: \(stringValue(payload["controlSocket"]))",
            "helperRunning: \(stringValue(payload["helperRunning"]))",
            "vmState: \(stringValue(payload["vmState"]))",
            "bootMode: \(stringValue(payload["bootMode"]))",
            formatGuestAgent(payload["guestAgent"] as? [String: Any])
        ]
        if let metadata = payload["metadata"] as? [String: Any] {
            for key in metadata.keys.sorted() {
                lines.append("metadata.\(key): \(stringValue(metadata[key]))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatHealth(_ payload: [String: Any]) -> String {
        var lines = [
            "health: \((payload["healthy"] as? Bool == true) ? "healthy" : "unhealthy")",
            "vmState: \(stringValue(payload["vmState"]))",
            "bootMode: \(stringValue(payload["bootMode"]))",
            formatGuestAgent(payload["guestAgent"] as? [String: Any])
        ]
        for check in payload["checks"] as? [[String: Any]] ?? [] {
            let ok = check["ok"] as? Bool == true ? "ok" : "fail"
            let detail = stringValue(check["detail"])
            lines.append("check.\(stringValue(check["name"])): \(ok)\(detail.isEmpty ? "" : " \(detail)")")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatCapabilities(_ payload: [String: Any]) -> String {
        guard let agent = payload["guestAgent"] as? [String: Any] else {
            return payload["ok"] as? Bool == false ? "ERROR: \(stringValue(payload["error"]))" : "Guest agent is unavailable."
        }
        let capabilities = agent["capabilities"] as? [String] ?? []
        return [
            formatGuestAgent(agent),
            "capabilities: \(capabilities.sorted().joined(separator: ", "))"
        ].joined(separator: "\n")
    }

    private static func formatGuestAgent(_ agent: [String: Any]?) -> String {
        guard let agent else { return "guestAgent: unavailable" }
        return "guestAgent connection=\(stringValue(agent["connection"])) role=\(stringValue(agent["role"])) protocol=\(stringValue(agent["protocolVersion"])) digest=\(stringValue(agent["executableDigest"])) update=\(stringValue(agent["updateState"]))"
    }

    private static func formatBoot(_ payload: [String: Any]) -> String {
        if payload["ok"] as? Bool != true {
            return "ERROR boot mode=\(stringValue(payload["bootMode"])): \(stringValue(payload["error"]))"
        }
        if payload["bootMode"] as? String == BootMode.recovery.rawValue,
           let agent = payload["guestAgent"] as? [String: Any],
           stringValue(agent["connection"]) == PommeAgentClosedStatus.Connection.connected.rawValue,
           stringValue(agent["role"]) == PommeProvisioningAgentRole.recovery.rawValue {
            return "OK Recovery ready"
        }
        let steps = payload["steps"] as? [[String: Any]] ?? []
        if let response = steps.compactMap({ $0["response"] as? String }).last {
            return response
        }
        return "OK boot mode=\(stringValue(payload["bootMode"]))"
    }

    private static func formatCreate(_ payload: [String: Any]) -> String {
        if payload["ok"] as? Bool == true {
            return "OK created name=\(stringValue(payload["name"])) bundle=\(stringValue(payload["bundlePath"]))"
        }
        return "ERROR create failed: \(stringValue(payload["error"]))"
    }

    private static func formatSecurityPayload(_ payload: [String: Any]) -> String {
        var lines: [String] = []
        if let output = payload["output"] as? String, !output.isEmpty { lines.append(output) }
        if let finalState = payload["finalState"] as? String { lines.append("finalState: " + finalState) }
        if let cleanup = payload["cleanup"] as? [String: Any] {
            let complete = cleanup.values.allSatisfy { ($0 as? Bool) == true }
            lines.append("cleanup: " + (complete ? "verified" : "incomplete"))
        }
        if lines.isEmpty {
            lines.append(payload["ok"] as? Bool == true ? "OK" : "ERROR: " + stringValue(payload["error"]))
        }
        return lines.joined(separator: "\n")
    }

    private static func jobSummary(_ object: [String: Any]) -> String {
        var fields = [
            stringValue(object["state"]).uppercased(),
            stringValue(object["jobID"]),
            "pid=\(stringValue(object["pid"]))"
        ]
        if let exitCode = object["exitCode"] {
            fields.append("exit=\(stringValue(exitCode))")
        }
        if let command = object["displayCommand"] {
            fields.append("command=\(stringValue(command))")
        }
        return fields.joined(separator: " ")
    }

    private static func stringValue(_ value: Any?) -> String {
        PommeCore.stringValue(value)
    }
}
