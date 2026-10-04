import Darwin
import Foundation

/// Everything `pomme mdm` was asked to do.
struct PommeMDMCommandRequest: Sendable {
    var name: String
    var profilePath: String
    var guestPath: String? = nil
    var timeout: TimeInterval = Constants.defaultGuestCommandTimeout
    var enrollmentMode: MDMEnrollmentMode = .supervised
    var finalSecurity: MDMFinalSecurity = .restore
    var force = false
    var dryRun = false
    var skipServerPreflight = false
    /// How to create the VM if it does not exist.
    var creation: PommeCreationRequest? = nil
    var creationOptionsSupplied = false
    var interactive = false

    var readiness: PommeMDMReadiness.Request {
        .init(enrollmentMode: enrollmentMode, finalSecurity: finalSecurity, force: force,
              interactive: interactive, skipServerPreflight: skipServerPreflight,
              creationSourceSupplied: creation != nil, creationOptionsSupplied: creationOptionsSupplied)
    }
}

enum PommeMDMOrchestrationError: Error, LocalizedError, Equatable {
    case preparationRepeated(String)

    var errorDescription: String? {
        switch self {
        case .preparationRepeated(let step):
            "MDM preparation step \(step) did not reach the state it should have produced. Repeat the same command to resume."
        }
    }
}

/// The effects `pomme mdm` composes. Tests replace them; each live effect
/// records its own progress in its own journal, so a repeated command
/// rebuilds its plan from those records.
struct PommeMDMOrchestratorDependencies: Sendable {
    typealias Profile = (identity: MDMEnrollmentProfileIdentity, trust: MDMProfileTrustMaterial)

    var readProfile: @Sendable (String) throws -> Profile
    var serverPreflight: @Sendable (MDMProfileTrustMaterial) async -> MDMServerTrustReport
    var acquireLease: @Sendable (String) throws -> VMBundleMutationLease
    var assess: @Sendable (PommeMDMCommandRequest, MDMEnrollmentProfileIdentity?, VMBundleMutationLease?) async
        -> PommeMDMReadiness.Facts
    /// Why a creation source cannot be used, checked on the host only.
    var checkCreation: @Sendable (PommeCreationRequest) -> String?
    var create: @Sendable (PommeCreationRequest, String, VMBundleMutationLease) async throws -> Void
    var resumeProvisioning: @Sendable (String, VMBundleMutationLease) async throws -> Void
    var finishSecurity: @Sendable (String, PommeSecurityWorkflowOperation, VMFinalState, Bool, VMBundleMutationLease)
        async throws -> Void
    var enroll: @Sendable (PommeMDMCommandRequest, VMBundleMutationLease?) async throws -> PommeOperationResult

    static var live: Self {
        .init(
            readProfile: { path in
                let data = try PommeApplication.readMDMSourceProfile(
                    URL(fileURLWithPath: PommeCore.absoluteHostPath(path)))
                return (try MDMEnrollmentEvidenceParser.parseProfileIdentity(fromMobileconfig: data),
                        try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: data))
            },
            serverPreflight: { await MDMServerTrustPreflight.run($0, defaultAnchors: .systemRoots) },
            acquireLease: { try VMBundleMutationLease.acquire(name: $0) },
            assess: { request, profile, lease in
                await PommeApplication.mdmReadinessFacts(request: request, profile: profile, lease: lease)
            },
            checkCreation: { $0.hostProblem },
            create: { creation, name, lease in _ = try await creation.create(name: name, lease: lease) },
            resumeProvisioning: { name, lease in _ = try await PommeCore.resumeProvisioning(name: name, lease: lease) },
            finishSecurity: { name, operation, finalState, force, lease in
                if operation.isSIP {
                    _ = try await PommeApplication.sipWorkflow(name: name, action: operation.requestsDisabled ? .disable : .enable,
                        finalState: finalState, force: force, lease: lease)
                } else {
                    _ = try await PommeApplication.amfiWorkflow(name: name, action: operation.requestsDisabled ? .disable : .enable,
                        finalState: finalState, force: force, lease: lease)
                }
            },
            enroll: { request, lease in
                try await PommeApplication.mdmEnroll(
                    name: request.name, profilePath: request.profilePath, guestPath: request.guestPath,
                    timeout: request.timeout, enrollmentMode: request.enrollmentMode,
                    finalSecurity: request.finalSecurity, force: request.force, lease: lease)
            }
        )
    }
}

extension PommeApplication {
    /// Each preparation kind runs at most once; a second request for it
    /// means the step did not produce the state it promised.
    static let maximumMDMPreparationSteps = 3

    /// Brings a VM from any state to the requested enrollment: create it,
    /// finish its creation, finish a retained SIP/AMFI operation, then run
    /// the enrollment engine, which detects and prepares SIP and AMFI itself.
    static func mdm(
        _ request: PommeMDMCommandRequest, dependencies: PommeMDMOrchestratorDependencies = .live
    ) async throws -> PommeOperationResult {
        let progressSink = PommeProgressContext.sink
        progressSink?.step(vm: request.name, "Preparing MDM enrollment")
        let profile: PommeMDMOrchestratorDependencies.Profile
        do {
            profile = try dependencies.readProfile(request.profilePath)
        } catch {
            // Without a readable profile nothing can be planned. The engine
            // still resumes or restores an unfinished enrollment for the same
            // VM and mode from its journal, exactly as before.
            guard !request.dryRun else { throw error }
            return try await dependencies.enroll(request, nil)
        }
        if !request.skipServerPreflight { progressSink?.step(vm: request.name, "Checking MDM server") }
        let trust = request.skipServerPreflight ? nil : await dependencies.serverPreflight(profile.trust)
        if let trust {
            PommeCore.log("MDM server preflight: \(trust.decision.rawValue).", vmName: request.name)
        }
        let lease: VMBundleMutationLease?
        if request.dryRun { lease = try? dependencies.acquireLease(request.name) }
        else { lease = try dependencies.acquireLease(request.name) }
        defer { lease?.release() }

        var steps: [[String: Any]] = []
        var completed: Set<String> = []
        for iteration in 0...maximumMDMPreparationSteps {
            var facts = await dependencies.assess(request, profile.identity, lease)
            facts.mutationInProgress = lease == nil
            facts.serverTrust = trust?.decision
            if !facts.vmExists, let creation = request.creation { facts.creationProblem = dependencies.checkCreation(creation) }
            let plan = PommeMDMReadiness.plan(facts, request: request.readiness)
            if iteration == 0 {
                for warning in plan.warnings { progressWarning("Warning: \(warning.message)", vmName: request.name) }
            }
            let context = MDMPlanContext(request: request, facts: facts, plan: plan, trust: trust)
            if request.dryRun || !plan.blockers.isEmpty {
                return mdmPlanResult(context, completed: steps)
            }
            guard let lease else { return mdmPlanResult(context, completed: steps) }
            guard let step = plan.nextPreparation else {
                progressSink?.step(vm: request.name, "Enrolling in MDM")
                PommeCore.log("MDM preparation complete; starting enrollment.", vmName: request.name)
                do {
                    let result = try await dependencies.enroll(request, lease)
                    return mdmMergedResult(result, context: context,
                        steps: steps + [mdmStep(.enroll, status: result.ok ? "completed" : "failed")])
                } catch {
                    return mdmFailureResult(context, steps: steps + [mdmStep(.enroll, status: "failed")], error: error)
                }
            }
            guard completed.insert(step.name).inserted else {
                return mdmFailureResult(context, steps: steps + [mdmStep(step, status: "failed")],
                                        error: PommeMDMOrchestrationError.preparationRepeated(step.name))
            }
            progressSink?.step(vm: request.name, step.detail)
            PommeCore.log("MDM preparation: \(step.detail)", vmName: request.name)
            do {
                switch step {
                case .create:
                    guard let creation = request.creation else { return mdmPlanResult(context, completed: steps) }
                    try await dependencies.create(creation, request.name, lease)
                case .resumeProvisioning:
                    try await dependencies.resumeProvisioning(request.name, lease)
                case .finishSecurityWorkflow(let operation, let finalState):
                    try await dependencies.finishSecurity(request.name, operation, finalState, request.force, lease)
                case .enroll:
                    break
                }
                steps.append(mdmStep(step, status: "completed"))
            } catch {
                return mdmFailureResult(context, steps: steps + [mdmStep(step, status: "failed")], error: error)
            }
        }
        throw PommeMDMOrchestrationError.preparationRepeated("preparation")
    }

    /// Host facts, retained journals, and, only when the VM is already
    /// running normal macOS with a verified agent, read-only guest facts.
    /// Nothing here boots, stops, or writes to the VM.
    static func mdmReadinessFacts(
        request: PommeMDMCommandRequest, profile: MDMEnrollmentProfileIdentity?, lease: VMBundleMutationLease?
    ) async -> PommeMDMReadiness.Facts {
        guard let reference = try? namedReference(request.name, requireExists: false),
              FileManager.default.fileExists(atPath: reference.bundle.rootURL.path) else {
            return .init(vmExists: false, provisioning: nil, runState: .unknown)
        }
        var facts = PommeMDMReadiness.Facts()
        facts.provisioning = PommeCore.provisioningReadiness(reference: reference)
        facts.runState = (try? PommeCore.stableVMRunState(reference: reference)).map(PommeMDMReadiness.RunState.init)
            ?? .unknown
        facts.pendingSnapshotRestore = facts.runState == .stopped
            && [reference.bundle.saveStateURL, reference.bundle.requiredSnapshotRestoreURL]
                .contains { FileManager.default.fileExists(atPath: $0.path) }
        if let lease {
            let bundleURL = reference.bundle.rootURL
            if let journal = try? PommeMDMEnrollmentJournalStore(bundleURL: bundleURL).loadIfPresent(lease: lease) {
                facts.retainedEnrollment = .init(journal, profile: profile, request: request.readiness)
            }
            if let child = try? PommeSecurityWorkflowJournalStore(bundleURL: bundleURL).loadIfPresent(lease: lease) {
                facts.retainedSecurity = .init(operation: child.operation, phase: child.phase,
                                               requestedFinalState: child.requestedFinalState)
            }
        }
        guard facts.runState == .running(.normal), case .complete = facts.provisioning,
              let plan = try? PommeCore.securityProvisioningPlan(reference: reference),
              let currentDigest = try? PommeCore.currentNormalAgentDigest(plan: plan) else { return facts }
        let timeout = min(request.timeout, 15)
        // A describe that does not answer yet is not evidence; the engine
        // waits for the agent itself. Only a completed answer is classified.
        guard let description = try? await authenticatedMDMAgentDescription(reference: reference, timeout: timeout)
        else { return facts }
        facts.agent = MDMEnrollmentAgentGate.classify(description,
                                                      expectedExecutableDigest: currentDigest)
        guard facts.agent == .ready else { return facts }
        if let profile, let observed = try? await observeMDMEnrollment(reference: reference, timeout: timeout) {
            do {
                switch try observed.disposition(profile: profile, mode: request.enrollmentMode) {
                case .install: facts.enrollment = .install
                case .upgrade: facts.enrollment = .upgrade
                case .satisfied: facts.enrollment = .satisfied
                }
            } catch PommeMDMWorkflowFailure.conflictingEnrollment {
                facts.enrollment = .conflicting
            } catch PommeMDMWorkflowFailure.downgradeUnsupported {
                facts.enrollment = .downgrade
            } catch {}
        }
        do {
            facts.sipDisabled = try await observeMDMNormalSecurity(reference: reference, timeout: timeout).sipDisabled
            facts.securityBaselineSupported = true
        } catch PommeMDMWorkflowFailure.securityBaselineUnsupported {
            facts.securityBaselineSupported = false
        } catch {}
        if let group = try? PommeCore.provisioningRuntimeMetadata(for: plan).startupVolumeGroupUUID,
           let amfi = PommeSecurityNormalAgent(reference: reference,
                                               expectedExecutableDigest: currentDigest)
            .observeAMFIState(volumeGroupUUID: group) {
            facts.amfiDisabled = amfi.disabled
        }
        return facts
    }

    fileprivate struct MDMPlanContext {
        let request: PommeMDMCommandRequest
        let facts: PommeMDMReadiness.Facts
        let plan: PommeMDMReadiness.Plan
        let trust: MDMServerTrustReport?

        var details: [String: Any] {
            [
                "dryRun": request.dryRun,
                "readiness": PommeMDMReadiness.publicValue(facts, plan: plan),
                "serverTrust": trust?.publicValue as Any? ?? NSNull(),
                "creationOptionsIgnored": plan.warnings.contains(.creationOptionsIgnored),
                "enrollmentMode": request.enrollmentMode.rawValue,
                "finalSecurity": request.finalSecurity.rawValue,
            ]
        }

        var reference: VMReference {
            (try? PommeApplication.namedReference(request.name, requireExists: false))
                ?? VMReference(name: request.name, bundle: BundleLayout(rootURL: URL(fileURLWithPath: "/")))
        }
    }

    fileprivate static func mdmStep(_ step: PommeMDMReadiness.Step, status: String) -> [String: Any] {
        ["name": step.name, "status": status, "detail": step.detail]
    }

    /// A dry run, or a plan stopped by blockers before any effect.
    fileprivate static func mdmPlanResult(_ context: MDMPlanContext, completed: [[String: Any]]) -> PommeOperationResult {
        let status = context.plan.blockers.isEmpty ? "planned" : "blocked"
        let remaining = context.plan.steps.map { mdmStep($0, status: status) }
        let ok = context.plan.blockers.isEmpty
        let error = context.plan.blockers.map(\.message).joined(separator: " ")
        var result = mdmResult(title: "MDM enrollment", operation: "mdm", reference: context.reference, ok: ok,
            agent: [:], steps: completed + remaining, result: context.details, error: ok ? nil : error)
        if ok {
            result = .init(title: result.title, vmName: result.vmName, ok: true, hostExitCode: 0,
                text: "OK mdm plan steps=\(context.plan.steps.map(\.name).joined(separator: ","))",
                payload: result.payload)
        }
        return result
    }

    fileprivate static func mdmFailureResult(
        _ context: MDMPlanContext, steps: [[String: Any]], error: any Error
    ) -> PommeOperationResult {
        var details = context.details
        details["failureStatePreserved"] = true
        details["retryAllowed"] = true
        progressWarning("MDM stopped; state is preserved. Repeat the same command to resume.", vmName: context.request.name)
        return mdmResult(title: "MDM enrollment", operation: "mdm", reference: context.reference, ok: false,
            agent: [:], steps: steps, result: details, error: error.localizedDescription)
    }

    /// The engine's result, with the steps that preceded it and the plan.
    fileprivate static func mdmMergedResult(
        _ result: PommeOperationResult, context: MDMPlanContext, steps: [[String: Any]]
    ) -> PommeOperationResult {
        var payload = result.payload
        payload["steps"] = steps
        var details = payload["result"] as? [String: Any] ?? [:]
        for (key, value) in context.details where details[key] == nil { details[key] = value }
        payload["result"] = details
        let text = result.ok
            ? "\(result.text) steps=\(steps.compactMap { $0["name"] as? String }.joined(separator: ","))"
            : result.text
        return .init(title: result.title, vmName: result.vmName, ok: result.ok,
                     hostExitCode: result.hostExitCode, text: text, payload: payload)
    }
}
