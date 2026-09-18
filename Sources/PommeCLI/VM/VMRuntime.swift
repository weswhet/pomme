import Foundation
@preconcurrency import Virtualization

/// The sole VM-side bridge to guest-agent behavior. Guest implementation
/// owners provide this protocol; lifecycle/control code neither selects nor
/// probes an alternate transport.
protocol PommeAgentSessionProtocol: Sendable {
    func status() async -> GuestAgentStatusV1?
    func perform(operation: String, payload: JSONValue?) async throws -> JSONValue
    func perform(
        operation: String,
        payload: JSONValue?,
        requestID: UUID
    ) async throws -> JSONValue
    func close() async
}

/// Dynamic because the guest connects after the VM helper starts.
protocol PommeAgentSessionProvider: Sendable {
    func session() -> (any PommeAgentSessionProtocol)?
    func status() async -> GuestAgentStatusV1
    func teardown()
}

struct PommeAgentCorrelatedResult: Sendable {
    let requestID: UUID
    let result: JSONValue
    let streamFrames: [PommeAgentJobStreamFrame]
}

/// Optional capability used by control-stream routing. Keeping it separate
/// means status/lifecycle require only a dynamic authenticated-session source.
protocol PommeAgentStreamingSessionProvider: PommeAgentSessionProvider {
    func performCorrelated(operation: String, payload: JSONValue?) async throws -> PommeAgentCorrelatedResult
    func sendStream(jobID: UUID, stream: PommeAgentProtocol.Stream, requestID: UUID, data: Data?, dimensions: (columns: Int, rows: Int)?, signal: Int32?) async throws -> [PommeAgentJobStreamFrame]
}

/// How a stop finished, so a clean guest shutdown can be told apart from a
/// power cut both on the wire and in the CLI's output.
enum VMStopOutcome: String, Sendable {
    case alreadyStopped = "already-stopped"
    case guestStopped = "guest-stopped"
    case forced

    var changedState: Bool { self != .alreadyStopped }
}

enum VMPauseResumeTransition {
    enum Action { case pause, resume }

    static func requiresFrameworkCall(_ action: Action, state: VZVirtualMachine.State, canPause: Bool, canResume: Bool) throws -> Bool {
        switch action {
        case .pause:
            if state == .paused { return false }
            guard state == .running, canPause else { throw RunnerError.virtualMachineState("VM cannot be paused from state \(state).") }
        case .resume:
            if state == .running { return false }
            guard state == .paused, canResume else { throw RunnerError.virtualMachineState("VM cannot be resumed from state \(state).") }
        }
        return true
    }
}

/// Serializes host-side terminal mutations across the attachment stream and
/// out-of-band sessions commands. The guest rejects skipped sequences, so an
/// in-flight input cannot race a concurrent terminate or resize.
private actor PommeTerminalMutationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            held = false
        }
    }
}

final class PommeVMRuntime: @unchecked Sendable {
    private let vm: VZVirtualMachine
    private let configuration: VZVirtualMachineConfiguration
    private let queue: DispatchQueue
    private let saveStateURL: URL
    private let snapshotsURL: URL
    private let requiredSnapshotRestoreURL: URL
    private let queueExecutor: PommeVMQueueExecutor
    private let agentProvider: (any PommeAgentSessionProvider)?
    private let terminalAdmission: (@Sendable (UUID) async throws -> Void)?
    private let terminalAdmissionCleanup: (@Sendable () async -> Bool)?
    private let uiController: PommeRuntimeUIController
    private let bootMode: BootMode
    private let terminalGeneration: UUID
    private let terminalSessions: PommeDurableTerminalSessionManager
    private let terminalMutationGate = PommeTerminalMutationGate()
    private let terminalPumpLock = NSLock()
    private let terminalCleanupLock = NSLock()
    private var terminalPumpTasks: [UUID: Task<Void, Never>] = [:]
    private var terminalCleanupVerified = true
    /// Protected by `queue`; a running VZ VM alone cannot prove that the
    /// requested Recovery boot path was used.
    private var recoveryStartCompleted = false

    init(vm: VZVirtualMachine, configuration: VZVirtualMachineConfiguration, queue: DispatchQueue,
         saveStateURL: URL, snapshotsURL: URL, requiredSnapshotRestoreURL: URL,
         agentProvider: (any PommeAgentSessionProvider)?, bootMode: BootMode,
         terminalAdmission: (@Sendable (UUID) async throws -> Void)? = nil,
         terminalAdmissionCleanup: (@Sendable () async -> Bool)? = nil) {
        self.vm = vm
        self.configuration = configuration
        self.queue = queue
        self.saveStateURL = saveStateURL
        self.snapshotsURL = snapshotsURL
        self.requiredSnapshotRestoreURL = requiredSnapshotRestoreURL
        self.queueExecutor = PommeVMQueueExecutor(queue: queue)
        self.agentProvider = agentProvider
        self.terminalAdmission = terminalAdmission
        self.terminalAdmissionCleanup = terminalAdmissionCleanup
        // Construct the queue-confined private backend before handing it to
        // the actor. This keeps raw Virtualization references out of the
        // actor boundary while preserving the VM's documented queue owner.
        self.uiController = PommeRuntimeUIController(
            backend: VirtualizationPrivateHeadlessBackend(
                virtualMachine: vm,
                configuration: configuration,
                queue: queue
            )
        )
        self.bootMode = bootMode
        let terminalGeneration = UUID()
        self.terminalGeneration = terminalGeneration
        self.terminalSessions = PommeDurableTerminalSessionManager(
            role: bootMode == .normal ? .normal : .recovery,
            vmPath: saveStateURL.deletingLastPathComponent().path,
            generation: terminalGeneration
        )
    }

    func start() async throws {
        do {
            switch bootMode {
            case .normal: try await startOrRestore()
            case .recovery: try await startRecovery()
            }
        } catch {
            await teardown()
            throw error
        }
    }

    private func startOrRestore() async throws {
        let requiredRestore = FileManager.default.fileExists(atPath: requiredSnapshotRestoreURL.path)
        guard !requiredRestore || FileManager.default.fileExists(atPath: saveStateURL.path) else {
            throw RunnerError.virtualMachineState(
                "Named snapshot restore is incomplete; its saved VM state is missing and the VM was not cold-started."
            )
        }
        if FileManager.default.fileExists(atPath: saveStateURL.path) {
            do {
                try configuration.validateSaveRestoreSupport()
                try await PommeCore.restoreMachineState(vm, from: saveStateURL, on: queue)
                if requiredRestore {
                    try VMSnapshotStore.consumeRequiredRestore(
                        bundle: BundleLayout(rootURL: saveStateURL.deletingLastPathComponent())
                    )
                    return
                }
                try await PommeCore.resume(vm, on: queue)
                try? FileManager.default.removeItem(at: saveStateURL)
                return
            } catch {
                if requiredRestore || FileManager.default.fileExists(atPath: requiredSnapshotRestoreURL.path) {
                    throw RunnerError.virtualMachineState("Named snapshot restore failed; VM was not cold-started: \(error.localizedDescription)")
                }
                quarantineSaveState()
            }
        }
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = false
        try await PommeCore.start(vm, options: options, on: queue)
    }

    private func startRecovery() async throws {
        clearRecoveryBootProof()
        guard !FileManager.default.fileExists(atPath: saveStateURL.path) else {
            throw RunnerError.virtualMachineState("Cannot boot Recovery while a saved VM state exists. Resume and stop the VM first.")
        }
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = true
        do {
            try await PommeCore.start(vm, options: options, on: queue)
            queueExecutor.sync { recoveryStartCompleted = true }
        } catch {
            clearRecoveryBootProof()
            throw error
        }
    }

    /// Each lifecycle call reports whether it changed the VM's state, so the
    /// reply can tell a stop, pause, or resume apart from a no-op. A stop also
    /// reports whether the guest shut itself down or had to be powered off.
    @discardableResult
    func stop() async throws -> VMStopOutcome {
        let state = await PommeCore.state(of: vm, on: queue)
        guard state != .stopped else { await teardown(); return .alreadyStopped }
        // A paused guest is frozen, so it can never act on the request and
        // waiting out the window would only delay the power off. The host
        // resumes a VM it means to shut down cleanly before asking for this.
        if state != .paused, await PommeCore.canRequestStop(vm, on: queue) {
            do {
                try await PommeCore.requestStop(vm, on: queue)
                if await waitUntilStopped(timeout: guestShutdownWindow) {
                    await teardown()
                    return .guestStopped
                }
            } catch { }
        }
        try await forceStop()
        await teardown()
        return .forced
    }

    /// recoveryOS provably ignores the framework's stop request, so it keeps
    /// the short window rather than making every Recovery stop wait it out.
    private var guestShutdownWindow: TimeInterval {
        bootMode == .normal ? Constants.guestShutdownTimeoutSeconds : Constants.gracefulStopTimeoutSeconds
    }

    @discardableResult
    func forceStopNow() async throws -> VMStopOutcome { try await forceStop(); await teardown(); return .forced }

    @discardableResult
    func resume() async throws -> Bool {
        let state = await PommeCore.state(of: vm, on: queue)
        guard try VMPauseResumeTransition.requiresFrameworkCall(.resume, state: state, canPause: false, canResume: await PommeCore.canResume(vm, on: queue)) else { return false }
        try await PommeCore.resume(vm, on: queue)
        return true
    }

    @discardableResult
    func pause() async throws -> Bool {
        let state = await PommeCore.state(of: vm, on: queue)
        guard try VMPauseResumeTransition.requiresFrameworkCall(.pause, state: state, canPause: await PommeCore.canPause(vm, on: queue), canResume: false) else { return false }
        try await PommeCore.pause(vm, on: queue)
        return true
    }

    func saveSnapshotMachineState(in stageName: String) async throws {
        guard bootMode == .normal else { throw RunnerError.virtualMachineState("Snapshots are unavailable in Recovery.") }
        let bundle = BundleLayout(rootURL: snapshotsURL.deletingLastPathComponent())
        let destination = try VMSnapshotStore.writableMachineStateURL(bundle: bundle, stageName: stageName)
        guard await PommeCore.state(of: vm, on: queue) == .paused else { throw RunnerError.virtualMachineState("VM must be paused before creating a snapshot.") }
        try configuration.validateSaveRestoreSupport()
        try await PommeCore.saveMachineState(vm, to: destination, on: queue)
    }

    /// Every guest operation must pass through the one injected Pomme session.
    func performGuestOperation(_ operation: String, payload: JSONValue? = nil) async throws -> JSONValue {
        guard let agentSession = agentProvider?.session() else { throw RunnerError.guestAgentUnavailable }
        return try await agentSession.perform(operation: operation, payload: payload)
    }

    func performGuestOperationCorrelated(_ operation: String, payload: JSONValue? = nil) async throws -> PommeAgentCorrelatedResult {
        guard let provider = agentProvider as? any PommeAgentStreamingSessionProvider else { throw RunnerError.guestAgentUnavailable }
        return try await provider.performCorrelated(operation: operation, payload: payload)
    }

    func sendGuestStream(jobID: UUID, stream: PommeAgentProtocol.Stream, requestID: UUID, data: Data? = nil,
                         dimensions: (columns: Int, rows: Int)? = nil, signal: Int32? = nil) async throws -> [PommeAgentJobStreamFrame] {
        guard let provider = agentProvider as? any PommeAgentStreamingSessionProvider else { throw RunnerError.guestAgentUnavailable }
        return try await provider.sendStream(jobID: jobID, stream: stream, requestID: requestID, data: data, dimensions: dimensions, signal: signal)
    }

    // MARK: Durable terminal sessions

    func terminalSessionCreate(payload: [String: JSONValue]) async throws -> [String: Any] {
        let sessionID: UUID
        if let supplied = payload["sessionID"]?.stringValue, let parsed = UUID(uuidString: supplied) {
            sessionID = parsed
        } else {
            sessionID = UUID()
        }
        if bootMode == .recovery, let terminalAdmission {
            try await terminalAdmission(sessionID)
        }
        try await requireTerminalCapability()
        var guestPayload = payload
        guestPayload["sessionID"] = .string(sessionID.uuidString.lowercased())
        guestPayload["sequence"] = .integer(0)
        guestPayload["mutationDigest"] = .string(
            PommeTerminalMutationDigest.make(operation: "terminal.create", payload: payload)
        )
        let result = try await performGuestOperation("terminal.create", payload: .object(guestPayload))
        guard let values = result.objectValue,
              let rawPID = values["pid"],
              case .integer(let pid) = rawPID,
              pid > 0
        else { throw RunnerError.invalidControlResponse("Invalid terminal creation receipt.") }
        let path = values["path"]?.stringValue ?? payload["path"]?.stringValue ?? "/bin/sh"
        let arguments = values["arguments"]?.arrayValue?.compactMap(\.stringValue)
            ?? payload["arguments"]?.arrayValue?.compactMap(\.stringValue)
            ?? []
        let record: PommeDurableTerminalRecord
        do {
            record = try await terminalSessions.register(.init(
                sessionID: sessionID,
                role: bootMode == .normal ? .normal : .recovery,
                bootGeneration: terminalGeneration,
                pid: pid,
                executable: path,
                arguments: arguments
            ))
        } catch {
            // Admission is host-durable: if the host cannot create its
            // transcript record, do not leave an unowned guest process behind.
            let cleanup: [String: JSONValue] = [
                "sessionID": .string(sessionID.uuidString.lowercased()),
                "sequence": .integer(1),
                "force": .bool(true),
                "mutationDigest": .string(PommeTerminalMutationDigest.make(
                    operation: "terminal.terminate",
                    payload: ["sessionID": .string(sessionID.uuidString.lowercased()), "force": .bool(true)]
                ))
            ]
            _ = try? await performGuestOperation("terminal.terminate", payload: .object(cleanup))
            _ = try? await performGuestOperation("terminal.release", payload: .object(["sessionID": .string(sessionID.uuidString.lowercased())]))
            throw error
        }
        startTerminalPump(sessionID)
        return [
            "sessionID": sessionID.uuidString.lowercased(),
            "session": record.publicPayload,
            "hostExitCode": 0
        ]
    }

    func terminalSessionList(pageToken: String? = nil, pageSize: Int = 128) async throws -> [String: Any] {
        let (records, nextPageToken) = try await terminalSessions.page(pageToken: pageToken, pageSize: pageSize)
        return [
            "sessions": records.map(\.publicPayload),
            "nextPageToken": nextPageToken ?? NSNull(),
            "hostExitCode": 0
        ]
    }

    func hasLiveTerminalSessions() async -> Bool {
        let records = await terminalSessions.list()
        return records.contains { record in
            ![.exited, .lost].contains(record.state)
        }
    }

    func terminalSessionInspect(id: UUID) async throws -> [String: Any] {
        let record = try await terminalSessions.inspect(id)
        return record.publicPayload
    }

    func terminalSessionLogs(id: UUID, offset: UInt64) async throws -> [String: Any] {
        let (record, data) = try await terminalSessions.logs(id, from: offset)
        let next = offset + UInt64(data.count)
        return [
            "session": record.publicPayload,
            "fromOffset": offset,
            "nextOffset": next,
            "dataBase64": data.base64EncodedString(),
            "complete": [.exited, .lost].contains(record.state) && next >= record.transcriptOffset,
            "hostExitCode": 0
        ]
    }

    func terminalSessionTerminate(id: UUID, force: Bool) async throws -> [String: Any] {
        _ = try await terminalSessionMutate(
            id: id,
            operation: "terminal.terminate",
            payload: ["force": .bool(force)]
        )
        return ["sessionID": id.uuidString.lowercased(), "terminated": true, "force": force, "hostExitCode": 0]
    }

    func terminalSessionDelete(id: UUID) async throws -> [String: Any] {
        try await terminalSessions.delete(id)
        _ = try? await performGuestOperation("terminal.release", payload: .object(["sessionID": .string(id.uuidString.lowercased())]))
        return ["sessionID": id.uuidString.lowercased(), "deleted": true, "hostExitCode": 0]
    }

    func terminalSessionAttach(
        id: UUID,
        offset: UInt64?,
        takeover: Bool,
        stream: PommeControlStreamSession
    ) async throws -> [String: Any] {
        let attachment = try await terminalSessions.attach(id, from: offset, takeover: takeover)
        defer { Task { try? await terminalSessions.detach(attachment) } }
        var cursor = attachment.cursor
        while true {
            if try await terminalSessions.isReplaced(attachment) {
                throw PommeDurableTerminalError.attachmentReplaced
            }
            let bytes = try await terminalSessions.read(id, from: cursor)
            if !bytes.isEmpty {
                try stream.send(stream: .stdout, data: bytes)
                cursor += UInt64(bytes.count)
                try await terminalSessions.markDelivered(attachment, offset: cursor)
            }

            if let frame = try stream.receiveIfAvailable(timeout: 0.01) {
                switch frame.stream {
                case .stdin:
                    if frame.eof == true {
                        _ = try await terminalSessionMutate(
                            id: id, operation: "terminal.input",
                            payload: ["dataBase64": .string(Data([0x04]).base64EncodedString())]
                        )
                    } else if let data = try frame.decodedData() {
                        _ = try await terminalSessionMutate(
                            id: id, operation: "terminal.input",
                            payload: ["dataBase64": .string(data.base64EncodedString())]
                        )
                    }
                case .resize:
                    guard let dimensions = Self.terminalDimensions(from: frame.payload) else {
                        throw RunnerError.invalidControlResponse("Invalid terminal resize frame.")
                    }
                    _ = try await terminalSessionMutate(
                        id: id, operation: "terminal.resize",
                        payload: ["columns": .integer(Int64(dimensions.columns)), "rows": .integer(Int64(dimensions.rows))]
                    )
                case .signal:
                    guard let signal = Self.terminalSignal(from: frame.payload) else {
                        throw RunnerError.invalidControlResponse("Invalid terminal signal frame.")
                    }
                    _ = try await terminalSessionMutate(
                        id: id, operation: "terminal.signal",
                        payload: ["signal": .integer(Int64(signal))]
                    )
                case .cancellation:
                    return ["sessionID": id.uuidString.lowercased(), "detached": true, "hostExitCode": 0]
                case .stdout, .stderr, .progress:
                    throw RunnerError.invalidControlResponse("Unexpected terminal attachment output frame.")
                }
            }

            let status = try await performGuestOperation(
                "terminal.status",
                payload: .object(["sessionID": .string(id.uuidString.lowercased())])
            )
            try await updateTerminalStatus(id: id, result: status)
            if let values = status.objectValue,
               values["exited"] == .bool(true),
                values["outputComplete"] == .bool(true),
               let outputLength = values["outputLength"].flatMap(Self.uint64Value),
               cursor >= outputLength {
                return ["sessionID": id.uuidString.lowercased(), "attached": false, "hostExitCode": 0]
            }
        }
    }

    func terminalSessionMutate(
        id: UUID,
        operation: String,
        payload: [String: JSONValue]
    ) async throws -> JSONValue {
        await terminalMutationGate.acquire()
        do {
            var values = payload
            values["sessionID"] = .string(id.uuidString.lowercased())
            let sequence = try await terminalSessions.nextMutationSequence(for: id)
            values["sequence"] = .integer(Int64(sequence))
            values["mutationDigest"] = .string(PommeTerminalMutationDigest.make(operation: operation, payload: payload))
            let result = try await performGuestOperation(operation, payload: .object(values))
            try await terminalSessions.commitMutationSequence(id, sequence: sequence)
            await terminalMutationGate.release()
            return result
        } catch {
            await terminalMutationGate.release()
            throw error
        }
    }

    private func requireTerminalCapability() async throws {
        let description = try await performGuestOperation("agent.describe")
        guard let object = description.objectValue,
              object["terminalSessionVersion"] == .integer(Int64(PommeTerminalSessionProtocol.version)),
              case .array(let rawCapabilities)? = object["capabilities"],
              Set(rawCapabilities.compactMap(\.stringValue)).isSuperset(of: Set(PommeAgent.terminalCapabilities))
        else {
            throw RunnerError.controlCapabilityUnavailable("terminalSessionVersion=1 (repair the guest agent)")
        }
    }

    private func startTerminalPump(_ id: UUID) {
        terminalPumpLock.withLock {
            terminalPumpTasks[id]?.cancel()
            terminalPumpTasks[id] = Task { [weak self] in
                await self?.pumpTerminal(id)
            }
        }
    }

    private func pumpTerminal(_ id: UUID) async {
        while !Task.isCancelled {
            do {
                let record = try await terminalSessions.inspect(id)
                if record.state == .lost { return }
                if record.state == .exited,
                   record.acknowledgedOffset >= record.transcriptOffset {
                    return
                }
                let result = try await performGuestOperation(
                    "terminal.read",
                    payload: .object([
                        "sessionID": .string(id.uuidString.lowercased()),
                        "offset": .integer(Int64(record.transcriptOffset)),
                        "count": .integer(Int64(PommeControlProtocol.maximumStreamChunkBytes))
                    ])
                )
                guard let values = result.objectValue else { throw RunnerError.invalidControlResponse("Invalid terminal read response.") }
                let encoded = values["dataBase64"]?.stringValue ?? ""
                guard let data = Data(base64Encoded: encoded) else { throw RunnerError.invalidControlResponse("Invalid terminal read bytes.") }
                if !data.isEmpty {
                    _ = try await terminalSessions.append(data, sessionID: id)
                }
                let status = try await performGuestOperation(
                    "terminal.status",
                    payload: .object(["sessionID": .string(id.uuidString.lowercased())])
                )
                try await updateTerminalStatus(id: id, result: status)
                try await reconcileTerminalAcknowledgement(id: id, result: status)
                try await Task.sleep(for: .milliseconds(10))
            } catch is CancellationError {
                return
            } catch {
                if let status = try? await performGuestOperation(
                    "terminal.status",
                    payload: .object(["sessionID": .string(id.uuidString.lowercased())])
                ), status.objectValue?["storageBlocked"] == .bool(true) {
                    try? await updateTerminalStatus(id: id, result: status)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func updateTerminalStatus(id: UUID, result: JSONValue) async throws {
        guard let values = result.objectValue else { throw RunnerError.invalidControlResponse("Invalid terminal status response.") }
        try await terminalSessions.updateGuestStatus(
            id,
            exited: values["exited"] == .bool(true),
            exitCode: values["exitCode"].flatMap(Self.intValue),
            signal: values["signal"].flatMap(Self.intValue),
            outputComplete: values["outputComplete"] == .bool(true),
            outputLength: values["outputLength"].flatMap(Self.uint64Value),
            storageBlocked: values["storageBlocked"] == .bool(true)
        )
    }

    private func reconcileTerminalAcknowledgement(id: UUID, result: JSONValue) async throws {
        guard let values = result.objectValue,
              let guestAcknowledged = values["acknowledgedOffset"].flatMap(Self.uint64Value)
        else { return }
        let local = try await terminalSessions.inspect(id)
        let localOffset = local.transcriptOffset
        let durableAcknowledged = min(guestAcknowledged, localOffset)

        // First reconcile an acknowledgement that the guest accepted before
        // the host observed the response. This makes retries idempotent even
        // when persisting the host metadata failed after the guest ack.
        if durableAcknowledged > local.acknowledgedOffset {
            try await terminalSessions.acknowledgeGuest(id, offset: durableAcknowledged)
        }
        guard guestAcknowledged < localOffset else { return }

        // The host append is durable before this request is sent. If the
        // response is lost, the next status pass sees guestAcknowledged at
        // least localOffset and records the same acknowledgement without
        // appending or acknowledging the bytes twice.
        _ = try await performGuestOperation(
            "terminal.ack",
            payload: .object([
                "sessionID": .string(id.uuidString.lowercased()),
                "offset": .integer(Int64(localOffset))
            ])
        )
        try await terminalSessions.acknowledgeGuest(id, offset: localOffset)
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        guard case .integer(let value) = value else { return nil }
        return Int(exactly: value)
    }

    private static func uint64Value(_ value: JSONValue?) -> UInt64? {
        guard case .integer(let value) = value, value >= 0 else { return nil }
        return UInt64(exactly: value)
    }

    private static func terminalDimensions(from payload: JSONValue?) -> (columns: Int, rows: Int)? {
        guard let object = payload?.objectValue,
              let columns = intValue(object["columns"]), let rows = intValue(object["rows"]),
              columns > 0, rows > 0 else { return nil }
        return (columns, rows)
    }

    private static func terminalSignal(from payload: JSONValue?) -> Int32? {
        guard let value = payload?.objectValue?["signal"], case .integer(let signal) = value else { return nil }
        return Int32(exactly: signal)
    }

    /// Captures one authenticated coordinator session for a security-bound
    /// operation. The returned pin owns the session choice; callers must use
    /// it for describe, process, and stream exchanges rather than reacquiring
    /// the coordinator's current session for each request.
    func captureAuthenticatedAgentSession(as role: PommeAgentVSOCKRole) throws -> PommeAuthenticatedAgentSession {
        guard let coordinator = agentProvider as? PommeAgentVSOCKCoordinator else {
            throw RunnerError.guestAgentUnavailable
        }
        return try coordinator.captureAuthenticatedSession(as: role)
    }

    /// Host-display UI is delivered by the private Virtualization backend in
    /// both normal and Recovery modes. It intentionally does not consult the
    /// guest-agent provider, so Recovery remains usable before authentication.
    func performUI(_ request: PommeUIControlRequest) async throws -> [String: JSONValue] {
        try await uiController.perform(request)
    }

    func statusPayload(bundle: BundleLayout, inspect: Bool) async -> [String: Any] {
        let state = await PommeCore.state(of: vm, on: queue)
        let role: GuestAgentStatusV1.Role = bootMode == .normal ? .normal : .recovery
        let agent = await agentProvider?.status() ?? .offline(role: role)
        var payload: [String: Any] = [
            "ok": true,
            "helperRunning": true,
            "vmState": stateDescription(state),
            "bootMode": bootMode.rawValue,
            "bundlePath": bundle.rootURL.path,
            "pommeSocket": bundle.pommeSocketURL.path,
            "guestAgent": agentPayload(agent)
        ]
        if inspect, let metadata = try? metadataPayload(bundle: bundle) { payload["metadata"] = metadata }
        return payload
    }

    func teardown() async {
        // A guest agent can outlive this helper. End every terminal process
        // group before dropping the authenticated connection so a helper exit
        // cannot leave a live PTY behind. A transient VSOCK loss does not call
        // teardown, so sessions remain reconnectable.
        await terminateGuestTerminalsForHelperExit()
        terminalPumpLock.withLock {
            for task in terminalPumpTasks.values { task.cancel() }
            terminalPumpTasks.removeAll()
        }
        await terminalSessions.markAllLost(reason: "helper-exited")
        clearRecoveryBootProof()
        if let terminalAdmissionCleanup {
            let verified = await terminalAdmissionCleanup()
            if !verified { terminalCleanupLock.withLock { terminalCleanupVerified = false } }
        }
        agentProvider?.teardown()
    }

    func terminalCleanupIsVerified() -> Bool {
        terminalCleanupLock.withLock { terminalCleanupVerified }
    }

    private func terminateGuestTerminalsForHelperExit() async {
        let live = (await terminalSessions.list()).filter {
            ![.exited, .lost].contains($0.state)
        }
        for record in live {
            guard let id = UUID(uuidString: record.sessionID) else { continue }
            _ = try? await terminalSessionMutate(
                id: id,
                operation: "terminal.terminate",
                payload: ["force": .bool(true)]
            )
        }
    }

    /// Returns proof only when this immutable Recovery runtime completed its
    /// own `startUpFromMacOSRecovery` call and the same VM is currently
    /// running. A state of `.running` without the successful start marker is
    /// intentionally insufficient.
    func provesRunningRecoveryBoot() -> Bool {
        guard bootMode == .recovery else { return false }
        return queueExecutor.sync {
            Self.recoveryBootIsProven(
                bootMode: bootMode,
                startCompleted: recoveryStartCompleted,
                state: vm.state
            )
        }
    }

    static func recoveryBootIsProven(
        bootMode: BootMode,
        startCompleted: Bool,
        state: VZVirtualMachine.State
    ) -> Bool {
        bootMode == .recovery && startCompleted && state == .running
    }

    private func forceStop() async throws {
        let state = await PommeCore.state(of: vm, on: queue)
        guard state != .stopped else { return }
        try await PommeCore.forceStop(vm, on: queue)
    }

    private func waitUntilStopped(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await PommeCore.state(of: vm, on: queue) == .stopped { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return await PommeCore.state(of: vm, on: queue) == .stopped
    }

    private func quarantineSaveState() {
        let quarantine = saveStateURL.deletingLastPathComponent().appendingPathComponent("SaveFile.invalid-\(UUID().uuidString).vzvmsave")
        try? FileManager.default.moveItem(at: saveStateURL, to: quarantine)
    }

    private func clearRecoveryBootProof() {
        queueExecutor.sync { recoveryStartCompleted = false }
    }

    private func stateDescription(_ state: VZVirtualMachine.State) -> String {
        switch state {
        case .stopped: "stopped"
        case .running: "running"
        case .paused: "paused"
        case .error: "error"
        case .starting: "starting"
        case .pausing: "pausing"
        case .resuming: "resuming"
        case .stopping: "stopping"
        default: "unknown"
        }
    }

    private func agentPayload(_ status: GuestAgentStatusV1) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(status), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
