import Foundation
import TOML
import Yams

/// The sole public creation-config schema. JSON, YAML, TOML, and Pkl are
/// decoding adapters for this same domain value.
struct VMCreationConfigV1: Codable, Sendable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var name: String
    var versions: [String]
    var ipswDevice: String?
    var hardware: Hardware?
    var credentials: Credentials?
    var workflow: Workflow?
    var mdm: MDM?
    var boot: BootMode?

    struct Hardware: Codable, Sendable {
        var diskSize: String? = nil
        var memory: String? = nil
    }

    struct Credentials: Codable, Sendable {
        var sipUser: String? = nil
        var sipBootstrapAccount: Bool? = nil
        var sipBootstrapUser: String? = nil
        var sipPasswordEnv: String? = nil
        var sipKeychain: String? = nil
    }

    struct Workflow: Codable, Sendable {
        var bootRecoveryAfterCreate: Bool? = nil
        var disableSIP: Bool? = nil
        var disableAMFI: Bool? = nil
        var bootNormalBeforeMDM: Bool? = nil
        var reenableAMFI: Bool? = nil
        var reenableSIP: Bool? = nil
        var finalBoot: BootMode? = nil
        var enableRemoteLogin: Bool? = nil

        var shouldBootRecoveryAfterCreate: Bool { bootRecoveryAfterCreate ?? false }
        var shouldDisableSIP: Bool { disableSIP ?? false }
        var shouldDisableAMFI: Bool { disableAMFI ?? false }
        var shouldBootNormalBeforeMDM: Bool { bootNormalBeforeMDM ?? false }
        var shouldReenableAMFI: Bool { reenableAMFI ?? true }
        var shouldReenableSIP: Bool { reenableSIP ?? true }
        var shouldEnableRemoteLogin: Bool { enableRemoteLogin ?? false }
    }

    struct MDM: Codable, Sendable {
        var enabled: Bool? = nil
        var method: MDMEnrollmentMethod? = nil
        var profile: String? = nil
        var guestPath: String? = nil

        var resolvedEnabled: Bool { enabled ?? false }
        var resolvedMethod: MDMEnrollmentMethod { method ?? .defaultMethod }
    }

    enum BootMode: String, Codable, CaseIterable, Sendable {
        case none
        case normal
        case recovery
    }
}

typealias ConfigBootMode = VMCreationConfigV1.BootMode

/// One fully resolved VM in a batch creation plan.
struct VMCreationPlan: Sendable {
    let name: String
    let selector: String
    let firmware: IPSWMEFirmware
    let config: VMCreationConfigV1
    let recoveryProfile: PommeCreateRecoveryProfileDescriptor
    let agentRequest: PommeCreateAgentPlanRequest

    init(
        name: String,
        selector: String,
        firmware: IPSWMEFirmware,
        config: VMCreationConfigV1,
        recoveryProfile: PommeCreateRecoveryProfileDescriptor
    ) {
        self.name = name
        self.selector = selector
        self.firmware = firmware
        self.config = config
        self.recoveryProfile = recoveryProfile
        agentRequest = .init(profile: recoveryProfile)
    }

    var payload: [String: Any] {
        [
            "name": name,
            "selector": selector,
            "version": firmware.version,
            "build": firmware.buildid,
            "ipswDevice": config.ipswDevice ?? firmware.identifier,
            "diskSize": config.hardware?.diskSize ?? "60GB",
            "memory": config.hardware?.memory ?? "8GB",
            "boot": (config.boot ?? .none).rawValue,
            "recoveryProfile": [
                "id": recoveryProfile.id,
                "digest": recoveryProfile.digest,
                "qualification": recoveryProfile.qualification.rawValue,
                "locale": recoveryProfile.locale,
                "display": "\(recoveryProfile.displayWidth)x\(recoveryProfile.displayHeight)"
            ],
            "agent": [
                "recoveryProfileID": agentRequest.recoveryProfileID,
                "recoveryProfileDigest": agentRequest.recoveryProfileDigest
            ]
        ]
    }
}

/// Loads and renders create configs in every supported format.
enum CreateConfigStore {
    typealias PklEvaluator = @Sendable (URL) throws -> Data

    /// Loads and validates the config at `path` based on its extension.
    static func load(
        path: String,
        pklEvaluator: PklEvaluator = { try evaluatePkl(at: $0) }
    ) throws -> VMCreationConfigV1 {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RunnerError.hostCommandFailed("Config file does not exist: \(url.path)")
        }

        let config: VMCreationConfigV1
        switch url.pathExtension.lowercased() {
        case "json":
            let data = try Data(contentsOf: url)
            try rejectUnsupportedShape(String(decoding: data, as: UTF8.self))
            config = try JSONDecoder().decode(VMCreationConfigV1.self, from: data)
        case "yaml", "yml":
            let text = try String(contentsOf: url, encoding: .utf8)
            try rejectUnsupportedShape(text)
            config = try YAMLDecoder().decode(VMCreationConfigV1.self, from: text)
        case "toml":
            let text = try String(contentsOf: url, encoding: .utf8)
            try rejectUnsupportedShape(text)
            config = try TOMLDecoder().decode(VMCreationConfigV1.self, from: text)
        case "pkl":
            let data = try pklEvaluator(url)
            try rejectUnsupportedShape(String(decoding: data, as: UTF8.self))
            config = try JSONDecoder().decode(VMCreationConfigV1.self, from: data)
        default:
            throw RunnerError.hostCommandFailed("Unsupported config format .\(url.pathExtension). Use .json, .yaml, .yml, .toml, or .pkl.")
        }

        try validate(config)
        return config
    }

    /// Encodes a starter config using the extension of `url`.
    static func encode(_ config: VMCreationConfigV1, to url: URL) throws -> Data {
        switch url.pathExtension.lowercased() {
        case "json":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(config)
            data.append(0x0A)
            return data
        case "yaml", "yml":
            let text = try YAMLEncoder().encode(config)
            return Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
        case "toml":
            return try TOMLEncoder().encode(config)
        case "pkl":
            return Data(pklStarter(config).utf8)
        default:
            throw RunnerError.hostCommandFailed("Unsupported config format .\(url.pathExtension). Use .json, .yaml, .yml, .toml, or .pkl.")
        }
    }

    private static func validate(_ config: VMCreationConfigV1) throws {
        guard config.schemaVersion == VMCreationConfigV1.supportedSchemaVersion else {
            throw RunnerError.hostCommandFailed(
                "Unsupported schemaVersion \(config.schemaVersion). Expected \(VMCreationConfigV1.supportedSchemaVersion)."
            )
        }
        _ = try validateVMName(config.name)
        guard !config.versions.isEmpty else {
            throw RunnerError.hostCommandFailed("Config versions must contain at least one version selector.")
        }
        let trimmed = config.versions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ !$0.isEmpty }) else {
            throw RunnerError.hostCommandFailed("Config versions cannot contain empty selectors.")
        }
        guard Set(trimmed.map { $0.lowercased() }).count == trimmed.count else {
            throw RunnerError.hostCommandFailed("Config versions must not contain duplicate selectors.")
        }
        // Creation is deliberately limited to durable Pomme provisioning. It
        // never carries credentials, security mutations, or enrollment work;
        // those are explicit operations with their own authenticated
        // Recovery/normal-agent gates. Reject these fields while still
        // decoding them so an old config cannot silently change semantics.
        guard config.credentials == nil else {
            throw RunnerError.hostCommandFailed(
                "Create configs cannot contain credentials. Use the explicit Pomme security operation."
            )
        }
        guard config.workflow == nil else {
            throw RunnerError.hostCommandFailed(
                "Create configs cannot contain workflow controls. Use --boot for the final state."
            )
        }
        guard config.mdm == nil else {
            throw RunnerError.hostCommandFailed(
                "Create configs cannot contain MDM enrollment. Use the explicit Pomme MDM operation."
            )
        }
        if let device = config.ipswDevice, !IPSWDeviceIdentifier.isValid(device) {
            throw RunnerError.hostCommandFailed("ipswDevice must be an Apple model identifier such as Mac16,10.")
        }
        if let diskSize = config.hardware?.diskSize, ByteSizeParser.parse(diskSize) == nil {
            throw RunnerError.invalidSize(flag: "hardware.diskSize", value: diskSize)
        }
        if let memory = config.hardware?.memory, ByteSizeParser.parse(memory) == nil {
            throw RunnerError.invalidSize(flag: "hardware.memory", value: memory)
        }
    }

    private static func rejectUnsupportedShape(_ text: String) throws {
        let unsupportedKeys = ["restore", "replaceExisting", "failureCleanup"]
        for key in unsupportedKeys {
            let pattern = #"(?m)(^|[,{])\s*[\"']?"# + NSRegularExpression.escapedPattern(for: key) + #"[\"']?\s*[:=]"#
            if text.range(of: pattern, options: .regularExpression) != nil {
                throw RunnerError.hostCommandFailed(
                    "Unsupported create-config key '\(key)'. Regenerate the config with `pomme config init`."
                )
            }
        }
    }

    private static func evaluatePkl(at url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pkl", "eval", "--format", "json", url.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw RunnerError.hostCommandFailed("Pkl configs require the pkl executable in PATH.")
        }
        process.waitUntilExit()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 127 {
                throw RunnerError.hostCommandFailed("Pkl configs require the pkl executable in PATH.")
            }
            throw RunnerError.hostCommandFailed(detail.isEmpty ? "Pkl evaluation failed." : detail)
        }
        return output
    }

    private static func pklStarter(_ config: VMCreationConfigV1) -> String {
        let versions = config.versions.map { "  \"\($0)\"" }.joined(separator: ",\n")
        return """
        schemaVersion = \(config.schemaVersion)
        name = "\(config.name)"
        versions = List(
        \(versions)
        )
        boot = "\((config.boot ?? .none).rawValue)"
        hardware {
          diskSize = "\(config.hardware?.diskSize ?? "60GB")"
          memory = "\(config.hardware?.memory ?? "8GB")"
        }
        \n
        """
    }
}

/// Resolves and executes version-driven create configs.
enum CreateConfigRunner {
    /// Resolves the exact firmware and generated VM name for every requested version.
    static func plans(path: String) async throws -> [VMCreationPlan] {
        let config = try CreateConfigStore.load(path: path)
        return try await VMCreationPlanner(dependencies: .live).plans(for: config)
    }

    /// Executes a config batch sequentially or with bounded concurrency.
    static func run(path: String, dryRun: Bool, parallelism: Int) async throws -> [PommeOperationResult] {
        let plans = try await plans(path: path)
        return try await VMCreationExecutor(dependencies: .live).execute(
            plans,
            dryRun: dryRun,
            parallelism: parallelism
        )
    }
}

struct VMCreationPlanningDependencies: Sendable {
    let firmwareLookup: @Sendable (String, String?) async throws -> IPSWMEFirmware
    let profileSelection: @Sendable (IPSWMEFirmware) throws -> PommeCreateRecoveryProfileDescriptor
    let managedVMCollision: @Sendable (String) throws -> Bool

    static let live = VMCreationPlanningDependencies(
        firmwareLookup: { selector, device in
            try await PommeCore.resolveIPSWFirmware(selection: selector, deviceIdentifier: device)
        },
        profileSelection: PommeRecoveryProfileSelector.select,
        managedVMCollision: { name in
            FileManager.default.fileExists(atPath: try namedBundleURL(for: name).path)
        }
    )
}

struct VMCreationPlanner: Sendable {
    let dependencies: VMCreationPlanningDependencies

    func plans(for config: VMCreationConfigV1) async throws -> [VMCreationPlan] {
        var plans: [VMCreationPlan] = []
        for selector in config.versions {
            let firmware = try await dependencies.firmwareLookup(selector, config.ipswDevice)
            let recoveryProfile = try dependencies.profileSelection(firmware)
            let name = try validateIdentifier("\(config.name)-\(firmware.version)", kind: .configDerived)
            plans.append(.init(
                name: name,
                selector: selector,
                firmware: firmware,
                config: config,
                recoveryProfile: recoveryProfile
            ))
        }

        let names = plans.map(\.name)
        guard Set(names).count == names.count else {
            throw RunnerError.hostCommandFailed("Multiple version selectors resolve to the same VM name.")
        }
        let collisions = try names.filter(dependencies.managedVMCollision)
        guard collisions.isEmpty else {
            throw RunnerError.hostCommandFailed(
                "Managed VM names already exist: \(collisions.joined(separator: ", ")). No VMs were created."
            )
        }
        PommeCore.log("VM creation planner resolved \(plans.count) VM(s): \(names.joined(separator: ", "))")
        return plans
    }
}

struct VMCreationExecutionDependencies: Sendable {
    let install: @Sendable (VMCreationPlan) async throws -> PommeOperationResult
    /// Checks a plan without installing it and returns payload fields for the
    /// dry-run result. It throws for a plan the real create would refuse.
    let dryRunPreflight: @Sendable (VMCreationPlan) async throws -> [String: Any]

    init(
        install: @escaping @Sendable (VMCreationPlan) async throws -> PommeOperationResult,
        dryRunPreflight: @escaping @Sendable (VMCreationPlan) async throws -> [String: Any] = { _ in [:] }
    ) {
        self.install = install
        self.dryRunPreflight = dryRunPreflight
    }

    static let live = VMCreationExecutionDependencies(
        install: PommeApplication.configuredCreate,
        dryRunPreflight: { plan in
            let memory = plan.config.hardware?.memory ?? "8GB"
            let check = try await PommeCore.dryRunMemoryCheck(
                memoryBytes: ByteSizeParser.parse(memory) ?? 0,
                source: .firmware(plan.firmware),
                vmName: plan.name
            )
            return ["memoryMinimum": check.payload]
        }
    )
}

struct VMCreationExecutor: Sendable {
    /// Virtualization runs at most two macOS guests at once; a third install
    /// would fail after the first two had already started.
    static let maximumParallelism = 2

    let dependencies: VMCreationExecutionDependencies

    func execute(
        _ plans: [VMCreationPlan],
        dryRun: Bool,
        parallelism: Int
    ) async throws -> [PommeOperationResult] {
        guard (1...Self.maximumParallelism).contains(parallelism) else {
            throw RunnerError.hostCommandFailed("Parallel creation runs at most \(Self.maximumParallelism) VMs at once.")
        }
        if dryRun {
            var results: [PommeOperationResult] = []
            for plan in plans { results.append(await dryRunResult(plan)) }
            return results
        }
        if parallelism == 1 {
            var results: [PommeOperationResult] = []
            for plan in plans { results.append(await install(plan)) }
            return results
        }

        return await withTaskGroup(of: (Int, PommeOperationResult).self) { group in
            var nextIndex = 0
            var results: [(Int, PommeOperationResult)] = []
            func submitNext() {
                guard nextIndex < plans.count else { return }
                let index = nextIndex
                nextIndex += 1
                group.addTask { (index, await install(plans[index])) }
            }
            for _ in 0..<min(parallelism, plans.count) { submitNext() }
            while let result = await group.next() {
                results.append(result)
                submitNext()
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func install(_ plan: VMCreationPlan) async -> PommeOperationResult {
        do {
            return try await dependencies.install(plan)
        } catch {
            return PommeOperationResult(
                title: "Create VM",
                vmName: plan.name,
                ok: false,
                hostExitCode: 1,
                text: error.localizedDescription,
                payload: [
                    "ok": false,
                    "name": plan.name,
                    "version": plan.firmware.version,
                    "build": plan.firmware.buildid,
                    "hostExitCode": 1,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func dryRunResult(_ plan: VMCreationPlan) async -> PommeOperationResult {
        var payload = plan.payload
        payload["dryRun"] = true
        do {
            payload.merge(try await dependencies.dryRunPreflight(plan)) { _, new in new }
        } catch {
            payload["ok"] = false
            payload["hostExitCode"] = 1
            payload["error"] = error.localizedDescription
            return PommeOperationResult(
                title: "Create plan",
                vmName: plan.name,
                ok: false,
                hostExitCode: 1,
                text: error.localizedDescription,
                payload: payload
            )
        }
        payload["ok"] = true
        payload["hostExitCode"] = 0
        return PommeOperationResult(
            title: "Create plan",
            vmName: plan.name,
            ok: true,
            hostExitCode: 0,
            text: "Would create \(plan.name) from macOS \(plan.firmware.version) (\(plan.firmware.buildid)).",
            payload: payload
        )
    }
}
