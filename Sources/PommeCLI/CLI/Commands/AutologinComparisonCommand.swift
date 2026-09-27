import ArgumentParser
import Foundation

/// A one-shot experiment, deliberately unavailable for arbitrary VM names.
enum PommeAutologinComparisonStrategy: String, ExpressibleByArgument, Sendable {
    case native, legacy, markerfirst, production, buddy

    var vmName: String {
        switch self {
        case .production: "pomme-agent-ownerflow26-20260927a"
        case .buddy: "pomme-agent-buddy26-20260927a"
        default: "pomme-agent-autologin-\(rawValue)26-20260927a"
        }
    }

    /// Production and Buddy arms use the normal owner preparation sequence.
    var ownerPreparationOverride: Self? { self == .production || self == .buddy ? nil : self }
}

struct AutologinComparisonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lab-autologin", abstract: "Run the scoped macOS 26 autologin comparison.",
        shouldDisplay: false)
    @Argument var name: String
    @Option var strategy: PommeAutologinComparisonStrategy
    @Flag(help: "Verify the retained marker-first desktop after guest-agent preference maintenance.")
    var verifyDesktop = false

    mutating func run() async throws {
        if verifyDesktop {
            try await PommeAutologinComparison.verifyMarkerDesktop(name: name, strategy: strategy)
        } else {
            try await PommeAutologinComparison.run(name: name, strategy: strategy)
        }
    }
}

enum PommeAutologinComparison {
    static let templateName = "pomme-agent-ownerloop-base26-20260922a"
    static let directoryName = "AutologinComparison-20260927"

    static func validateScope(name: String, strategy: PommeAutologinComparisonStrategy) throws {
        guard name == strategy.vmName else {
            throw RunnerError.hostCommandFailed("Autologin comparison refused: VM name does not match the selected experiment arm.")
        }
    }

    static func validateClone(
        version: String, build: String, input: PommeProvisioningInput,
        runtime: PommeProvisioningRuntimeMetadata,
        expectedTemplatePath: String, frameworkOwnerPresent: Bool
    ) throws -> UUID {
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else {
                throw RunnerError.hostCommandFailed("Autologin comparison refused: " + reason + ".")
            }
        }
        try require(version == "26.6.2", "restore version is not the expected macOS 26.6.2")
        try require(build == "25G83", "restore build is not the expected 25G83")
        try require(input.memorySizeBytes == 4 * 1024 * 1024 * 1024, "memory is not exactly 4 GiB")
        try require(input.diskSizeBytes == 40 * 1024 * 1024 * 1024, "disk is not exactly 40 GiB")
        try require(input.templateBundlePath == expectedTemplatePath, "source template path does not match the protected macOS 26 template")
        try require(!frameworkOwnerPresent, "a framework-provisioned owner is already present")
        guard let group = runtime.startupVolumeGroupUUID else {
            throw RunnerError.hostCommandFailed("Autologin comparison refused: runtime startup-volume-group identity is missing after completed creation.")
        }
        return group
    }

    static func run(name: String, strategy: PommeAutologinComparisonStrategy) async throws {
        try validateScope(name: name, strategy: strategy)
        try await VMBundleMutationLease.withLease(name: name) { lease in
            let reference = try PommeApplication.namedReference(name)
            let plan = try PommeCore.securityProvisioningPlan(reference: reference)
            let input = try PommeCore.loadProvisioningInput(for: plan)
            let template = try PommeTemplateStore.bundle(for: templateName)
            let runtime = try PommeCore.provisioningRuntimeMetadata(for: plan)
            let group = try validateClone(
                version: plan.restore.version, build: plan.restore.build,
                input: input, runtime: runtime, expectedTemplatePath: template.rootURL.path,
                frameworkOwnerPresent: try PommeCore.frameworkProvisionedOwner(reference: reference) != nil)
            let securityStore = PommeSecurityWorkflowJournalStore(bundleURL: reference.bundle.rootURL)
            guard try securityStore.loadIfPresent(lease: lease) == nil else {
                throw RunnerError.hostCommandFailed("Autologin comparison refused: an existing security workflow journal is present.")
            }
            let original = try PommeCore.stableVMRunState(reference: reference)
            guard original == .stopped else {
                throw RunnerError.hostCommandFailed("Autologin comparison refused: the fresh clone must be stopped before the experiment.")
            }
            let identity = try PommeSecurityWorkflowIdentity.capture(
                vmName: name, bundle: reference.bundle, startupVolumeGroupUUID: group,
                immutableProvisioningPlanDigest: plan.digest)
            let directory = reference.bundle.rootURL.appendingPathComponent(directoryName)
            // mkdir is exclusive: any retained attempt blocks reruns and strategy changes.
            guard mkdir(directory.path, 0o700) == 0 else {
                throw RunnerError.hostCommandFailed("Autologin comparison refused: the experiment directory already exists or cannot be created; retained attempts are never resumed automatically.")
            }
            let receipt: [String: String] = [
                "strategy": strategy.rawValue, "vm": name, "planDigest": plan.digest,
                "agentDigest": plan.normalAgent.executableDigest,
                "completion": strategy.ownerPreparationOverride == nil ? "production-owner-workflow"
                    : strategy == .markerfirst ? "markers-with-agent-preferences" : "shared-native",
                "failurePolicy": "preserve-no-retry"
            ]
            let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            try bytes.write(to: directory.appendingPathComponent("Experiment.json"), options: .atomic)
            // Reuse the owner-only phase machine in a separate lab directory. Never
            // invoke the security engine or create a production security journal.
            let store = PommeSecurityWorkflowJournalStore(bundleURL: directory)
            let journal = try store.begin(
                operation: .sipDisable, identity: identity, originalRunState: original,
                requestedFinalState: .normal, lease: lease)
            let progress = PommeSecurityWorkflowProgress(journal, store: store, lease: lease)
            let normal = PommeSecurityNormalAgent(
                reference: reference, expectedExecutableDigest: plan.normalAgent.executableDigest)
            let owner = PommeSecurityLiveOwnerPreparation(
                reference: reference, normal: normal, force: true, labStrategy: strategy.ownerPreparationOverride)
            let started = Date()
            if strategy.ownerPreparationOverride == nil {
                PommeCore.log("Production owner workflow harness: normal owner sequencing selected; isolated journal; no SIP or AMFI operation will run.", vmName: name)
            }
            PommeCore.log("Autologin comparison started: strategy=\(strategy.rawValue), retry=disabled, failureCleanup=disabled.", vmName: name)
            do {
                _ = try await owner.prepare(progress: progress)
                if strategy == .markerfirst {
                    let stage = try readMarkerStage(reference: reference)
                    guard stage.state == "owner-console-ready", stage.planDigest == plan.digest,
                          progress.journal.phase == .autologinIntent else {
                        throw RunnerError.hostCommandFailed("Marker-first lab failed: post-reboot console stage was not recorded.")
                    }
                    PommeCore.log("Marker-first lab stage passed: markers created, normal reboot authenticated, owner console verified. Guest-agent preference maintenance verified; run --verify-desktop for the full desktop proof.", vmName: name)
                    return
                }
                guard progress.journal.phase == .autologinVerified else {
                    throw RunnerError.hostCommandFailed("Autologin comparison failed: owner preparation returned without a fresh desktop proof.")
                }
                PommeCore.log("Autologin comparison passed: strategy=\(strategy.rawValue), elapsedSeconds=\(Int(Date().timeIntervalSince(started))), desktop=verified.", vmName: name)
            } catch {
                PommeCore.log("Autologin comparison failed: strategy=\(strategy.rawValue), phase=\(progress.journal.phase.rawValue), elapsedSeconds=\(Int(Date().timeIntervalSince(started))). VM and artifacts retained; no retry, restart, or cleanup follows this failure.", vmName: name)
                throw error
            }
        }
    }

    struct MarkerStage: Codable {
        let state: String
        let vm: String
        let planDigest: String
        let uniqueID: UInt32
    }

    static func markerStageURL(reference: VMReference) -> URL {
        reference.bundle.rootURL.appendingPathComponent(directoryName).appendingPathComponent("MarkerStage.json")
    }

    static func recordMarkerReady(
        reference: VMReference, progress: PommeSecurityWorkflowProgress, uniqueID: UInt32
    ) throws {
        let stage = MarkerStage(state: "owner-console-ready", vm: reference.displayName,
                                planDigest: progress.journal.identity.immutableProvisioningPlanDigest,
                                uniqueID: uniqueID)
        try JSONEncoder().encode(stage).write(to: markerStageURL(reference: reference), options: .withoutOverwriting)
    }

    static func readMarkerStage(reference: VMReference) throws -> MarkerStage {
        let url = markerStageURL(reference: reference)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0, info.st_size <= 4096 else {
            throw RunnerError.hostCommandFailed("Marker-first lab refused: stage receipt is absent or unsafe.")
        }
        return try JSONDecoder().decode(MarkerStage.self, from: Data(contentsOf: url))
    }

    static func ownerConsoleMatches(_ result: GuestCommandResult, username: String, uniqueID: UInt32) -> Bool {
        PommeSecurityNormalAgent.ownerConsoleMatches(result, username: username, uniqueID: uniqueID)
    }

    static func verifyOwnerConsole(normal: PommeSecurityNormalAgent, username: String, uniqueID: UInt32) async throws {
        try await normal.verifyOwnerConsole(username: username, uniqueID: uniqueID)
    }

    static func verifyMarkerDesktop(name: String, strategy: PommeAutologinComparisonStrategy) async throws {
        try validateScope(name: name, strategy: strategy)
        guard strategy == .markerfirst else {
            throw RunnerError.hostCommandFailed("Autologin comparison refused: --verify-desktop is only available for markerfirst.")
        }
        try await VMBundleMutationLease.withLease(name: name) { lease in
            let reference = try PommeApplication.namedReference(name)
            let plan = try PommeCore.securityProvisioningPlan(reference: reference)
            let input = try PommeCore.loadProvisioningInput(for: plan)
            let runtime = try PommeCore.provisioningRuntimeMetadata(for: plan)
            let template = try PommeTemplateStore.bundle(for: templateName)
            let group = try validateClone(version: plan.restore.version, build: plan.restore.build,
                input: input, runtime: runtime, expectedTemplatePath: template.rootURL.path,
                frameworkOwnerPresent: try PommeCore.frameworkProvisionedOwner(reference: reference) != nil)
            let currentIdentity = try PommeSecurityWorkflowIdentity.capture(
                vmName: name, bundle: reference.bundle, startupVolumeGroupUUID: group,
                immutableProvisioningPlanDigest: plan.digest)
            guard try PommeSecurityWorkflowJournalStore(bundleURL: reference.bundle.rootURL).loadIfPresent(lease: lease) == nil else {
                throw RunnerError.hostCommandFailed("Marker-first lab refused: a production security journal is present.")
            }
            let stage = try readMarkerStage(reference: reference)
            guard stage.state == "owner-console-ready", stage.vm == name, stage.planDigest == plan.digest,
                  stage.uniqueID >= 501,
                  try PommeCore.stableVMRunState(reference: reference) == .running(.normal) else {
                throw RunnerError.hostCommandFailed("Marker-first lab refused: a matching completed console stage and current normal boot are required.")
            }
            let directory = reference.bundle.rootURL.appendingPathComponent(directoryName)
            let store = PommeSecurityWorkflowJournalStore(bundleURL: directory)
            guard let journal = try store.loadIfPresent(lease: lease), journal.phase == .autologinIntent,
                  journal.identity.matches(currentIdentity),
                  journal.owner?.accountUsername == "pomme" else {
                throw RunnerError.hostCommandFailed("Marker-first lab refused: owner journal does not match the retained console stage.")
            }
            // An attempted verification is never silently repeated after failure.
            try Data("desktop-verification-intent".utf8).write(
                to: directory.appendingPathComponent("DesktopVerificationIntent"), options: .withoutOverwriting)
            let normal = PommeSecurityNormalAgent(reference: reference, expectedExecutableDigest: plan.normalAgent.executableDigest)
            do {
                try await normal.authenticate()
                for (domain, key, expected) in [
                    ("com.apple.SetupAssistant", "LastSeenBuddyBuildVersion", plan.restore.build),
                    ("com.apple.loginwindow", "MiniBuddyLaunch", "0")
                ] {
                    let result = try normal.execute(.init(path: "/usr/bin/sudo",
                        arguments: ["-H", "-u", "pomme", "/usr/bin/defaults", "read", domain, key], timeout: 15))
                    guard result.exited, !result.timedOut, result.exitCode == 0, result.signal == nil,
                          !result.stdoutTruncated, !result.stderrTruncated, result.stderr.isEmpty,
                          String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
                        throw RunnerError.hostCommandFailed("Marker-first lab failed: post-reboot CFPreferences readback did not verify \(key). No preferences were written by verification.")
                    }
                    PommeCore.log("Marker-first lab: post-reboot preference readback verified key=\(key).", vmName: name)
                }
                try await normal.verifyConsoleLogin(username: "pomme", uniqueID: stage.uniqueID)
                let progress = PommeSecurityWorkflowProgress(journal, store: store, lease: lease)
                try progress.advance(.autologinVerified)
                let completed = MarkerStage(state: "desktop-verified", vm: name, planDigest: plan.digest, uniqueID: stage.uniqueID)
                try JSONEncoder().encode(completed).write(to: markerStageURL(reference: reference), options: .atomic)
                PommeCore.log("Marker-first lab passed: post-reboot preferences and full desktop verified.", vmName: name)
            } catch {
                PommeCore.log("Marker-first lab desktop verification failed; VM and stage retained without reboot, retry, or cleanup.", vmName: name)
                throw error
            }
        }
    }

    /// Only the encoded artifact traverses authenticated stdin. It is still a
    /// credential and must never enter argv, environment, output, or logs.
    static func legacyRequest(password: String) -> GuestCommandRequest {
        .init(path: "/bin/sh", arguments: ["-c", legacyScript], timeout: 30,
              inputData: kcpasswordData(for: password))
    }

    static func setLegacy(reference: VMReference, password: String) throws {
        let request = legacyRequest(password: password)
        PommeCore.log("Autologin comparison legacy setter: atomic loginwindow and credential writes started.", vmName: reference.displayName)
        let result: GuestCommandResult
        do {
            let response = try PommeCore.sendForegroundControlObject(
                try request.validatedControlPayload(), bundle: reference.bundle, timeout: 45)
            result = try PommeSecurityNormalAgent.decodeCompletedCommand(response)
        } catch {
            throw RunnerError.hostCommandFailed("Autologin comparison legacy setter failed: authenticated execution or response verification failed; artifacts retained.")
        }
        guard result.exited, result.exitCode == 0, result.signal == nil, !result.timedOut,
              !result.stdoutTruncated, !result.stderrTruncated,
              result.stdout.isEmpty, result.stderr.isEmpty else {
            throw RunnerError.hostCommandFailed("Autologin comparison legacy setter failed: exit=\(result.exitCode.map(String.init) ?? "missing"); stdoutPresent=\(!result.stdout.isEmpty), stderrPresent=\(!result.stderr.isEmpty). Stages: 71=root, 72=unsafe target, 73=staging, 74=credential write, 75=plist read, 76=plist update, 77=metadata, 78=commit, 79=readback. Artifacts retained.")
        }
        PommeCore.log("Autologin comparison legacy setter: committed both artifacts; shared native readback follows.", vmName: reference.displayName)
    }

    static let legacyScript = #"""
    [ "$(/usr/bin/id -u)" = 0 ] || exit 71
    umask 077
    login=/Library/Preferences/com.apple.loginwindow.plist
    kc=/etc/kcpassword
    [ ! -L "$login" ] && [ ! -L "$kc" ] || exit 72
    [ ! -e "$login" ] || [ -f "$login" ] || exit 72
    [ ! -e "$kc" ] || [ -f "$kc" ] || exit 72
    ls=$(/usr/bin/mktemp /Library/Preferences/.pomme-autologin.XXXXXXXX) || exit 73
    ks=$(/usr/bin/mktemp /etc/.pomme-kcpassword.XXXXXXXX) || exit 73
    /bin/cat > "$ks" || exit 74
    [ -s "$ks" ] || exit 74
    if [ -e "$login" ]; then
      /bin/cp "$login" "$ls" || exit 75
    else
      /usr/bin/plutil -create binary1 "$ls" || exit 75
    fi
    /usr/bin/plutil -replace autoLoginUser -string pomme "$ls" 2>/dev/null || /usr/bin/plutil -insert autoLoginUser -string pomme "$ls" 2>/dev/null || exit 76
    /usr/bin/plutil -convert binary1 "$ls" || exit 76
    /usr/sbin/chown 0:0 "$ls" "$ks" && /bin/chmod 644 "$ls" && /bin/chmod 600 "$ks" || exit 77
    /bin/mv -f "$ls" "$login" && /bin/mv -f "$ks" "$kc" || exit 78
    [ "$(/usr/bin/plutil -extract autoLoginUser raw "$login")" = pomme ] || exit 79
    [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$login")" = '0:0:644' ] || exit 79
    [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$kc")" = '0:0:600' ] || exit 79
    """#
}
