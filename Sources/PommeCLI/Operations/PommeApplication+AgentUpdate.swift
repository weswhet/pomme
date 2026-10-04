import Darwin
import Foundation

enum PommeAgentUpdateError: Error, LocalizedError, Equatable {
    case notRunningNormal(vmName: String)
    case unprovisioned(vmName: String)
    case retainedWorkflow(vmName: String, workflow: String)
    case activeWork(vmName: String, jobs: [String], sessions: [String])
    case agentUnavailable(vmName: String)
    case unsupportedAgent(vmName: String)
    case transferMismatch
    case applyFailed(detail: String)
    case activationTimedOut(vmName: String, expected: String, observed: String?)

    var errorDescription: String? {
        switch self {
        case .notRunningNormal(let name):
            "Start \(name) in normal macOS before updating its Pomme agent: `pomme start \(name)`."
        case .unprovisioned(let name):
            "\(name) was not created by Pomme, so it has no Pomme agent to update."
        case .retainedWorkflow(let name, let workflow):
            "\(name) has a retained \(workflow) operation pinned to its current agent. Finish it before updating the agent."
        case .activeWork(let name, let jobs, let sessions):
            "\(name) has running background jobs or terminal sessions that the restarted agent could no longer manage. "
                + "Let them finish or stop them, then rerun `pomme agent update \(name)`."
                + jobs.map { "\n  job \($0): pomme jobs kill \(name) \($0)" }.joined()
                + sessions.map { "\n  session \($0): pomme sessions terminate \(name) \($0)" }.joined()
        case .agentUnavailable(let name):
            "The Pomme agent in \(name) did not answer. Check it with `pomme agent status \(name)`."
        case .unsupportedAgent(let name):
            "The Pomme agent in \(name) cannot receive files or run processes, so it cannot be updated in place. Use `pomme agent repair \(name)`."
        case .transferMismatch:
            "The staged agent in the guest does not match this host's Pomme executable."
        case .applyFailed(let detail):
            "The guest could not install the new Pomme agent; the previous agent is still installed. \(detail)"
        case .activationTimedOut(let name, let expected, let observed):
            "The updated Pomme agent in \(name) did not connect with digest \(expected) (observed \(observed ?? "none")). "
                + "It is installed and takes effect on the next restart: `pomme restart \(name)`, then rerun `pomme agent update \(name)`."
        }
    }
}

/// `pomme agent update`: replaces the persistent agent in a running,
/// Pomme-created VM with this host's signed Pomme executable, without
/// Recovery. The old agent receives the bytes and runs them as root in
/// update mode; the agent job is then restarted and must reconnect with the
/// new digest before the host records it.
extension PommeApplication {
    static let agentUpdateActivationTimeout: TimeInterval = 90

    static func agentUpdate(name: String) async throws -> PommeOperationResult {
        let name = try validateVMName(name)
        return try await VMBundleMutationLease.withLease(name: name) { lease in
            try await agentUpdate(name: name, lease: lease)
        }
    }

    private static func agentUpdate(name: String, lease: VMBundleMutationLease) async throws -> PommeOperationResult {
        let progress = PommeProgressContext.sink
        let reference = try namedReference(name)
        let plan: PommeProvisioningPlan
        do { plan = try PommeCore.loadOwnedProvisioningPlan(reference: reference) }
        catch { throw PommeAgentUpdateError.unprovisioned(vmName: name) }
        guard try PommeCore.stableVMRunState(reference: reference) == .running(.normal) else {
            throw PommeAgentUpdateError.notRunningNormal(vmName: name)
        }
        if let journal = try PommeSecurityWorkflowJournalStore(bundleURL: reference.bundle.rootURL)
            .loadIfPresent(lease: lease),
           journal.phase != .restorationComplete, journal.phase != .preflightRejected {
            throw PommeAgentUpdateError.retainedWorkflow(vmName: name, workflow: "security")
        }
        if let journal = try PommeMDMEnrollmentJournalStore(bundleURL: reference.bundle.rootURL)
            .loadIfPresent(lease: lease), journal.phase != .restorationComplete {
            throw PommeAgentUpdateError.retainedWorkflow(vmName: name, workflow: "MDM enrollment")
        }

        progress?.step(vm: name, "Checking Pomme agent")
        let current = try describeAgent(reference: reference, name: name)
        let host = try PommeCore.runningExecutableIdentity()
        try PommeAgentArtifactStore.Dependencies().verifyCodeSignature(host.url)
        let recorded = try PommeCore.currentNormalAgentDigest(plan: plan)

        if current.digest == host.sha256 {
            if recorded != host.sha256 {
                try PommeCore.recordNormalAgentUpdate(plan: plan, previousDigest: recorded, digest: host.sha256)
            }
            return agentUpdateResult(name: name, reference: reference, previous: current.digest,
                                     digest: host.sha256, updated: false)
        }
        guard ["file.open", "file.write", "file.commit", "process.start"]
            .allSatisfy(current.capabilities.contains) else {
            throw PommeAgentUpdateError.unsupportedAgent(vmName: name)
        }
        // The restarted agent starts with empty job and terminal tables, so it
        // could no longer wait for, attach to, or stop work the old one owns.
        let active = try activeAgentWork(reference: reference, capabilities: current.capabilities)
        guard active.jobs.isEmpty, active.sessions.isEmpty else {
            throw PommeAgentUpdateError.activeWork(vmName: name, jobs: active.jobs, sessions: active.sessions)
        }

        progress?.step(vm: name, "Copying Pomme agent")
        let staged = PommeAgentInstall.updatePrefix + UUID().uuidString.lowercased()
        let transfer = PommeGuestFileTransfer { operation, payload in
            try performAuthenticatedAgentOperation(reference: reference, operation: operation, payload: payload)
        }
        let receipt = try transfer.copy(.init(source: .host(host.url), destination: .guest(staged)))
        guard receipt.sha256 == host.sha256 else {
            _ = try? await runMDMGuestProcess(reference: reference, path: "/bin/rm", arguments: ["-f", staged], timeout: 30)
            throw PommeAgentUpdateError.transferMismatch
        }

        progress?.step(vm: name, "Installing Pomme agent")
        let chmod = try await runMDMGuestProcess(reference: reference, path: "/bin/chmod",
                                                 arguments: ["0500", staged], timeout: 30)
        guard chmod.exited, chmod.exitCode == 0 else {
            _ = try? await runMDMGuestProcess(reference: reference, path: "/bin/rm", arguments: ["-f", staged], timeout: 30)
            throw PommeAgentUpdateError.applyFailed(detail: "The staged agent could not be made executable.")
        }
        let apply = try await runMDMGuestProcess(reference: reference, path: staged,
            arguments: [PommeAgentUpdateApply.flag, staged, host.sha256], timeout: 120)
        let output = String(decoding: apply.stdout, as: UTF8.self)
        guard apply.exited, apply.exitCode == 0,
              ["\(PommeAgentUpdateApply.Outcome.applied.rawValue) \(host.sha256)\n",
               "\(PommeAgentUpdateApply.Outcome.alreadyApplied.rawValue) \(host.sha256)\n"].contains(output) else {
            _ = try? await runMDMGuestProcess(reference: reference, path: "/bin/rm", arguments: ["-f", staged], timeout: 30)
            throw PommeAgentUpdateError.applyFailed(
                detail: "Update mode exited with status \(apply.exitCode.map(String.init) ?? "unknown").")
        }

        progress?.step(vm: name, "Restarting Pomme agent")
        // The restart ends the agent that carries this request, so its reply
        // may never arrive. Success is proven only by the reconnect below.
        _ = try? PommeCore.sendControlObject([
            "command": "agent.perform",
            "operation": "process.start",
            "payload": [
                "path": "/bin/launchctl",
                "arguments": ["kickstart", "-k", "system/\(PommeAgentInstall.label)"],
                "detached": true,
            ],
        ], bundle: reference.bundle, timeout: 15)

        progress?.step(vm: name, "Waiting for updated Pomme agent")
        let deadline = Date().addingTimeInterval(agentUpdateActivationTimeout)
        var observed: String?
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            guard let description = try? describeAgent(reference: reference, name: name) else { continue }
            observed = description.digest
            if description.digest == host.sha256 { break }
        }
        guard observed == host.sha256 else {
            throw PommeAgentUpdateError.activationTimedOut(vmName: name, expected: host.sha256, observed: observed)
        }
        try PommeCore.recordNormalAgentUpdate(plan: plan, previousDigest: current.digest, digest: host.sha256)
        return agentUpdateResult(name: name, reference: reference, previous: current.digest,
                                 digest: host.sha256, updated: true)
    }

    private static func activeAgentWork(
        reference: VMReference, capabilities: [String]
    ) throws -> (jobs: [String], sessions: [String]) {
        var jobs: [JSONValue] = []
        if capabilities.contains("process.list") {
            let listed = try performAuthenticatedAgentOperation(reference: reference, operation: "process.list")
            jobs = listed.objectValue?["jobs"]?.arrayValue ?? []
        }
        // Durable sessions are owned by the VM helper, which reports the same
        // states that block Recovery security workflows.
        var sessions: [JSONValue] = []
        var token: String?
        repeat {
            var request: [String: Any] = ["command": "terminal.session", "operation": "terminal.list"]
            if let token { request["payload"] = ["pageToken": token] }
            let response = try JSONValue(any: PommeCore.sendControlObject(request, bundle: reference.bundle))
            guard let page = response.objectValue, page["ok"] == .bool(true),
                  let entries = page["sessions"]?.arrayValue else {
                throw PommeAgentUpdateError.agentUnavailable(vmName: reference.displayName)
            }
            sessions += entries
            token = page["nextPageToken"]?.stringValue
        } while token != nil
        return PommeAgentUpdateActiveWork.running(jobs: jobs, sessions: sessions)
    }

    private static func describeAgent(reference: VMReference, name: String) throws -> (digest: String, capabilities: [String]) {
        let value: JSONValue
        do { value = try performAuthenticatedAgentOperation(reference: reference, operation: "agent.describe") }
        catch { throw PommeAgentUpdateError.agentUnavailable(vmName: name) }
        guard let object = value.objectValue,
              object["role"]?.stringValue == PommeAgentRole.persistent.rawValue,
              let digest = object["executableSHA256"]?.stringValue,
              PommeProvisioningDigest.isSHA256(digest),
              let capabilities = object["capabilities"]?.arrayValue?.compactMap(\.stringValue)
        else { throw PommeAgentUpdateError.agentUnavailable(vmName: name) }
        return (digest, capabilities)
    }

    private static func agentUpdateResult(
        name: String, reference: VMReference, previous: String, digest: String, updated: Bool
    ) -> PommeOperationResult {
        result(
            title: "Agent Update",
            reference: reference,
            payload: [
                "ok": true,
                "name": name,
                "updated": updated,
                "previousExecutableDigest": previous,
                "executableDigest": digest,
                "hostExitCode": 0,
            ],
            text: updated
                ? "Updated the Pomme agent in \(name) to \(digest.prefix(12))."
                : "The Pomme agent in \(name) is already current (\(digest.prefix(12)))."
        )
    }
}

/// Selects the guest work an agent restart would orphan: background jobs
/// whose programs have not exited, and terminal sessions that are neither
/// exited nor lost. An entry whose state can't be read counts as running.
enum PommeAgentUpdateActiveWork {
    static func running(jobs: [JSONValue], sessions: [JSONValue]) -> (jobs: [String], sessions: [String]) {
        let runningJobs = jobs.compactMap { entry -> String? in
            guard let object = entry.objectValue, object["exited"] != .bool(true) else { return nil }
            return object["jobID"]?.stringValue ?? "unknown"
        }
        let liveSessions = sessions.compactMap { entry -> String? in
            guard let object = entry.objectValue,
                  !["exited", "lost"].contains(object["state"]?.stringValue) else { return nil }
            return object["sessionID"]?.stringValue ?? "unknown"
        }
        return (runningJobs, liveSessions)
    }
}
