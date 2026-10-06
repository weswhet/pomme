import Foundation
import Testing

@Suite("VM creation planning")
struct VMCreationPlanningTests {
    @Test("JSON, YAML, TOML, and Pkl decode the same schema")
    func formatsProduceSameModel() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = sampleConfig()

        for extensionName in ["json", "yaml", "toml"] {
            let url = directory.appendingPathComponent("config.\(extensionName)")
            try CreateConfigStore.encode(config, to: url).write(to: url)
            let decoded = try CreateConfigStore.load(path: url.path)
            #expect(decoded.schemaVersion == 1)
            #expect(decoded.name == "lab")
            #expect(decoded.versions == ["latest", "26.6.0"])
            #expect(decoded.hardware?.diskSize == "64GB")
            #expect(decoded.boot == .recovery)
        }

        let pklURL = directory.appendingPathComponent("config.pkl")
        try Data("schemaVersion = 1\n".utf8).write(to: pklURL)
        let json = try CreateConfigStore.encode(config, to: directory.appendingPathComponent("fixture.json"))
        let decoded = try CreateConfigStore.load(path: pklURL.path, pklEvaluator: { _ in json })
        #expect(decoded.versions == config.versions)
        #expect(decoded.hardware?.memory == "12GB")
    }

    @Test("Unsupported keys produce a targeted regeneration error", arguments: [
        ("json", #"{"schemaVersion":1,"name":"lab","versions":["latest"],"restore":{}}"#),
        ("yaml", "schemaVersion: 1\nname: lab\nversions: [latest]\nreplaceExisting: true\n"),
        ("toml", "schemaVersion = 1\nname = \"lab\"\nversions = [\"latest\"]\nfailureCleanup = \"restore-security\"\n")
    ])
    func unsupportedKeyRejection(extensionName: String, contents: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unsupported.\(extensionName)")
        try Data(contents.utf8).write(to: url)
        do {
            _ = try CreateConfigStore.load(path: url.path)
            Issue.record("Expected unsupported config rejection.")
        } catch {
            #expect(error.localizedDescription.contains("pomme config init"))
        }
    }

    @Test("Config decode failures name the key or the syntax position in plain words", arguments: [
        ("yaml", "name: lab\nversions: [latest]\n", "Config is missing required key 'schemaVersion'."),
        ("json", #"{"name":"lab","versions":["latest"]}"#, "Config is missing required key 'schemaVersion'."),
        ("toml", "name = \"lab\"\nversions = [\"latest\"]\n", "Config is missing required key 'schemaVersion'."),
        ("json", #"{"schemaVersion":1,"name":"lab","versions":["latest"],"hardware":{"memory":4}}"#,
         "Config key 'hardware.memory' must be a string."),
        ("toml", "schemaVersion = 1\nname = \"lab\"\nversions = [\"latest\"]\n[hardware]\nmemory = 4\n",
         "Config key 'hardware.memory' must be a string."),
        ("yaml", "schemaVersion: 1\nname: lab\nversions: [latest\n", "Config is not valid YAML at line "),
        ("yaml", "schemaVersion: 1\n\tname: lab\n", "Config is not valid YAML at line 2, column "),
        ("json", #"{"schemaVersion":1,"#, "Config is not valid JSON: "),
        ("toml", "schemaVersion = = 1\n", "Config is not valid TOML at line 1, column ")
    ])
    func decodeFailuresArePlain(extensionName: String, contents: String, expected: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bad.\(extensionName)")
        try Data(contents.utf8).write(to: url)

        let error = #expect(throws: RunnerError.self) { try CreateConfigStore.load(path: url.path) }
        let message = error?.localizedDescription ?? ""
        #expect(message.hasPrefix(url.standardizedFileURL.path + ": " + expected), "\(message)")
        #expect(!message.contains("CodingKeys("))
    }

    @Test("Unknown config keys are rejected with the known keys named", arguments: [
        ("yaml", "schemaVersion: 1\nname: lab\nversions: [latest]\nbogusKey: 1\n",
         "Config key 'bogusKey' is not recognized. Known keys: boot, credentials, hardware, ipswDevice, mdm, name, schemaVersion, versions, workflow."),
        ("json", #"{"schemaVersion":1,"name":"lab","versions":["latest"],"hardware":{"memroy":"4GB"}}"#,
         "Config key 'hardware.memroy' is not recognized. Known keys: diskSize, memory."),
        ("yaml", "schemaVersion: 1\nname: lab\nversions: [latest]\nhardware:\n  memroy: 4GB\n",
         "Config key 'hardware.memroy' is not recognized. Known keys: diskSize, memory."),
        ("toml", "schemaVersion = 1\nname = \"lab\"\nversions = [\"latest\"]\n[hardware]\nmemroy = \"4GB\"\n",
         "Config key 'hardware.memroy' is not recognized. Known keys: diskSize, memory.")
    ])
    func unknownKeysAreRejected(extensionName: String, contents: String, expected: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unknown.\(extensionName)")
        try Data(contents.utf8).write(to: url)

        let error = #expect(throws: RunnerError.self) { try CreateConfigStore.load(path: url.path) }
        #expect(error?.localizedDescription == expected)
    }

    @Test("Creation configs reject security, credential, and enrollment controls")
    func unsupportedCreationControlsAreRejectedBeforePlanning() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = [
            #"{"schemaVersion":1,"name":"lab","versions":["26.6.0"],"credentials":{"sipUser":"admin"}}"#,
            #"{"schemaVersion":1,"name":"lab","versions":["26.6.0"],"workflow":{"disableSIP":true}}"#,
            #"{"schemaVersion":1,"name":"lab","versions":["26.6.0"],"mdm":{"enabled":true}}"#
        ]

        for (index, contents) in fixtures.enumerated() {
            let url = directory.appendingPathComponent("unsupported-\(index).json")
            try Data(contents.utf8).write(to: url)
            do {
                _ = try CreateConfigStore.load(path: url.path)
                Issue.record("Expected unsupported create controls to be rejected.")
            } catch {
                #expect(error.localizedDescription.contains("Create configs cannot contain"))
            }
        }
    }

    @Test("Planner resolves exact names and checks every collision before execution")
    func plannerResolutionAndCollisionAtomicity() async throws {
        let calls = PlanningCalls()
        let planner = VMCreationPlanner(dependencies: .init(
            firmwareLookup: { selector, _ in
                await calls.resolved(selector)
                return firmware(version: selector == "latest" ? "16.0" : selector, build: "B-\(selector)")
            },
            profileSelection: { _ in PommeRecoveryProfileSelector.tahoe2660Build25G72 },
            managedVMCollision: { name in name.hasSuffix("26.6.0") }
        ))
        do {
            _ = try await planner.plans(for: sampleConfig())
            Issue.record("Expected collision rejection.")
        } catch {
            #expect(error.localizedDescription.contains("lab-26.6.0"))
        }
        #expect(await calls.selectors == ["latest", "26.6.0"])
    }

    @Test("Executor bounds concurrency, preserves order, and aggregates sibling failures")
    func executorOrderingAndFailures() async throws {
        let probe = ExecutionProbe()
        let config = sampleConfig()
        let plans = (0..<5).map { index in
            VMCreationPlan(
                name: "lab-\(index)",
                selector: "\(index)",
                firmware: firmware(version: "\(index)", build: "B\(index)"),
                config: config,
                recoveryProfile: PommeRecoveryProfileSelector.tahoe2660Build25G72
            )
        }
        let executor = VMCreationExecutor(dependencies: .init(install: { plan in
            await probe.enter()
            try await Task.sleep(for: .milliseconds(10))
            await probe.leave()
            if plan.name == "lab-2" { throw TestFailure.failed }
            return operationResult(name: plan.name, ok: true)
        }))

        let results = try await executor.execute(plans, dryRun: false, parallelism: 2)
        #expect(results.map(\.vmName) == plans.map(\.name))
        #expect(results.map(\.ok) == [true, true, false, true, true])
        #expect(await probe.maximum == 2)

        await #expect(throws: RunnerError.self) {
            _ = try await executor.execute(plans, dryRun: false, parallelism: 3)
        }
    }

    @Test("Config dry-run resolves plans but does not install")
    func configDryRun() async throws {
        let installs = InstallCounter()
        let config = sampleConfig()
        let plan = VMCreationPlan(
            name: "lab-16.0",
            selector: "latest",
            firmware: firmware(version: "16.0", build: "B16"),
            config: config,
            recoveryProfile: PommeRecoveryProfileSelector.tahoe2660Build25G72
        )
        let executor = VMCreationExecutor(dependencies: .init(install: { plan in
            await installs.increment()
            return operationResult(name: plan.name, ok: true)
        }))
        let results = try await executor.execute([plan], dryRun: true, parallelism: 1)
        #expect(results[0].payload["dryRun"] as? Bool == true)
        #expect(await installs.value == 0)

        let refusing = VMCreationExecutor(dependencies: .init(
            install: { plan in
                await installs.increment()
                return operationResult(name: plan.name, ok: true)
            },
            dryRunPreflight: { _ in throw RunnerError.hostCommandFailed("The plan would not install.") }
        ))
        let refused = try await refusing.execute([plan], dryRun: true, parallelism: 1)
        #expect(refused[0].ok == false)
        #expect(refused[0].payload["error"] as? String == "The plan would not install.")
        #expect(refused[0].payload["dryRun"] as? Bool == true)
        #expect(await installs.value == 0)
    }

    @Test("Live config dry-run discloses provisioning without credentials", arguments: ["27.0", "26.6.0"])
    func liveDryRunProvisioningDisclosure(version: String) async throws {
        // The live preflight checks memory against this host's Virtualization
        // limit, which is its physical memory: 7 GiB on GitHub's runners. Use
        // the 4 GB floor so the result doesn't depend on the host.
        let plan = VMCreationPlan(
            name: "lab-\(version)", selector: version,
            firmware: firmware(version: version, build: "dry-run-\(UUID().uuidString)"),
            config: sampleConfig(memory: "4GB"),
            recoveryProfile: PommeRecoveryProfileSelector.tahoe2660Build25G72
        )
        let executor = VMCreationExecutor(dependencies: .init(
            install: { _ in
                Issue.record("Dry-run must not install a guest.")
                throw TestFailure.failed
            },
            dryRunPreflight: VMCreationExecutionDependencies.live.dryRunPreflight
        ))
        let result = try #require(await executor.execute([plan], dryRun: true, parallelism: 1).first)
        #expect(result.ok)
        let virtualization = PommeCore.usesVirtualizationProvisioning(
            guestVersion: version, firstBootEligible: true)
        #expect(result.payload["guestProvisioning"] as? String == (virtualization ? "virtualization" : "recovery"))
        #expect(result.payload["agentInstallMethod"] as? String == (virtualization ? "ssh-bootstrap" : "recovery"))
        #expect(result.payload["automaticLogin"] as? String == (virtualization ? "enabled" : "legacy"))
        #expect(result.payload["remoteLogin"] as? String == (virtualization ? "off" : "legacy"))
        #expect(result.payload["account"] as? String == (virtualization ? "pomme" : nil))
        let rendered = String(decoding: try JSONSerialization.data(withJSONObject: result.payload), as: UTF8.self)
        for secretField in ["password", "agentToken", "ownerCredential", "keychain", "bootstrapRequest"] {
            #expect(!rendered.localizedCaseInsensitiveContains(secretField))
        }
    }

    private func sampleConfig(memory: String = "12GB") -> VMCreationConfigV1 {
        VMCreationConfigV1(
            schemaVersion: 1,
            name: "lab",
            versions: ["latest", "26.6.0"],
            ipswDevice: "VirtualMac2,1",
            hardware: .init(diskSize: "64GB", memory: memory),
            credentials: nil,
            workflow: nil,
            mdm: nil,
            boot: .recovery
        )
    }

    @Test("Reviewed Tahoe and unreviewed identities have explicit qualifications")
    func profileQualification() throws {
        let tahoe = firmware(version: "26.6.0", build: "25G72")
        let sequoia = firmware(version: "15.6.1", build: "24G90")
        let latestTahoe = firmware(version: "26.6.2", build: "25G83")
        let newer = firmware(version: "27.0.0", build: "26A123b")

        let selected = try PommeRecoveryProfileSelector.select(for: tahoe)
        let feedSelected = try PommeRecoveryProfileSelector.select(
            for: firmware(version: "26.6", build: "25G72")
        )
        let latestSelected = try PommeRecoveryProfileSelector.select(for: latestTahoe)
        let newerSelected = try PommeRecoveryProfileSelector.select(for: newer)
        let pendingSelected = try PommeRecoveryProfileSelector.select(for: sequoia)
        #expect(selected.id == "tahoe-26.6.0-25G72-en-1280x800")
        #expect(feedSelected == selected)
        #expect(selected.qualification == .accepted)
        #expect(selected.locale == "en")
        #expect(selected.displayWidth == 1280)
        #expect(selected.displayHeight == 800)
        #expect(PommeCreateAgentPlanRequest(profile: selected).recoveryProfileDigest == selected.digest)
        #expect(latestSelected.qualification == .experimental)
        #expect(latestSelected.version == "26.6.2")
        #expect(latestSelected.build == "25G83")
        #expect(try latestSelected == PommeRecoveryProfileSelector.descriptor(version: "26.6.2", build: "25G83"))
        #expect(newerSelected.qualification == .experimental)
        #expect(newerSelected.version == "27.0.0")
        #expect(newerSelected.build == "26A123b")
        #expect(pendingSelected.qualification == .experimental)
        #expect(pendingSelected.version == "15.6.1")
        #expect(pendingSelected.build == "24G90")
        #expect(try latestSelected.digest == PommeRecoveryProfileSelector.descriptor(version: "26.6.2", build: "25G83").digest)
        #expect(throws: PommeRecoveryProfileSelectionError.self) {
            _ = try PommeRecoveryProfileSelector.select(for: firmware(version: "not-an-os-version", build: "25G99"))
        }
        #expect(throws: PommeRecoveryProfileSelectionError.self) {
            _ = try PommeRecoveryProfileSelector.select(for: firmware(version: "26.6.2", build: "not-a-build"))
        }
    }

    @Test("Malformed restore identity fails before an executor could mutate any batch member")
    func malformedProfileBlocksWholeBatch() async throws {
        let calls = PlanningCalls()
        let planner = VMCreationPlanner(dependencies: .init(
            firmwareLookup: { selector, _ in
                await calls.resolved(selector)
                return selector == "latest"
                    ? firmware(version: "26.6.0", build: "25G72")
                    : firmware(version: "99.invalid", build: "Z99")
            },
            profileSelection: PommeRecoveryProfileSelector.select,
            managedVMCollision: { _ in
                Issue.record("Collision checks must not run after a failed profile preflight.")
                return false
            }
        ))

        do {
            _ = try await planner.plans(for: sampleConfig())
            Issue.record("Expected profile preflight to reject the whole batch.")
        } catch {
            #expect(error.localizedDescription.contains("99.invalid"))
        }
        #expect(await calls.selectors == ["latest", "26.6.0"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-create-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum TestFailure: Error { case failed }

    private actor PlanningCalls {
        private(set) var selectors: [String] = []
        func resolved(_ selector: String) { selectors.append(selector) }
    }

    private actor ExecutionProbe {
        private var current = 0
        private(set) var maximum = 0
        func enter() { current += 1; maximum = max(maximum, current) }
        func leave() { current -= 1 }
    }

    private actor InstallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}

private func firmware(version: String, build: String) -> IPSWMEFirmware {
    IPSWMEFirmware(
        identifier: "VirtualMac2,1",
        version: version,
        buildid: build,
        filesize: 1,
        url: "https://example.invalid/restore.ipsw",
        releasedate: nil,
        uploaddate: nil,
        signed: true,
        sha1sum: nil,
        md5sum: nil,
        sha256sum: nil
    )
}

private func operationResult(name: String, ok: Bool) -> PommeOperationResult {
    PommeOperationResult(
        title: "Create VM",
        vmName: name,
        ok: ok,
        hostExitCode: ok ? 0 : 1,
        text: name,
        payload: ["ok": ok, "name": name, "hostExitCode": ok ? 0 : 1]
    )
}
