import CryptoKit
import Darwin
import Foundation
import Security

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
                    try requireSnapshotLifecycleSucceeded(pause(name: name, lease: lease))
                    pausedForCapture = true
                }
                let capture = try PommeCore.sendControlObject([
                    "command": "snapshot-save",
                    "stageName": stage.lastPathComponent
                ], bundle: reference.bundle)
                try VMSnapshotStore.confirmCapture(response: capture, stage: stage)
                let record = try VMSnapshotStore.complete(
                    bundle: reference.bundle, name: snapshot, stage: stage,
                    sourceState: didPause ? "running" : "paused"
                )
                if didPause {
                    try requireSnapshotLifecycleSucceeded(resume(name: name, lease: lease))
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
                        try requireSnapshotLifecycleSucceeded(resume(name: name, lease: lease))
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
                        try requireSnapshotLifecycleSucceeded(pause(name: name, lease: lease))
                        pausedForRollbackCapture = true
                    }
                    let capture = try PommeCore.sendControlObject([
                        "command": "snapshot-save",
                        "stageName": rollback!.lastPathComponent
                    ], bundle: reference.bundle)
                    try VMSnapshotStore.confirmCapture(response: capture, stage: rollback!)
                    rollbackCaptured = true
                    try requireSnapshotLifecycleSucceeded(stop(name: name, force: true, lease: lease))
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
                            try requireSnapshotLifecycleSucceeded(resume(name: name, lease: lease))
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
                    try requireSnapshotLifecycleSucceeded(stop(name: name, force: true, lease: lease))
                    try VMSnapshotStore.removeRequiredRestoreArtifacts(bundle: reference.bundle)
                    if let rollback, rollbackCaptured {
                        try VMSnapshotStore.installRollbackMachineState(bundle: reference.bundle, stage: rollback)
                        _ = try PommeCore.startRequiredSnapshotRestorePayload(reference: reference)
                        if priorState == "running" {
                            try requireSnapshotLifecycleSucceeded(resume(name: name, lease: lease))
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

    static func requireSnapshotLifecycleSucceeded(_ result: PommeOperationResult) throws {
        guard result.ok, result.hostExitCode == 0 else {
            throw RunnerError.virtualMachineState(
                result.payload["error"] as? String ?? "Snapshot VM state transition failed.")
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
        if request.pty {
            return try terminalSessionCreate(
                name: name,
                payload: request.terminalPayload(),
                title: "Exec",
                attach: true
            )
        }
        return try VMBundleMutationLease.withLease(name: name) { _ in
        let reference = try namedReference(name)
        var payload = try PommeCore.sendForegroundControlObject(request.controlPayload, bundle: reference.bundle)
        payload["operation"] = "process.start"
        payload["name"] = name
        let ok = payload["ok"] as? Bool == true
        let text = agentResponseText(payload)
        return result(title: "Exec", reference: reference, payload: payload,
                      text: payload["foreground"] as? Bool == true ? text : (text.isEmpty ? (ok ? "OK" : "The guest command failed.") : text))
        }
    }

    static func terminalSessionCreate(
        name: String,
        payload: [String: Any],
        title: String,
        attach: Bool
    ) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        var createPayload = payload
        let sessionID = UUID().uuidString.lowercased()
        createPayload["sessionID"] = sessionID
        createPayload["command"] = "terminal.session"
        createPayload["operation"] = "terminal.create"
        let create = { try PommeCore.sendControlObject(createPayload, bundle: reference.bundle) }
        let status = try? PommeCore.sendControlObject(
            ["command": "status"],
            bundle: reference.bundle
        )
        var created: [String: Any]
        if (status?["bootMode"] as? String) == BootMode.recovery.rawValue {
            // Recovery admission briefly owns the bundle mutation lease while
            // it stages and authenticates the terminal authority. The lease
            // is released before the durable session can be attached.
            created = try VMBundleMutationLease.withLease(name: name) { _ in
                try create()
            }
        } else {
            created = try create()
        }
        created["operation"] = "terminal.create"
        created["name"] = name
        guard let createdID = created["sessionID"] as? String else {
            throw RunnerError.invalidControlResponse("The terminal creation response did not include a session ID.")
        }
        if attach {
            if let session = created["session"] as? [String: Any],
               session["bootRole"] as? String == PommeDurableTerminalRole.recovery.rawValue {
                let notice = "Notice: this Recovery terminal runs as unrestricted root and is outside Pomme's transactional SIP/AMFI guarantees.\n"
                FileHandle.standardError.write(Data(notice.utf8))
            }
            let attached = try PommeCore.sendTerminalAttachControlObject(
                [
                    "command": "terminal.session",
                    "operation": "terminal.attach",
                    "sessionID": createdID
                ],
                bundle: reference.bundle
            )
            var payload = attached
            payload["sessionID"] = createdID
            payload["operation"] = "terminal.attach"
            payload["terminalAttachment"] = true
            payload["name"] = name
            return result(title: title, reference: reference, payload: payload, text: "")
        }
        let text = "session " + createdID
        return result(title: title, reference: reference, payload: created, text: text)
    }

    static func terminalSessionList(name: String) throws -> PommeOperationResult {
        try terminalSessionControl(name: name, operation: "terminal.list", payload: [:], title: "Sessions")
    }

    static func terminalSessionInspect(name: String, sessionID: String) throws -> PommeOperationResult {
        try terminalSessionControl(
            name: name,
            operation: "terminal.inspect",
            payload: ["sessionID": sessionID],
            title: "Session"
        )
    }

    static func terminalSessionLogs(name: String, sessionID: String, offset: UInt64) throws -> PommeOperationResult {
        try terminalSessionControl(
            name: name,
            operation: "terminal.logs",
            payload: ["sessionID": sessionID, "offset": Int64(offset)],
            title: "Logs"
        )
    }

    static func terminalSessionTerminate(name: String, sessionID: String, force: Bool) throws -> PommeOperationResult {
        try terminalSessionControl(
            name: name,
            operation: "terminal.terminate",
            payload: ["sessionID": sessionID, "force": force],
            title: "Terminate"
        )
    }

    static func terminalSessionDelete(name: String, sessionID: String) throws -> PommeOperationResult {
        try terminalSessionControl(
            name: name,
            operation: "terminal.delete",
            payload: ["sessionID": sessionID],
            title: "Delete"
        )
    }

    static func terminalSessionAttach(
        name: String,
        sessionID: String,
        offset: UInt64?,
        takeover: Bool
    ) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        let inspection = try PommeCore.sendControlObject(
            [
                "command": "terminal.session",
                "operation": "terminal.inspect",
                "sessionID": sessionID
            ],
            bundle: reference.bundle
        )
        if inspection["bootRole"] as? String == PommeDurableTerminalRole.recovery.rawValue {
            let notice = "Notice: this Recovery terminal runs as unrestricted root and is outside Pomme's transactional SIP/AMFI guarantees.\n"
            FileHandle.standardError.write(Data(notice.utf8))
        }
        var payload: [String: Any] = [
            "command": "terminal.session",
            "operation": "terminal.attach",
            "sessionID": sessionID,
            "takeover": takeover
        ]
        if let offset { payload["offset"] = Int64(offset) }
        var resultPayload = try PommeCore.sendTerminalAttachControlObject(payload, bundle: reference.bundle)
        resultPayload["operation"] = "terminal.attach"
        resultPayload["terminalAttachment"] = true
        return result(title: "Attach", reference: reference, payload: resultPayload, text: "")
    }

    private static func terminalSessionControl(
        name: String,
        operation: String,
        payload: [String: Any],
        title: String
    ) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        var request = payload
        request["command"] = "terminal.session"
        request["operation"] = operation
        var response = try PommeCore.sendControlObject(request, bundle: reference.bundle)
        response["operation"] = operation
        response["name"] = name
        let text: String
        switch operation {
        case "terminal.list":
            let sessions = response["sessions"] as? [[String: Any]] ?? []
            text = sessions.isEmpty
                ? "No terminal sessions."
                : sessions.map { terminalSessionSummary($0) }.joined(separator: "\n")
        case "terminal.inspect":
            text = terminalSessionSummary(response)
        case "terminal.logs":
            text = response["dataBase64"] as? String ?? ""
        default:
            text = response["error"] as? String ?? "OK"
        }
        return result(title: title, reference: reference, payload: response, text: text)
    }

    private static func terminalSessionSummary(_ session: [String: Any]) -> String {
        let id = stringValue(session["sessionID"])
        let state = stringValue(session["state"])
        let executable = stringValue(session["executable"] ?? session["path"])
        let offset = stringValue(session["transcriptOffset"] ?? session["outputLength"])
        return [id, state, executable, "offset=" + offset].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func guestRequest(
        name: String,
        request: GuestCLIRequest,
        title: String
    ) throws -> PommeOperationResult {
        if case .jobWait = request {
            // The wait acquires the bundle lease for each short exchange.
            // Holding it across the entire wait would prevent jobs kill.
            return try guestRequestUnchecked(name: name, request: request, title: title)
        }
        return try VMBundleMutationLease.withLease(name: name) { _ in
            try guestRequestUnchecked(name: name, request: request, title: title)
        }
    }

    private static func guestRequestUnchecked(name: String, request: GuestCLIRequest, title: String) throws -> PommeOperationResult {
        let reference = try namedReference(name)
        try request.validate()
        let transfer = PommeGuestFileTransfer { operation, payload in
            try performAuthenticatedAgentOperation(reference: reference, operation: operation, payload: payload)
        }
        switch request {
        case .copy(let copy):
            let receipt = try transfer.copy(copy)
            return result(title: title, reference: reference, payload: receipt.payload,
                          text: "Copied \(receipt.bytes) bytes.")
        case .cat(let cat):
            let payload = try transfer.cat(cat)
            return result(title: title, reference: reference, payload: payload, text: "")
        case .jobWait(let jobID, let timeout):
            let waiter = PommeGuestJobWait(perform: { poll, remaining in
                let deadline = ProcessInfo.processInfo.systemUptime + remaining
                return try VMBundleMutationLease.withLease(name: name) { _ in
                    try PommeCore.sendControlObject(poll.controlPayload, bundle: reference.bundle,
                                                   timeout: deadline - ProcessInfo.processInfo.systemUptime)
                }
            })
            let payload = try waiter.wait(jobID: jobID, timeout: timeout)
            return result(title: title, reference: reference, payload: payload,
                          text: agentResponseText(payload))
        default: break
        }
        var payload: [String: Any]
        if case .screenSharing = request {
            payload = try ScreenSharingAgentCapabilityGate.perform(
                describe: {
                    try performAuthenticatedAgentOperation(
                        reference: reference,
                        operation: "agent.describe"
                    )
                },
                dispatch: {
                    try PommeCore.sendControlObject(request.controlPayload, bundle: reference.bundle)
                }
            )
        } else {
            payload = try PommeCore.sendControlObject(request.controlPayload, bundle: reference.bundle)
        }
        if case .jobOutput = request {
            payload["operation"] = "process.output"
            return result(title: title, reference: reference, payload: payload,
                          text: agentResponseText(payload))
        }
        if case .jobList = request, payload["ok"] as? Bool == true {
            guard let response = payload["result"] as? [String: Any],
                  let jobs = response["jobs"] as? [[String: Any]] else {
                throw RunnerError.invalidControlResponse("Invalid background job list.")
            }
            var lines = jobs.map { job -> String in
                var summary = job
                summary["state"] = job["exited"] as? Bool == true ? "exited" : "running"
                return jobSummary(summary)
            }
            if lines.isEmpty { lines = ["No background jobs."] }
            if response["truncated"] as? Bool == true { lines.append("The job list is truncated.") }
            return result(title: title, reference: reference, payload: payload,
                          text: lines.joined(separator: "\n"))
        }
        let text = payload["stdout"] as? String
            ?? payload["error"] as? String
            ?? payload["state"] as? String
            ?? "OK"
        return result(title: title, reference: reference, payload: payload, text: text)
    }

    static func ui(name: String, request: GuestUIRequest) throws -> PommeOperationResult {
        try PommeUICapabilities.require(operation: request.operation)
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
        // Config members boot normally unless the config says `none` or `recovery`.
        let boot = plan.config.boot ?? .normal
        if boot != .none {
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
                : stringValue(payload["error"])
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
            try requireMDMWorkflowAvailable(reference: reference, lease: acquiredLease)
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
            try requireMDMWorkflowAvailable(reference: reference, lease: acquiredLease)
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

    /// Staging runs in the current signed guest bootstrap because older agents
    /// use Foundation path standardization that aliases /private/var on macOS 15.
    /// The bootstrap is separate from both the pinned agent and the privately
    /// signed enrollment helper, and exists only for this CLI transaction.
    private actor MDMStagingBootstrap {
        let reference: VMReference
        let requestID: String
        var transferred = false
        var terminationUnproven = false

        init(reference: VMReference, requestID: UUID = UUID(), transferred: Bool = false) {
            self.reference = reference
            self.requestID = requestID.uuidString.lowercased()
            self.transferred = transferred
        }
        var path: String { "/private/var/db/pomme-mdm-bootstrap-\(requestID).bin" }

        func prepare() async throws -> JSONValue {
            if !transferred {
                let artifact = try currentCanonicalPommeArtifact()
                let receipt = try await transferAuthenticatedFile(
                    reference: reference, source: artifact.source, destination: path,
                    maximumBytes: 128 * 1024 * 1024
                )
                transferred = true
                guard receipt.sha256 == artifact.sha256 else {
                    throw PommeMDMEnrollmentError.invalidTransfer
                }
                let mode = try await runMDMGuestProcess(
                    reference: reference, path: "/bin/chmod",
                    arguments: ["700", path], timeout: 15
                )
                guard mode.exitedSuccessfully, mode.stdout.isEmpty, mode.stderr.isEmpty else {
                    throw PommeMDMEnrollmentError.stagingPreparationFailed
                }
            }
            return try await invoke(action: "prepare")
        }

        func cleanup(_ profilePath: String) async throws -> JSONValue {
            guard transferred else { return .object(["removed": .bool(true)]) }
            return try await invoke(action: "cleanup", extra: [profilePath])
        }

        func remove() async throws {
            guard transferred else { return }
            guard !terminationUnproven else {
                throw PommeMDMEnrollmentError.helperProcessTerminationUnproven
            }
            let value = try await invoke(action: "remove")
            try PommeMDMEnrollmentAgentResponse.requireCleanup(value)
            transferred = false
        }

        private func invoke(action: String, extra: [String] = []) async throws -> JSONValue {
            let process: MDMGuestProcessResult
            do {
                process = try await runMDMGuestProcess(
                    reference: reference, path: "/usr/bin/env",
                    arguments: ["-i", path, "--pomme-mdm-staging-helper", requestID, action] + extra,
                    timeout: 30
                )
            } catch {
                if (error as? PommeMDMEnrollmentError) == .helperProcessTerminationUnproven {
                    terminationUnproven = true
                }
                throw error
            }
            guard process.exitedSuccessfully, process.stderr.isEmpty,
                  process.stdout.count <= 1024,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: process.stdout) else {
                PommeCore.log("MDM staging bootstrap rejected operation [action=\(action), exit=\(process.exitCode ?? -1)].")
                throw PommeMDMEnrollmentError.stagingPreparationFailed
            }
            return value
        }
    }

    static func mdmEnroll(
        name: String, profilePath: String, guestPath: String?, timeout: TimeInterval,
        enrollmentMode: MDMEnrollmentMode = .supervised, force: Bool = false
    ) async throws -> PommeOperationResult {
        guard timeout.isFinite, timeout >= 1, timeout <= 300 else {
            throw RunnerError.invalidControlCommand("mdm timeout must be between 1 and 300 seconds")
        }
        return try await VMBundleMutationLease.withLease(name: name) { lease in
            let reference = try namedReference(name)
            let profileURL = URL(fileURLWithPath: PommeCore.absoluteHostPath(profilePath))
            let plan = try PommeCore.securityProvisioningPlan(reference: reference)
            let metadata = try PommeCore.provisioningRuntimeMetadata(for: plan)
            guard let group = metadata.startupVolumeGroupUUID else {
                throw PommeMDMEnrollmentWorkflowError.journalIdentityMismatch
            }
            let identity = try PommeSecurityWorkflowIdentity.capture(
                vmName: name, bundle: reference.bundle, startupVolumeGroupUUID: group,
                immutableProvisioningPlanDigest: plan.digest
            )
            let store = PommeMDMEnrollmentJournalStore(bundleURL: reference.bundle.rootURL)
            let retained = try store.loadIfPresent(lease: lease)
            let source = Result { try MDMEnrollmentEvidenceParser.parseProfileIdentity(
                fromMobileconfig: readMDMSourceProfile(profileURL)) }
            let profile: MDMEnrollmentProfileIdentity
            let sourceError: (any Error)?
            switch source {
            case .success(let parsed):
                profile = parsed
                sourceError = nil
            case .failure(let error):
                guard let retained, retained.phase != .restorationComplete,
                      retained.identity == identity, retained.enrollmentMode == enrollmentMode else { throw error }
                profile = retained.profile
                sourceError = error
            }
            let childStore = PommeSecurityWorkflowJournalStore(bundleURL: reference.bundle.rootURL)
            if let child = try childStore.loadIfPresent(lease: lease),
               child.phase != .restorationComplete, child.phase != .preflightRejected {
                guard retained?.pendingChild == child.operation, child.identity.matches(identity) else {
                    throw PommeMDMWorkflowFailure.competingSecurityOperation
                }
            }
            let requestID = UUID()
            let workspace = try PommeMDMTemporaryHelperWorkspace(requestID: requestID)
            let profileDestination = try MDMProfileStaging.destination(requestedPath: guestPath)
            let journal = try store.begin(
                identity: identity, profile: profile, agentSHA256: plan.normalAgent.executableDigest,
                enrollmentMode: enrollmentMode,
                originalRunState: PommeCore.stableVMRunState(reference: reference),
                ownedArtifacts: [workspace.helperPath, workspace.requestPath, workspace.entitlementsPath,
                    "/private/var/db/pomme-mdm-bootstrap-\(requestID.uuidString.lowercased()).bin", profileDestination],
                lease: lease
            )
            let progress = PommeMDMWorkflowProgress(journal, store: store, lease: lease)
            let lastObservation = PommeMDMLastObservation()
            let artifacts = try mdmArtifacts(journal)
            if let guestPath, guestPath != artifacts.profile {
                throw PommeMDMEnrollmentWorkflowError.journalIdentityMismatch
            }
            let ensureNormal: @Sendable () async throws -> Void = {
                try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
                let description = try await authenticatedMDMAgentDescription(reference: reference, timeout: timeout)
                _ = try MDMEnrollmentAgentGate.verify(description, expectedExecutableDigest: journal.agentSHA256)
            }
            let observe: @Sendable () async throws -> PommeMDMObservedEnrollment = {
                if progress.journal.phase == .captured, !progress.journal.stagedProfileOwned {
                    try await requireMDMDestinationAbsent(reference: reference, destination: artifacts.profile)
                }
                let value = try await observeMDMEnrollment(reference: reference, timeout: timeout)
                await lastObservation.record(value, phase: progress.journal.phase)
                return value
            }
            let recovery = PommeSecurityRecoveryAdapter(
                reference: reference, volumeGroupUUID: group, factory: try currentRecoveryIntegrationFactory()
            )
            // The baseline read is the only Recovery session an enrollment
            // needs when SIP and AMFI already match what it requires. A normal
            // boot can report the same AMFI state, so prefer the agent and
            // defer to Recovery for agents pinned before that.
            let normalAgent = PommeSecurityNormalAgent(
                reference: reference, expectedExecutableDigest: plan.normalAgent.executableDigest)
            let observeAMFIBaseline: @Sendable () async throws -> PommeSecurityWorkflowState = {
                if let state = normalAgent.observeAMFIState(volumeGroupUUID: group) {
                    PommeCore.log("MDM baseline: read the AMFI configuration through the persistent normal agent.")
                    return state
                }
                return try await recovery.observe(.amfiDisable)
            }
            let dependencies = PommeMDMWorkflowDependencies(
                ensureNormal: ensureNormal,
                observe: observe,
                captureSecurity: {
                    let normal = try await observeMDMNormalSecurity(reference: reference, timeout: timeout)
                    let amfi = try await observeAMFIBaseline()
                    PommeCore.log("MDM baseline: sipDisabled=\(normal.sipDisabled), amfiDisabled=\(amfi.disabled), baselinePresent=\(amfi.baselinePresent), phase=\(amfi.baselinePhase ?? "none"), reconciliationRequired=\(amfi.reconciliationRequired).")
                    try PommeMDMWorkflowSecurityBaseline.validateOriginalAMFI(sipDisabled: normal.sipDisabled,
                        activeBootArguments: normal.arguments, state: amfi)
                    return .init(sipDisabled: normal.sipDisabled, amfiDisabled: amfi.disabled,
                        activeBootArguments: normal.arguments, configuredBootArguments: normal.configured)
                },
                runSecurity: { operation in
                    if operation == .amfiDisable,
                       try childStore.loadIfPresent(lease: lease)?.operation != .amfiDisable {
                        // Revalidate an enabled AMFI receipt after SIP has
                        // reached its prerequisite state. This check is before
                        // child creation or any AMFI mutation; failure can
                        // still restore SIP without attempting an AMFI enable.
                        do {
                            let state = try await recovery.observe(.amfiDisable)
                            guard !state.disabled, !state.baselinePresent, !state.reconciliationRequired else {
                                throw PommeMDMWorkflowFailure.securityBaselineUnsupported
                            }
                        } catch {
                            try progress.record(pendingChild: .some(nil), amfiChangeRequested: false)
                            throw error
                        }
                    }
                    try await PommeMDMChildScope.$vmName.withValue(name) {
                        if operation.isSIP {
                            _ = try await sipWorkflow(name: name, action: operation.requestsDisabled ? .disable : .enable,
                                finalState: .normal, force: force, lease: lease)
                        } else {
                            _ = try await amfiWorkflow(name: name, action: operation.requestsDisabled ? .disable : .enable,
                                finalState: .normal, force: force, lease: lease)
                        }
                    }
                },
                enroll: {
                    try await cleanupMDMArtifacts(reference: reference, journal: progress.journal)
                    _ = try await mdmHelperEnrollment(
                        name: name, profilePath: profileURL.path, guestPath: artifacts.profile,
                        timeout: timeout, enrollmentMode: enrollmentMode, lease: lease,
                        operationID: artifacts.workspace.requestID, progress: progress
                    )
                },
                cleanup: { try await cleanupMDMArtifacts(reference: reference, journal: progress.journal) },
                requireHelperStopped: { try await requireMDMHelpersStopped(reference: reference, journal: progress.journal) },
                verifySecurity: { baseline in
                    let observed = try await observeMDMNormalSecurity(reference: reference, timeout: timeout)
                    guard observed.sipDisabled == baseline.sipWasDisabled,
                          observed.arguments == baseline.normalBootArguments,
                          observed.configured == baseline.configuredBootArguments else {
                        throw PommeMDMWorkflowFailure.restorationIncomplete
                    }
                },
                restoreRunState: { state in
                    try await PommeCore.restoreStableVMRunState(state, reference: reference)
                    guard try PommeCore.provesStableVMRunState(state, reference: reference) else {
                        throw PommeMDMWorkflowFailure.restorationIncomplete
                    }
                },
                awaitEnrollment: {
                    let deadline = Date().addingTimeInterval(timeout)
                    while true {
                        do {
                            let value = try await observeMDMEnrollment(reference: reference,
                                timeout: max(0, deadline.timeIntervalSinceNow))
                            await lastObservation.record(value, phase: progress.journal.phase)
                            try value.requireRequestedState(profile: profile, mode: enrollmentMode)
                            return value
                        } catch {
                            guard Date() < deadline else { throw PommeMDMWorkflowFailure.evidenceUnavailable }
                            try Task.checkCancellation()
                            try await Task.sleep(nanoseconds: 250_000_000)
                        }
                    }
                },
                reportSecurityFailure: { failure in
                    await lastObservation.recordFailure(failure)
                    PommeCore.log("MDM security workflow failure: \(failure.localizedDescription)")
                }
            )
            let observed: PommeMDMObservedEnrollment
            do { observed = try await PommeMDMWorkflowExecution(progress: progress, dependencies: dependencies).run(preflightError: sourceError) }
            catch {
                let retained = progress.journal
                var details: [String: Any] = [
                    "enrollmentMode": enrollmentMode.rawValue, "profileIdentifier": profile.identifier,
                    "enrolled": NSNull(), "userApproved": NSNull(), "supervised": NSNull(),
                    "enrollmentOutcome": retained.enrollmentDispatched && !retained.enrollmentVerified ? "unknown" : "incomplete",
                    "securityRestored": [.securityRestored, .runStateRestorationIntent, .restorationComplete].contains(retained.phase),
                    "runStateRestored": (try? PommeCore.provesStableVMRunState(retained.originalRunState, reference: reference)) == true,
                    "artifactsCleaned": retained.phase == .restorationComplete,
                    "phase": retained.phase.rawValue
                ]
                if let (last, phase) = await lastObservation.snapshot() {
                    details["lastObserved"] = ["enrolled": last.status.enrolled, "userApproved": last.status.userApproved,
                        "supervised": last.supervised, "phase": phase.rawValue]
                }
                let securityFailures = await lastObservation.securityFailures()
                if !securityFailures.isEmpty {
                    details["securityFailures"] = securityFailures.map(\.localizedDescription)
                }
                return mdmResult(title: "MDM enrollment", operation: "mdm", reference: reference, ok: false,
                    agent: [:], steps: [], result: details, error: error.localizedDescription)
            }
            return mdmResult(title: "MDM enrollment", operation: "mdm", reference: reference, ok: true,
                agent: ["role": "normal", "protocol": PommeAgentProtocol.name, "version": PommeAgentProtocol.version],
                steps: [], result: [
                    "enrollmentMode": enrollmentMode.rawValue, "profileIdentifier": profile.identifier,
                    "enrolled": observed.status.enrolled, "userApproved": observed.status.userApproved,
                    "supervised": observed.supervised, "securityRestored": true,
                    "runStateRestored": true, "artifactsCleaned": true
                ])
        }
    }

    private static func requireMDMWorkflowAvailable(reference: VMReference, lease: VMBundleMutationLease) throws {
        guard PommeMDMChildScope.vmName != reference.displayName else { return }
        if let journal = try PommeMDMEnrollmentJournalStore(bundleURL: reference.bundle.rootURL).loadIfPresent(lease: lease),
           journal.phase != .restorationComplete || (journal.enrollmentDispatched && !journal.enrollmentVerified) {
            throw PommeMDMWorkflowFailure.competingSecurityOperation
        }
    }

    private static func readMDMSourceProfile(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PommeMDMEnrollmentError.invalidProfile }
        defer { _ = Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0,
              before.st_size <= off_t(PommeMDMTemporaryHelperRequest.maximumProfileBytes) else {
            throw PommeMDMEnrollmentError.invalidProfile
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= PommeMDMTemporaryHelperRequest.maximumProfileBytes else {
                throw PommeMDMEnrollmentError.invalidProfile
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, data.count == Int(before.st_size),
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw PommeMDMEnrollmentError.invalidProfile
        }
        return data
    }

    private static func mdmArtifacts(_ journal: PommeMDMEnrollmentJournal) throws -> (
        workspace: PommeMDMTemporaryHelperWorkspace, profile: String, bootstrap: String
    ) {
        let prefix = "/private/var/db/pomme-mdm-bootstrap-"
        guard let bootstrap = journal.ownedArtifacts.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".bin") }),
              let id = UUID(uuidString: String(bootstrap.dropFirst(prefix.count).dropLast(4))) else {
            throw PommeMDMEnrollmentWorkflowError.malformedJournal
        }
        let workspace = try PommeMDMTemporaryHelperWorkspace(requestID: id)
        let profiles = journal.ownedArtifacts.filter { $0 != bootstrap && !workspace.owns($0) }
        guard journal.ownedArtifacts.count == 5, profiles.count == 1,
              try MDMProfileStaging.destination(requestedPath: profiles[0]) == profiles[0],
              Set(journal.ownedArtifacts) == Set([
                bootstrap, workspace.helperPath, workspace.entitlementsPath, workspace.requestPath, profiles[0]
              ]) else { throw PommeMDMEnrollmentWorkflowError.malformedJournal }
        return (workspace, profiles[0], bootstrap)
    }

    private static func observeMDMEnrollment(reference: VMReference, timeout: TimeInterval) async throws -> PommeMDMObservedEnrollment {
        let deadline = Date().addingTimeInterval(timeout)
        func capture(_ path: String, _ arguments: [String], acceptsDaemonDiagnostic: Bool = false) async throws -> Data {
            guard deadline.timeIntervalSinceNow >= 1 else { throw PommeMDMWorkflowFailure.evidenceUnavailable }
            let process = try await runMDMGuestProcess(reference: reference, path: path,
                arguments: arguments, timeout: min(timeout, deadline.timeIntervalSinceNow))
            let daemonDiagnostic = Data("[ERROR] Unable to target 'local user' via XPC when running as daemon\n".utf8)
            guard process.exitedSuccessfully,
                  process.stderr.isEmpty || (acceptsDaemonDiagnostic && process.stderr == daemonDiagnostic) else {
                throw PommeMDMWorkflowFailure.evidenceUnavailable
            }
            return process.stdout
        }
        let status = try MDMEnrollmentEvidenceParser.parseEnrollmentStatus(
            fromProfilesStatus: await capture("/usr/bin/profiles", ["status", "-type", "enrollment"]))
        let profiles = try await capture("/usr/bin/profiles", ["show", "-type", "configuration", "-output", "stdout-xml"])
        let installed: MDMInstalledProfileIdentity?
        do { installed = try MDMEnrollmentEvidenceParser.parseInstalledProfileIdentity(fromProfilesShow: profiles) }
        catch MDMEnrollmentEvidenceError.missingEvidence {
            // Explicit, well-formed empty device profile output can establish
            // absence before a fresh install, but never successful enrollment.
            var format = PropertyListSerialization.PropertyListFormat.openStep
            guard !status.enrolled,
                  let root = try? PropertyListSerialization.propertyList(from: profiles, options: [], format: &format) as? [String: Any],
                  format == .xml, root.isEmpty || root["_computerlevel"] is [Any] else { throw PommeMDMWorkflowFailure.evidenceUnavailable }
            installed = nil
        }
        let supervision = try MDMEnrollmentEvidenceParser.parseDeviceSupervision(
            fromMDMClient: await capture("/usr/libexec/mdmclient", ["QueryDeviceInformation"], acceptsDaemonDiagnostic: true))
        return .init(installed: installed, status: status, supervised: supervision.isSupervised)
    }

    private static func observeMDMNormalSecurity(reference: VMReference, timeout: TimeInterval) async throws -> (sipDisabled: Bool, arguments: Data, configured: Data) {
        let sip = try await runMDMGuestProcess(reference: reference, path: "/usr/bin/csrutil", arguments: ["status"], timeout: timeout)
        let args = try await runMDMGuestProcess(reference: reference, path: "/usr/sbin/sysctl", arguments: ["-n", "kern.bootargs"], timeout: timeout)
        let nvram = try await runMDMGuestProcess(reference: reference, path: "/usr/sbin/nvram", arguments: ["-xp"], timeout: timeout)
        guard sip.exitedSuccessfully, sip.stderr.isEmpty, args.exitedSuccessfully, args.stderr.isEmpty,
              args.stdout.last == 0x0a, !args.stdout.contains(0),
              sip.stdout == Data("System Integrity Protection status: enabled.\n".utf8)
                || sip.stdout == Data("System Integrity Protection status: disabled.\n".utf8) else {
            throw PommeMDMWorkflowFailure.securityBaselineUnsupported
        }
        var format = PropertyListSerialization.PropertyListFormat.openStep
        guard nvram.exitedSuccessfully, nvram.stderr.isEmpty,
              let root = try? PropertyListSerialization.propertyList(from: nvram.stdout, options: [], format: &format) as? [String: Any],
              format == .xml else { throw PommeMDMWorkflowFailure.securityBaselineUnsupported }
        let configuredBytes: Data?
        switch root["boot-args"] {
        case nil: configuredBytes = nil
        case let data as Data: configuredBytes = data
        case let string as String: configuredBytes = Data(string.utf8)
        default: throw PommeMDMWorkflowFailure.securityBaselineUnsupported
        }
        let active = Data(args.stdout.dropLast())
        // A pending boot-argument change would make a reboot change the
        // captured security state. Reject it before any security mutation.
        guard (configuredBytes ?? Data()) == active else {
            throw PommeMDMWorkflowFailure.securityBaselineUnsupported
        }
        let configured = try PommeProvisioningCoding.encode(
            configuredBytes.map { JSONValue.string($0.base64EncodedString()) } ?? .null)
        return (sip.stdout == Data("System Integrity Protection status: disabled.\n".utf8), active, configured)
    }

    private static func requireMDMHelpersStopped(reference: VMReference, journal: PommeMDMEnrollmentJournal) async throws {
        let state = try PommeCore.stableVMRunState(reference: reference)
        guard state == .running(.normal) || state == .paused(previousBootMode: .normal) else { return }
        if state == .paused(previousBootMode: .normal) {
            try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
        }
        _ = try MDMEnrollmentAgentGate.verify(
            await authenticatedMDMAgentDescription(reference: reference, timeout: 30), expectedExecutableDigest: journal.agentSHA256)
        let artifacts = try mdmArtifacts(journal)
        for path in [artifacts.workspace.helperPath, artifacts.bootstrap] {
            let process = try await runMDMGuestProcess(reference: reference, path: "/usr/bin/pgrep", arguments: ["-f", path], timeout: 15)
            guard process.exited, process.exitCode == 1, process.stderr.isEmpty, process.stdout.isEmpty else {
                throw PommeMDMEnrollmentError.helperProcessTerminationUnproven
            }
        }
    }

    private static func cleanupMDMArtifacts(reference: VMReference, journal: PommeMDMEnrollmentJournal) async throws {
        let artifacts = try mdmArtifacts(journal)
        try await PommeCore.restoreStableVMRunState(.running(.normal), reference: reference)
        _ = try MDMEnrollmentAgentGate.verify(
            await authenticatedMDMAgentDescription(reference: reference, timeout: 30), expectedExecutableDigest: journal.agentSHA256)
        func exists(_ path: String) async throws -> Bool {
            for flag in ["-e", "-L"] {
                let result = try await runMDMGuestProcess(reference: reference, path: "/bin/test", arguments: [flag, path], timeout: 15)
                guard result.exited, result.exitCode == 0 || result.exitCode == 1, result.stdout.isEmpty, result.stderr.isEmpty else {
                    throw PommeMDMEnrollmentError.cleanupFailed
                }
                if result.exitCode == 0 { return true }
            }
            return false
        }
        var present: [String] = []
        let ownedPaths = journal.ownedArtifacts.filter { $0 != artifacts.profile || journal.stagedProfileOwned }
        for path in ownedPaths where try await exists(path) { present.append(path) }
        guard !present.isEmpty else { return }
        let hasBootstrap = present.contains(artifacts.bootstrap)
        if hasBootstrap {
            let signature = try await runMDMGuestProcess(reference: reference, path: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "-R", PommeAgentArtifactStore.signingRequirement, artifacts.bootstrap], timeout: 30)
            guard signature.exitedSuccessfully else { throw PommeMDMEnrollmentError.cleanupFailed }
            let chmod = try await runMDMGuestProcess(reference: reference, path: "/bin/chmod", arguments: ["700", artifacts.bootstrap], timeout: 15)
            guard chmod.exitedSuccessfully else { throw PommeMDMEnrollmentError.cleanupFailed }
        }
        let staging = MDMStagingBootstrap(reference: reference, requestID: artifacts.workspace.requestID, transferred: hasBootstrap)
        if !hasBootstrap { _ = try await staging.prepare() }
        for path in present where path != artifacts.bootstrap {
            if path == artifacts.workspace.helperPath {
                let chmod = try await runMDMGuestProcess(reference: reference, path: "/bin/chmod", arguments: ["600", path], timeout: 15)
                guard chmod.exitedSuccessfully else { throw PommeMDMEnrollmentError.cleanupFailed }
            }
            try PommeMDMEnrollmentAgentResponse.requireCleanup(await staging.cleanup(path))
        }
        try await staging.remove()
        for path in ownedPaths where try await exists(path) { throw PommeMDMEnrollmentError.cleanupFailed }
    }

    private static func mdmHelperEnrollment(
        name: String,
        profilePath: String,
        guestPath: String?,
        timeout: TimeInterval,
        enrollmentMode: MDMEnrollmentMode,
        lease: VMBundleMutationLease,
        operationID: UUID,
        progress: PommeMDMWorkflowProgress
    ) async throws -> PommeOperationResult {
        guard timeout.isFinite, timeout >= 1, timeout <= 300 else {
            throw RunnerError.invalidControlCommand("mdm.enroll timeout")
        }
        return try await VMBundleMutationLease.withLease(name: name, inherited: lease) { _ in
            let reference = try namedReference(name)
            let profileURL = URL(fileURLWithPath: PommeCore.absoluteHostPath(profilePath)).standardizedFileURL
            guard regularFile(profileURL) else {
                throw RunnerError.hostCommandFailed("The MDM profile does not exist.")
            }
            let expectedDigest = try PommeCore.expectedProvisionedAgentDigest(
                reference: reference
            )
            let workspace = try PommeMDMTemporaryHelperWorkspace(requestID: operationID)
            let destination = try MDMProfileStaging.destination(
                requestedPath: guestPath
                    ?? "\(MDMProfileStaging.guestDirectory)/profile-\(operationID.uuidString.lowercased()).mobileconfig"
            )
            let staging = MDMStagingBootstrap(reference: reference, requestID: operationID)
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
                    switch operation {
                    case .prepareStaging: return try await staging.prepare()
                    case .cleanup(let path):
                        guard progress.journal.stagedProfileOwned else {
                            // A rejected pre-existing custom destination was
                            // never claimed by this transaction.
                            return .object(["removed": .bool(true)])
                        }
                        return try await staging.cleanup(path)
                    default:
                        return try performAuthenticatedAgentOperation(
                            reference: reference, operation: operation.wireName,
                            payload: try operation.payload()
                        )
                    }
                },
                transferProfile: { source, destination in
                    try await requireMDMDestinationAbsent(reference: reference, destination: destination)
                    try progress.record(stagedProfileOwned: true)
                    let receipt = try await transferMDMProfile(
                        reference: reference,
                        source: source,
                        destination: destination
                    )
                    guard receipt.sha256 == progress.journal.profile.digest else {
                        throw PommeMDMEnrollmentError.invalidTransfer
                    }
                    return receipt
                }
            )
            let temporaryHelper = makeLiveMDMTemporaryHelper(
                reference: reference,
                expectedExecutableDigest: expectedDigest,
                staging: staging,
                workspace: workspace,
                onLaunch: { try progress.record(enrollmentDispatched: true) }
            )
            let state = makeLiveMDMStatePort(reference: reference)
            let transaction = PommeMDMEnrollmentTransaction(
                agent: transport,
                state: state,
                profileURL: profileURL,
                guestPath: destination,
                timeout: timeout,
                enrollmentMode: enrollmentMode,
                expectedExecutableDigest: expectedDigest,
                temporaryHelper: temporaryHelper
            )
            let enrolled: PommeMDMEnrollmentTransactionResult
            do {
                enrolled = try await transaction.execute()
            } catch {
                let original = error
                if (error as? PommeMDMEnrollmentError) == .helperProcessTerminationUnproven { throw error }
                do { try await staging.remove() }
                catch { throw PommeMDMEnrollmentError.cleanupFailed }
                throw original
            }
            try await staging.remove()
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
        if operation == "mdm.staging.prepare" || operation == "mdm.staging.cleanup" {
            let accepted = response["ok"] as? Bool == true
            let resultPresent = response["result"] != nil
            PommeCore.log("MDM staging receipt [operation=\(operation), accepted=\(accepted), resultPresent=\(resultPresent)].")
        }
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
    ) async throws -> PommeMDMProfileTransferReceipt {
        guard try MDMProfileStaging.destination(requestedPath: destination) == destination else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
        let generic = try await transferAuthenticatedFile(
            reference: reference,
            source: source,
            destination: destination,
            maximumBytes: PommeMDMTemporaryHelperRequest.maximumProfileBytes
        )
        return try .init(
            destination: generic.destination,
            bytes: generic.bytes,
            sha256: generic.sha256
        )
    }

    private static func transferMDMHelperFile(
        reference: VMReference,
        source: URL,
        destination: String
    ) async throws -> PommeMDMAuthenticatedFileTransferReceipt {
        guard PommeMDMTemporaryHelperWorkspace.isArtifactPath(destination) else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
        return try await transferAuthenticatedFile(
            reference: reference,
            source: source,
            destination: destination,
            maximumBytes: 128 * 1024 * 1024
        )
    }

    private static func transferMDMHelperData(
        reference: VMReference,
        data: Data,
        destination: String
    ) async throws -> PommeMDMAuthenticatedFileTransferReceipt {
        guard PommeMDMTemporaryHelperWorkspace.isArtifactPath(destination),
              !data.isEmpty,
              data.count <= PommeAgentProtocol.maximumFrameBytes * 64 else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
        var remoteFileID: String?
        do {
            try await requireMDMDestinationAbsent(
                reference: reference,
                destination: destination
            )
            let fileID = try openMDMStageFile(reference: reference, destination: destination)
            remoteFileID = fileID
            var hasher = SHA256()
            var transferred = 0
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + PommeAgentProtocol.maximumFileChunkBytes)
                let chunk = data.subdata(in: offset..<end)
                hasher.update(data: chunk)
                try requireMDMWrite(
                    try performAuthenticatedAgentOperation(
                        reference: reference,
                        operation: "file.write",
                        payload: .object([
                            "fileID": .string(fileID),
                            "dataBase64": .string(chunk.base64EncodedString())
                        ])
                    ),
                    count: chunk.count
                )
                offset = end
                transferred += chunk.count
            }
            try finishMDMTransfer(
                reference: reference,
                fileID: fileID,
                bytes: transferred,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
            let digest = PommeMDMTemporaryHelperRequest.digest(of: data)
            remoteFileID = nil
            return try .init(destination: destination, bytes: data.count, sha256: digest)
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

    private static func transferAuthenticatedFile(
        reference: VMReference,
        source: URL,
        destination: String,
        maximumBytes: Int
    ) async throws -> PommeMDMAuthenticatedFileTransferReceipt {
        guard isAllowedMDMTransferPath(destination) else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PommeMDMEnrollmentError.invalidProfile }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0,
              before.st_size <= off_t(maximumBytes) else {
            throw PommeMDMEnrollmentError.invalidProfile
        }

        var remoteFileID: String?
        do {
            try await requireMDMDestinationAbsent(
                reference: reference,
                destination: destination
            )
            let fileID = try openMDMStageFile(reference: reference, destination: destination)
            remoteFileID = fileID
            var hasher = SHA256()
            var transferred = 0
            var buffer = [UInt8](repeating: 0, count: PommeAgentProtocol.maximumFileChunkBytes)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw PommeMDMEnrollmentError.transferFailed }
                if count == 0 { break }
                let chunk = Data(buffer.prefix(count))
                hasher.update(data: chunk)
                try requireMDMWrite(
                    try performAuthenticatedAgentOperation(
                        reference: reference,
                        operation: "file.write",
                        payload: .object([
                            "fileID": .string(fileID),
                            "dataBase64": .string(chunk.base64EncodedString())
                        ])
                    ),
                    count: count
                )
                transferred += count
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
            try finishMDMTransfer(
                reference: reference,
                fileID: fileID,
                bytes: transferred,
                sha256: digest
            )
            remoteFileID = nil
            return try .init(destination: destination, bytes: transferred, sha256: digest)
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

    private static func isAllowedMDMTransferPath(_ path: String) -> Bool {
        (try? MDMProfileStaging.destination(requestedPath: path)) == path
            || PommeMDMTemporaryHelperWorkspace.isArtifactPath(path)
            || PommeMDMStagingHelper.isBootstrapPath(path)
    }

    /// The generic agent commit operation deliberately supports replacing an
    /// existing regular file. MDM destinations are one-shot artifacts, so
    /// reject a known existing path through the authenticated guest process
    /// boundary before opening the stage. Generated UUID paths keep the
    /// remaining preflight-to-commit interval scoped to this CLI lease; the
    /// agent commit still refuses symlinks.
    private static func requireMDMDestinationAbsent(
        reference: VMReference,
        destination: String
    ) async throws {
        for flag in ["-e", "-L"] {
            let result = try await runMDMGuestProcess(
                reference: reference,
                path: "/bin/test",
                arguments: [flag, destination],
                timeout: 15
            )
            guard result.exited,
                  !result.timedOut,
                  !result.cancelled,
                  result.outputComplete,
                  !result.stdoutTruncated,
                  !result.stderrTruncated,
                  result.signal == nil,
                  result.stdout.isEmpty,
                  result.stderr.isEmpty,
                  result.exitCode == 1 else {
                throw PommeMDMEnrollmentError.invalidTransfer
            }
        }
    }

    private static func openMDMStageFile(
        reference: VMReference,
        destination: String
    ) throws -> String {
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
        return fileID
    }

    private static func requireMDMWrite(_ value: JSONValue, count: Int) throws {
        guard let object = value.objectValue,
              Set(object.keys) == ["count"],
              object["count"] == .integer(Int64(count)) else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
    }

    private static func finishMDMTransfer(
        reference: VMReference,
        fileID: String,
        bytes: Int,
        sha256: String
    ) throws {
        let flushed = try performAuthenticatedAgentOperation(
            reference: reference,
            operation: "file.flush",
            payload: .object(["fileID": .string(fileID)])
        )
        guard flushed == .object([:]) else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
        let committed = try performAuthenticatedAgentOperation(
            reference: reference,
            operation: "file.commit",
            payload: .object([
                "fileID": .string(fileID),
                "expectedBytes": .integer(Int64(bytes)),
                "expectedSHA256": .string(sha256)
            ])
        )
        guard committed == .object([
            "committed": .bool(true),
            "bytes": .integer(Int64(bytes)),
            "sha256": .string(sha256)
        ]) else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
    }

    private static let mdmTemporaryHelperIdentifier = "com.github.weswhet.pomme.mdm-helper"
    private static let mdmTemporaryHelperOutputLimit = 64 * 1024

    private struct MDMGuestProcessResult: Sendable {
        let jobID: UUID
        let exited: Bool
        let exitCode: Int32?
        let signal: Int32?
        let timedOut: Bool
        let cancelled: Bool
        let outputComplete: Bool
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
        let stdout: Data
        let stderr: Data

        var exitedSuccessfully: Bool {
            exited && !timedOut && !cancelled && outputComplete
                && !stdoutTruncated && !stderrTruncated
                && exitCode == 0 && signal == nil
        }
    }

    /// Resolves the executable that invoked this CLI, then verifies its exact
    /// Pomme Developer ID requirement and stable bytes before it enters guest
    /// staging. The pinned guest-agent digest is intentionally not used as a
    /// source selector: old VMs may retain an earlier agent without the
    /// temporary helper entrypoint.
    private static func currentCanonicalPommeArtifact() throws -> PommeMDMTemporaryHelperArtifact {
        var size: UInt32 = 0
        guard _NSGetExecutablePath(nil, &size) == -1, size > 0 else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard buffer.withUnsafeMutableBufferPointer({ pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size) == 0
        }) else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let source = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard source.path.hasPrefix("/"), source.path == source.standardizedFileURL.path else {
            throw PommeMDMEnrollmentError.invalidRequest
        }

        var before = stat()
        guard lstat(source.path, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_mode & 0o022 == 0,
              before.st_size > 0,
              before.st_size <= off_t(PommeAgentArtifactStore.maximumExecutableBytes) else {
            throw PommeMDMEnrollmentError.invalidRequest
        }

        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(source as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(
                  PommeAgentArtifactStore.signingRequirement as CFString,
                  [],
                  &requirement
              ) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                  code,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                  requirement
              ) == errSecSuccess else {
            throw PommeMDMEnrollmentError.invalidRequest
        }

        let descriptor = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PommeMDMEnrollmentError.invalidRequest }
        defer { _ = Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino,
              opened.st_size == before.st_size else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        var data = Data(count: Int(opened.st_size))
        let read = data.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return offset }
                offset += count
            }
            return offset
        }
        var after = stat()
        guard read == data.count,
              lstat(source.path, &after) == 0,
              after.st_dev == opened.st_dev,
              after.st_ino == opened.st_ino,
              after.st_size == opened.st_size else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        return try .init(source: source, sha256: PommeMDMTemporaryHelperRequest.digest(of: data))
    }

    private static func makeLiveMDMTemporaryHelper(
        reference: VMReference,
        expectedExecutableDigest: String,
        staging: MDMStagingBootstrap,
        workspace: PommeMDMTemporaryHelperWorkspace,
        onLaunch: @escaping @Sendable () throws -> Void
    ) -> any PommeMDMTemporaryHelperTransport {
        PommeMDMTemporaryHelperHost(dependencies: .init(
            canonicalArtifact: {
                try currentCanonicalPommeArtifact()
            },
            prepare: { _ in
                let value = try await staging.prepare()
                try PommeMDMEnrollmentAgentResponse.requireStagingReady(value)
            },
            transferFile: { source, destination in
                try await transferMDMHelperFile(
                    reference: reference,
                    source: source,
                    destination: destination
                )
            },
            transferData: { data, destination in
                try await transferMDMHelperData(
                    reference: reference,
                    data: data,
                    destination: destination
                )
            },
            resignAndVerify: { workspace in
                PommeCore.log("MDM helper phase: guest signing.")
                let digest = try await resignAndVerifyMDMHelper(reference: reference, workspace: workspace)
                PommeCore.log("MDM helper phase: guest signature verified.")
                return digest
            },
            launch: { workspace, request, requestSHA256, timeout in
                PommeCore.log("MDM helper phase: launch.")
                try onLaunch()
                let process: MDMGuestProcessResult
                do {
                    process = try await runMDMGuestProcess(
                        reference: reference,
                        path: "/usr/bin/env",
                        arguments: [
                            "-i",
                            workspace.helperPath,
                            PommeMDMPrivateHelper.flag,
                            request.requestID,
                            requestSHA256,
                        ],
                        timeout: timeout
                    )
                } catch {
                    // The request may have reached the helper even when the
                    // foreground transport failed to return a terminal
                    // response. Treat every post-launch transport failure as
                    // an unknown enrollment outcome.
                    if (error as? PommeMDMEnrollmentError)
                        == .helperProcessTerminationUnproven {
                        throw error
                    }
                    throw PommeMDMEnrollmentError.enrollmentOutcomeUnknown
                }
                guard process.stderr.isEmpty,
                      process.stdout.count <= mdmTemporaryHelperOutputLimit,
                      process.exited,
                      !process.timedOut,
                      !process.cancelled,
                      process.outputComplete,
                      !process.stdoutTruncated,
                      !process.stderrTruncated,
                      process.signal == nil else {
                    // Once the signed helper has been launched, a timeout,
                    // signal, or incomplete response cannot prove whether
                    // finalInstallProfile committed. Keep that outcome
                    // distinct so callers verify state before retrying.
                    throw PommeMDMEnrollmentError.enrollmentOutcomeUnknown
                }
                let lines = process.stdout.split(
                    separator: 0x0a,
                    omittingEmptySubsequences: true
                )
                guard lines.count == 1,
                      let value = try? JSONDecoder().decode(
                          JSONValue.self,
                          from: Data(lines[0])
                      ) else {
                    throw PommeMDMEnrollmentError.enrollmentOutcomeUnknown
                }
                if process.exitCode != 0 {
                    guard case .object(let object) = value,
                          object["completed"] == .bool(false) else {
                        throw PommeMDMEnrollmentError.enrollmentOutcomeUnknown
                    }
                }
                if let code = value.objectValue?["errorCode"]?.stringValue,
                   PommeMDMPrivateHelper.FailureCode(rawValue: code) != nil {
                    PommeCore.log("MDM helper closed failure: \(code).")
                }
                return value
            },
            cleanup: { workspace in
                var failed = false
                do {
                    _ = try await runMDMGuestProcess(
                        reference: reference,
                        path: "/bin/chmod",
                        arguments: ["600", workspace.helperPath],
                        timeout: 15
                    )
                } catch {
                    failed = true
                }

                // Each artifact is a known UUID-derived direct child. The
                // authenticated staging operation proves owner, group, mode,
                // regular-file identity, unlink, fsync, and post-removal
                // absence; no recursive or generic delete is reachable here.
                for path in [workspace.helperPath, workspace.entitlementsPath, workspace.requestPath] {
                    do {
                        let value = try await staging.cleanup(path)
                        try PommeMDMEnrollmentAgentResponse.requireCleanup(value)
                    } catch {
                        failed = true
                    }
                }
                if failed { throw PommeMDMEnrollmentError.cleanupFailed }
            },
            now: Date.init
        ), workspace: workspace)
    }

    private static func resignAndVerifyMDMHelper(
        reference: VMReference,
        workspace: PommeMDMTemporaryHelperWorkspace
    ) async throws -> String {
        let sign = try await runMDMGuestProcess(
            reference: reference,
            path: "/usr/bin/codesign",
            arguments: [
                "--force", "--sign", "-",
                "--identifier", mdmTemporaryHelperIdentifier,
                "--options", "runtime",
                "--entitlements", workspace.entitlementsPath,
                workspace.helperPath,
            ],
            timeout: 30
        )
        PommeCore.log("MDM helper sign receipt [accepted=\(sign.exitedSuccessfully)].")
        guard sign.exitedSuccessfully else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }

        let verify = try await runMDMGuestProcess(
            reference: reference,
            path: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", "--all-architectures", workspace.helperPath],
            timeout: 30
        )
        PommeCore.log("MDM helper signature receipt [accepted=\(verify.exitedSuccessfully)].")
        guard verify.exitedSuccessfully else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }

        let entitlements = try await runMDMGuestProcess(
            reference: reference,
            path: "/usr/bin/codesign",
            arguments: ["--display", "--entitlements", "/dev/stdout", "--xml", workspace.helperPath],
            timeout: 30
        )
        PommeCore.log("MDM helper entitlements receipt [accepted=\(entitlements.exitedSuccessfully), stderrMatched=\(exactMDMHelperEntitlementStderr(entitlements.stderr, helperPath: workspace.helperPath)), entitlementsMatched=\(exactMDMHelperEntitlements(entitlements.stdout))].")
        guard entitlements.exitedSuccessfully,
              exactMDMHelperEntitlementStderr(
                  entitlements.stderr,
                  helperPath: workspace.helperPath
              ),
              exactMDMHelperEntitlements(entitlements.stdout) else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }

        let details = try await runMDMGuestProcess(
            reference: reference,
            path: "/usr/bin/codesign",
            arguments: ["--display", "--verbose=4", workspace.helperPath],
            timeout: 30
        )
        PommeCore.log("MDM helper signing details receipt [accepted=\(details.exitedSuccessfully), matched=\(validMDMHelperSigningDetails(details.stdout, stderr: details.stderr))].")
        guard details.exitedSuccessfully,
              validMDMHelperSigningDetails(details.stdout, stderr: details.stderr) else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }

        let chmod = try await runMDMGuestProcess(
            reference: reference,
            path: "/bin/chmod",
            arguments: ["700", workspace.helperPath],
            timeout: 15
        )
        guard chmod.exitedSuccessfully else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }

        let digest = try await runMDMGuestProcess(
            reference: reference,
            path: "/sbin/sha256",
            arguments: ["-q", workspace.helperPath],
            timeout: 30
        )
        guard digest.exitedSuccessfully,
              digest.stderr.isEmpty,
              let value = String(data: digest.stdout, encoding: .utf8)?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              PommeMDMTemporaryHelperRequest.isDigest(value) else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        return value
    }

    private static func exactMDMHelperEntitlements(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ),
        let values = plist as? [String: Any],
        Set(values.keys) == PommeMDMTemporaryHelperHost.requiredPrivateEntitlements,
        values.values.allSatisfy({ ($0 as? Bool) == true }) else {
            return false
        }
        return true
    }

    static func validMDMHelperSigningDetails(_ stdout: Data, stderr: Data) -> Bool {
        let text = String(
            data: stdout + stderr,
            encoding: .utf8
        ) ?? ""
        guard text.contains("Identifier=\(mdmTemporaryHelperIdentifier)"),
              text.range(of: #"(?m)^CodeDirectory\b[^\r\n]*\bflags=0x[0-9a-fA-F]+\([^\r\n)]*\bruntime\b[^\r\n)]*\)(?:[ \t]|$)"#, options: .regularExpression) != nil,
              text.contains("Signature=adhoc") || text.contains("Authority=adhoc"),
              text.split(whereSeparator: \.isNewline).contains(where: {
                  $0 == "TeamIdentifier=not set"
              }) else {
            return false
        }
        return true
    }

    private static func exactMDMHelperEntitlementStderr(
        _ data: Data,
        helperPath: String
    ) -> Bool {
        String(data: data, encoding: .utf8) == "Executable=\(helperPath)\n"
    }

    private static func runMDMGuestProcess(
        reference: VMReference,
        path: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> MDMGuestProcessResult {
        guard path.hasPrefix("/"), !path.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              timeout.isFinite, timeout >= 1, timeout <= 300 else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        let response: [String: Any]
        do {
            response = try PommeCore.sendForegroundControlObject(
                [
                    "command": "agent.perform",
                    "operation": "process.start",
                    "payload": [
                        "path": path,
                        "arguments": arguments,
                        "timeout": timeout,
                        "detached": false,
                    ],
                ],
                bundle: reference.bundle
            )
        } catch {
            // A foreground request may have started the process before the
            // control response was lost. Do not let helper cleanup unlink a
            // path while that process might still hold it open.
            throw PommeMDMEnrollmentError.helperProcessTerminationUnproven
        }
        guard let terminal = response["result"] as? [String: Any],
              let rawJobID = terminal["jobID"] as? String,
              let jobID = UUID(uuidString: rawJobID),
              let exited = terminal["exited"] as? Bool else {
            throw PommeMDMEnrollmentError.helperProcessTerminationUnproven
        }

        let timedOut = terminal["timedOut"] as? Bool == true
        let cancelled = terminal["cancelled"] as? Bool == true
        if timedOut || cancelled || !exited {
            try await terminateMDMGuestJob(
                reference: reference,
                jobID: jobID,
                timeout: min(15, max(1, timeout))
            )
        }

        let output = try decodeMDMGuestOutput(response)
        let exitCode = integerMDMField(terminal["exitCode"])
        let signal = integerMDMField(terminal["signal"])
        let outputComplete = terminal["outputComplete"] as? Bool == true
        let stdoutTruncated = terminal["stdoutTruncated"] as? Bool == true
        let stderrTruncated = terminal["stderrTruncated"] as? Bool == true
        return .init(
            jobID: jobID,
            exited: exited,
            exitCode: exitCode,
            signal: signal,
            timedOut: timedOut,
            cancelled: cancelled,
            outputComplete: outputComplete,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated,
            stdout: output.stdout,
            stderr: output.stderr
        )
    }

    private static func decodeMDMGuestOutput(
        _ response: [String: Any]
    ) throws -> (stdout: Data, stderr: Data) {
        guard let rawFrames = response["streamFrames"] as? [[String: Any]] else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        var stdout = Data()
        var stderr = Data()
        for frame in rawFrames {
            guard let stream = frame["stream"] as? String else {
                throw PommeMDMEnrollmentError.enrollmentFailed
            }
            guard stream == "stdout" || stream == "stderr",
                  let encoded = frame["dataBase64"] as? String,
                  let data = Data(base64Encoded: encoded) else {
                throw PommeMDMEnrollmentError.enrollmentFailed
            }
            if stream == "stdout" {
                guard stdout.count <= mdmTemporaryHelperOutputLimit - data.count else {
                    throw PommeMDMEnrollmentError.enrollmentFailed
                }
                stdout.append(data)
            } else {
                guard stderr.count <= mdmTemporaryHelperOutputLimit - data.count else {
                    throw PommeMDMEnrollmentError.enrollmentFailed
                }
                stderr.append(data)
            }
        }
        return (stdout, stderr)
    }

    private static func integerMDMField(_ value: Any?) -> Int32? {
        guard let value, let decoded = try? JSONValue(any: value),
              case .integer(let integer) = decoded else { return nil }
        return Int32(exactly: integer)
    }

    private static func terminateMDMGuestJob(
        reference: VMReference,
        jobID: UUID,
        timeout: TimeInterval
    ) async throws {
        let id = jobID.uuidString.lowercased()
        _ = try? performAuthenticatedAgentOperation(
            reference: reference,
            operation: "process.signal",
            payload: .object([
                "jobID": .string(id),
                "signal": .integer(Int64(SIGTERM)),
            ])
        )
        if try await pollMDMGuestJob(reference: reference, jobID: jobID, timeout: timeout) {
            return
        }
        _ = try? performAuthenticatedAgentOperation(
            reference: reference,
            operation: "process.signal",
            payload: .object([
                "jobID": .string(id),
                "signal": .integer(Int64(SIGKILL)),
            ])
        )
        guard try await pollMDMGuestJob(reference: reference, jobID: jobID, timeout: timeout) else {
            throw PommeMDMEnrollmentError.helperProcessTerminationUnproven
        }
    }

    private static func pollMDMGuestJob(
        reference: VMReference,
        jobID: UUID,
        timeout: TimeInterval
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let id = jobID.uuidString.lowercased()
        while Date() < deadline {
            do {
                let value = try performAuthenticatedAgentOperation(
                    reference: reference,
                    operation: "process.status",
                    payload: .object(["jobID": .string(id)])
                )
                guard let object = value.objectValue,
                      Set(object.keys).isSuperset(of: ["jobID", "pid", "exited"]),
                      object["jobID"]?.stringValue == id,
                      object["exited"] != nil else {
                    throw PommeMDMEnrollmentError.enrollmentFailed
                }
                if object["exited"] == .bool(true) { return true }
            } catch {
                // Keep polling only for a bounded process lifetime. A lost
                // status receipt remains a cleanup failure after the bound.
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private static func makeLiveMDMStatePort(
        reference: VMReference
    ) -> PommeMDMEnrollmentStateDependencies {
        let proof = PommeMDMRestorationProof()
        return .init(
            capture: {
                do {
                    let runState = try PommeCore.stableVMRunState(reference: reference)
                    return try await normalMDMSecurityBaseline(reference: reference, runState: runState)
                } catch {
                    throw PommeMDMEnrollmentError.baselineCaptureFailed
                }
            },
            restore: { baseline in
                // Enrollment has no security mutation path. Recheck the same
                // authenticated normal-guest evidence rather than rebooting
                // through Recovery to read the same unchanged configuration.
                if try !PommeCore.provesStableVMRunState(baseline.runState, reference: reference) {
                    try await PommeCore.restoreStableVMRunState(baseline.runState, reference: reference)
                }
                let observed = try await normalMDMSecurityBaseline(
                    reference: reference,
                    runState: baseline.runState
                )
                guard observed == baseline else { throw PommeMDMEnrollmentError.restorationFailed }
                await proof.recordSecurityMatch()
            },
            verify: { baseline in
                guard await proof.isSecurityMatched() else { return false }
                return try PommeCore.provesStableVMRunState(baseline.runState, reference: reference)
            }
        )
    }

    /// Configuration evidence only: the normal agent proves SIP plus configured
    /// and active AMFI boot arguments. This does not claim to inspect LocalPolicy
    /// or establish live kernel enforcement. SIP/AMFI commands own those changes.
    private static func normalMDMSecurityBaseline(
        reference: VMReference,
        runState: VMRunStateSnapshot
    ) async throws -> PommeMDMEnrollmentStateBaseline {
        guard runState == .running(.normal),
              try PommeCore.provesStableVMRunState(runState, reference: reference) else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        let expectedDigest = try PommeCore.expectedProvisionedAgentDigest(reference: reference)
        _ = try MDMEnrollmentAgentGate.verify(
            try await authenticatedMDMAgentDescription(reference: reference, timeout: 15),
            expectedExecutableDigest: expectedDigest
        )
        func observe(_ path: String, _ arguments: [String]) async throws -> Data {
            let result = try await runMDMGuestProcess(
                reference: reference,
                path: "/usr/bin/env",
                arguments: ["-i", path] + arguments,
                timeout: 15
            )
            guard result.exitedSuccessfully, result.exited,
                  result.outputComplete, !result.stdoutTruncated, !result.stderrTruncated,
                  result.stderr.isEmpty, result.stdout.count <= 16 * 1024 else {
                throw PommeMDMEnrollmentError.baselineCaptureFailed
            }
            return result.stdout
        }
        let sip = try await observe("/usr/bin/csrutil", ["status"])
        let nvram = try await observe("/usr/sbin/nvram", ["-x", "boot-args"])
        let active = try await observe("/usr/sbin/sysctl", ["-n", "kern.bootargs"])
        _ = try MDMEnrollmentAgentGate.verify(
            try await authenticatedMDMAgentDescription(reference: reference, timeout: 15),
            expectedExecutableDigest: expectedDigest
        )
        guard try PommeCore.provesStableVMRunState(runState, reference: reference) else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        return try PommeMDMNormalSecurityEvidence.baseline(
            csrutil: sip, nvram: nvram, activeBootArguments: active, runState: runState
        )
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
            text: ok ? "OK " + operation : (error ?? "PommeAgent operation failed.")
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
            case "--from-template":
                guard index + 1 < restoreArgs.count else {
                    throw RunnerError.usage
                }
                options.templateName = restoreArgs[index + 1]
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
            return payload["ok"] as? Bool == false ? stringValue(payload["error"]) : "Guest agent is unavailable."
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
            return "boot mode=\(stringValue(payload["bootMode"])): \(stringValue(payload["error"]))"
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
        return "create failed: \(stringValue(payload["error"]))"
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
            lines.append(payload["ok"] as? Bool == true ? "OK" : stringValue(payload["error"]))
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
