import Foundation
import Testing

@Suite("MDM any-state orchestration")
struct PommeMDMOrchestrationTests {
    private typealias Facts = PommeMDMReadiness.Facts

    @Test("A missing VM is created, then enrolled, under one lease")
    func createsThenEnrolls() async throws {
        let harness = Harness(facts: [Facts(vmExists: false, provisioning: nil, runState: .unknown), ready()])
        var request = harness.request
        request.creation = .init(source: .template("base"), diskSize: "60GB", memory: "4GB", boot: .none)
        request.creationOptionsSupplied = true

        let result = try await PommeApplication.mdm(request, dependencies: harness.dependencies)

        #expect(result.ok)
        #expect(await harness.effects.values() == ["create:base:none", "enroll:leased"])
        #expect(stepNames(result) == ["create", "enroll"])
        #expect(stepStatuses(result) == ["completed", "completed"])
        #expect(result.text == "OK mdm steps=create,enroll")
        #expect(await harness.leaseChecks.values().allSatisfy { $0 })
    }

    @Test("Repeating the command on an existing VM skips creation and reports ignored options")
    func rerunSkipsCreation() async throws {
        let harness = Harness(facts: [ready()])
        var request = harness.request
        request.creation = .init(source: .template("base"), diskSize: "60GB", memory: "4GB", boot: .normal)
        request.creationOptionsSupplied = true

        let result = try await PommeApplication.mdm(request, dependencies: harness.dependencies)

        #expect(await harness.effects.values() == ["enroll:leased"])
        #expect(details(result)["creationOptionsIgnored"] as? Bool == true)
    }

    @Test("Incomplete creation and a retained security operation are finished before enrollment")
    func finishesPreparation() async throws {
        let retained = PommeMDMReadiness.RetainedSecurityWorkflow(
            operation: .sipDisable, phase: .autologinIntent, requestedFinalState: .normal)
        let harness = Harness(facts: [
            ready { $0.provisioning = .resumable(schema: 1, phase: "installRecoveryAgent") },
            ready { $0.retainedSecurity = retained },
            ready(),
        ])
        var request = harness.request
        request.force = true

        let result = try await PommeApplication.mdm(request, dependencies: harness.dependencies)

        #expect(result.ok)
        #expect(await harness.effects.values() == ["resume", "finish:sipDisable:normal:force", "enroll:leased"])
        #expect(stepNames(result) == ["resumeProvisioning", "finishSecurityWorkflow", "enroll"])
    }

    @Test("A blocked plan performs no effect and exits nonzero")
    func blockerHasNoEffects() async throws {
        let harness = Harness(facts: [ready { $0.provisioning = .blocked(schema: 2, reason: .ambiguousFirstBoot) }])

        let result = try await PommeApplication.mdm(harness.request, dependencies: harness.dependencies)

        #expect(!result.ok)
        #expect(result.hostExitCode == 1)
        #expect(await harness.effects.values().isEmpty)
        #expect(stepStatuses(result) == ["blocked"])
        let readiness = try #require(details(result)["readiness"] as? [String: Any])
        #expect((readiness["blockers"] as? [[String: String]])?.first?["code"] == "provisioning.ambiguousFirstBoot")
    }

    @Test("A step that does not change the plan is not repeated")
    func repeatedStepStops() async throws {
        let resumable = ready { $0.provisioning = .resumable(schema: 2, phase: "verifyNormalAgent") }
        let harness = Harness(facts: [resumable, resumable])

        let result = try await PommeApplication.mdm(harness.request, dependencies: harness.dependencies)

        #expect(!result.ok)
        #expect(await harness.effects.values() == ["resume"])
        #expect(stepStatuses(result) == ["completed", "failed"])
        #expect(details(result)["failureStatePreserved"] as? Bool == true)
    }

    @Test("A failed preparation step stops before enrollment and preserves state")
    func failedStepStops() async throws {
        let harness = Harness(facts: [ready { $0.provisioning = .resumable(schema: 1, phase: "restoreFinalState") }],
                              failResume: true)

        let result = try await PommeApplication.mdm(harness.request, dependencies: harness.dependencies)

        #expect(!result.ok)
        #expect(await harness.effects.values() == ["resume"])
        #expect(stepStatuses(result) == ["failed"])
        #expect(details(result)["retryAllowed"] as? Bool == true)
    }

    @Test("A dry run reports the plan without any effect")
    func dryRunHasNoEffects() async throws {
        let harness = Harness(facts: [ready { $0.provisioning = .resumable(schema: 1, phase: "installRecoveryAgent") }])
        var request = harness.request
        request.dryRun = true

        let result = try await PommeApplication.mdm(request, dependencies: harness.dependencies)

        #expect(result.ok)
        #expect(await harness.effects.values().isEmpty)
        #expect(stepNames(result) == ["resumeProvisioning", "enroll"])
        #expect(stepStatuses(result) == ["planned", "planned"])
        #expect(details(result)["dryRun"] as? Bool == true)
        #expect(result.text == "OK mdm plan steps=resumeProvisioning,enroll")
    }

    @Test("A dry run while another operation holds the lease reports it as a blocker")
    func dryRunWithBusyLease() async throws {
        let harness = Harness(facts: [ready()], leaseBusy: true)
        var request = harness.request
        request.dryRun = true

        let result = try await PommeApplication.mdm(request, dependencies: harness.dependencies)

        #expect(!result.ok)
        let readiness = try #require(details(result)["readiness"] as? [String: Any])
        #expect((readiness["blockers"] as? [[String: String]])?.first?["code"] == "mutationInProgress")
    }

    @Test("An untrusted server stops a new enrollment before any VM effect")
    func untrustedServerStops() async throws {
        let harness = Harness(facts: [Facts(vmExists: false, provisioning: nil, runState: .unknown)],
                              trust: .untrusted)
        var request = harness.request
        request.creation = .init(source: .version("latest", ipswDevice: nil), diskSize: "40GB", memory: "4GB",
                                 boot: .normal)

        let result = try await PommeApplication.mdm(request, dependencies: harness.dependencies)

        #expect(!result.ok)
        #expect(await harness.effects.values().isEmpty)
        #expect((details(result)["serverTrust"] as? [String: Any])?["result"] as? String == "untrusted")
    }

    @Test("An unusable creation source blocks before any effect")
    func unusableCreationSourceBlocks() async throws {
        let harness = Harness(facts: [Facts(vmExists: false, provisioning: nil, runState: .unknown)])
        var request = harness.request
        request.creation = .init(source: .template("missing"), diskSize: "60GB", memory: "4GB", boot: .normal)
        request.dryRun = true

        let result = try await PommeApplication.mdm(request, dependencies: harness.dependencies)

        #expect(!result.ok)
        #expect(await harness.effects.values().isEmpty)
        let readiness = try #require(details(result)["readiness"] as? [String: Any])
        #expect((readiness["blockers"] as? [[String: String]])?.first?["code"] == "creationUnavailable")
    }

    @Test("Skipping the preflight never probes the server")
    func skipPreflight() async throws {
        let harness = Harness(facts: [ready()], trust: .untrusted)
        var request = harness.request
        request.skipServerPreflight = true

        let result = try await PommeApplication.mdm(request, dependencies: harness.dependencies)

        #expect(result.ok)
        #expect(await harness.effects.values() == ["enroll:leased"])
    }

    @Test("An unreadable profile falls through to the engine's own retained-journal handling")
    func unreadableProfile() async throws {
        let harness = Harness(facts: [ready()], profileReadable: false)

        let result = try await PommeApplication.mdm(harness.request, dependencies: harness.dependencies)

        #expect(result.ok)
        #expect(await harness.effects.values() == ["enroll:unleased"])
    }

    private func ready(_ change: (inout Facts) -> Void = { _ in }) -> Facts {
        var facts = Facts(provisioning: .complete(schema: 2), runState: .stopped)
        change(&facts)
        return facts
    }
}

private func details(_ result: PommeOperationResult) -> [String: Any] {
    result.payload["result"] as? [String: Any] ?? [:]
}

private func steps(_ result: PommeOperationResult) -> [[String: Any]] {
    result.payload["steps"] as? [[String: Any]] ?? []
}

private func stepNames(_ result: PommeOperationResult) -> [String] {
    steps(result).compactMap { $0["name"] as? String }
}

private func stepStatuses(_ result: PommeOperationResult) -> [String] {
    steps(result).compactMap { $0["status"] as? String }
}

private struct Harness {
    let effects = Recorder()
    let leaseChecks = BoolRecorder()
    let request: PommeMDMCommandRequest
    let dependencies: PommeMDMOrchestratorDependencies

    init(facts: [PommeMDMReadiness.Facts], trust: MDMServerTrustDecision = .publicTrust, leaseBusy: Bool = false,
         failResume: Bool = false, profileReadable: Bool = true) {
        let name = "mdm-orchestration-\(UUID().uuidString.prefix(8).lowercased())"
        request = PommeMDMCommandRequest(name: name, profilePath: "/tmp/profile.mobileconfig", interactive: false)
        let effects = effects
        let leaseChecks = leaseChecks
        let queue = FactsQueue(facts)
        let profile = MDMEnrollmentProfileIdentity(identifier: "com.example.mdm", uuid: UUID(),
            serverURL: "https://mdm.example.test/mdm", digest: String(repeating: "d", count: 64))
        let material = MDMProfileTrustMaterial(serverURL: URL(string: "https://mdm.example.test/mdm")!,
                                               checkInURL: nil, certificates: [])
        dependencies = .init(
            readProfile: { _ in
                guard profileReadable else { throw MDMEnrollmentEvidenceError.missingEvidence }
                return (profile, material)
            },
            serverPreflight: { _ in
                .init(endpoints: [.init(endpoint: MDMServerEndpoint(material.serverURL), decision: trust)])
            },
            acquireLease: { name in
                guard !leaseBusy else { throw VMBundleMutationLease.Error.activeMutation(name: name) }
                return try VMBundleMutationLease.acquire(name: name)
            },
            assess: { _, _, _ in await queue.next() },
            checkCreation: { creation in
                guard case .template(let template) = creation.source, template == "missing" else { return nil }
                return "No template named missing."
            },
            create: { creation, name, lease in
                await leaseChecks.append(lease.validates(name: name))
                guard case .template(let template) = creation.source else { return await effects.append("create") }
                await effects.append("create:\(template):\(creation.boot.rawValue)")
            },
            resumeProvisioning: { name, lease in
                await leaseChecks.append(lease.validates(name: name))
                await effects.append("resume")
                if failResume { throw PommeProvisioningError.invalidJournal }
            },
            finishSecurity: { name, operation, finalState, force, lease in
                await leaseChecks.append(lease.validates(name: name))
                await effects.append("finish:\(operation.rawValue):\(finalState.rawValue)\(force ? ":force" : "")")
            },
            enroll: { request, lease in
                if let lease { await leaseChecks.append(lease.validates(name: request.name)) }
                await effects.append(lease == nil ? "enroll:unleased" : "enroll:leased")
                return PommeOperationResult(title: "MDM enrollment", vmName: request.name, ok: true, hostExitCode: 0,
                    text: "OK mdm", payload: ["ok": true, "operation": "mdm", "steps": [],
                                              "result": ["enrolled": true]])
            }
        )
    }
}

private actor FactsQueue {
    private var values: [PommeMDMReadiness.Facts]
    init(_ values: [PommeMDMReadiness.Facts]) { self.values = values }
    /// The last element repeats once the queue is drained.
    func next() -> PommeMDMReadiness.Facts { values.count > 1 ? values.removeFirst() : values[0] }
}

private actor Recorder {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func values() -> [String] { events }
}

private actor BoolRecorder {
    private var events: [Bool] = []
    func append(_ event: Bool) { events.append(event) }
    func values() -> [Bool] { events }
}
