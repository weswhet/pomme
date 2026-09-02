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

final class PommeVMRuntime: @unchecked Sendable {
    private let vm: VZVirtualMachine
    private let configuration: VZVirtualMachineConfiguration
    private let queue: DispatchQueue
    private let saveStateURL: URL
    private let snapshotsURL: URL
    private let requiredSnapshotRestoreURL: URL
    private let agentProvider: (any PommeAgentSessionProvider)?
    private let bootMode: BootMode

    init(vm: VZVirtualMachine, configuration: VZVirtualMachineConfiguration, queue: DispatchQueue,
         saveStateURL: URL, snapshotsURL: URL, requiredSnapshotRestoreURL: URL,
         agentProvider: (any PommeAgentSessionProvider)?, bootMode: BootMode) {
        self.vm = vm
        self.configuration = configuration
        self.queue = queue
        self.saveStateURL = saveStateURL
        self.snapshotsURL = snapshotsURL
        self.requiredSnapshotRestoreURL = requiredSnapshotRestoreURL
        self.agentProvider = agentProvider
        self.bootMode = bootMode
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
        if FileManager.default.fileExists(atPath: saveStateURL.path) {
            let requiredRestore = FileManager.default.fileExists(atPath: requiredSnapshotRestoreURL.path)
            do {
                try configuration.validateSaveRestoreSupport()
                try await PommeCore.restoreMachineState(vm, from: saveStateURL, on: queue)
                if requiredRestore { return }
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
        guard !FileManager.default.fileExists(atPath: saveStateURL.path) else {
            throw RunnerError.virtualMachineState("Cannot boot Recovery while a saved VM state exists. Resume and stop the VM first.")
        }
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = true
        try await PommeCore.start(vm, options: options, on: queue)
    }

    func stop() async throws {
        let state = await PommeCore.state(of: vm, on: queue)
        guard state != .stopped else { await teardown(); return }
        if await PommeCore.canRequestStop(vm, on: queue) {
            do {
                try await PommeCore.requestStop(vm, on: queue)
                if await waitUntilStopped(timeout: Constants.gracefulStopTimeoutSeconds) { await teardown(); return }
            } catch { }
        }
        try await forceStop()
        await teardown()
    }

    func forceStopNow() async throws { try await forceStop(); await teardown() }

    func resume() async throws {
        let state = await PommeCore.state(of: vm, on: queue)
        guard try VMPauseResumeTransition.requiresFrameworkCall(.resume, state: state, canPause: false, canResume: await PommeCore.canResume(vm, on: queue)) else { return }
        try await PommeCore.resume(vm, on: queue)
    }

    func pause() async throws {
        let state = await PommeCore.state(of: vm, on: queue)
        guard try VMPauseResumeTransition.requiresFrameworkCall(.pause, state: state, canPause: await PommeCore.canPause(vm, on: queue), canResume: false) else { return }
        try await PommeCore.pause(vm, on: queue)
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

    func teardown() async { agentProvider?.teardown() }

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
        @unknown default: "unknown"
        }
    }

    private func agentPayload(_ status: GuestAgentStatusV1) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(status), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
