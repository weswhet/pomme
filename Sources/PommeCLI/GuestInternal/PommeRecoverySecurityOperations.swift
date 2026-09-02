import CryptoKit
import Darwin
import Foundation

/// The guest-side Recovery security surface is deliberately smaller than the
/// normal agent command surface.  It is called only after PommeAgent has
/// authenticated a bounded Recovery session.
enum PommeGuestRecoverySecurityError: Error, LocalizedError, Equatable, Sendable {
    case recoveryRoleRequired
    case rootRequired
    case invalidOperation
    case invalidPayload
    case credentialRequired
    case commandFailed
    case verificationFailed
    case rollbackFailed
    case invalidSnapshot
    case invalidPolicy
    case invalidNVRAM
    case nvramMutationUnqualified
    case snapshotPending
    case promptRejected
    case timedOut
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .recoveryRoleRequired:
            "Recovery security operations require the Recovery agent role."
        case .rootRequired:
            "Recovery security operations require root."
        case .invalidOperation:
            "The Recovery security operation is not supported."
        case .invalidPayload:
            "The Recovery security request payload is invalid."
        case .credentialRequired:
            "The Recovery security operation requires an authorized account credential."
        case .commandFailed:
            "The Recovery security command failed."
        case .verificationFailed:
            "The Recovery security change could not be verified."
        case .rollbackFailed:
            "The Recovery security rollback could not be verified."
        case .invalidSnapshot:
            "The Recovery security snapshot is invalid."
        case .invalidPolicy:
            "The Recovery boot policy is invalid or cannot be restored exactly."
        case .invalidNVRAM:
            "The Recovery NVRAM state is invalid or cannot be restored exactly."
        case .nvramMutationUnqualified:
            "AMFI boot-argument mutation is unavailable until Recovery NVRAM write and readback are qualified."
        case .snapshotPending:
            "A previous Recovery security transition is unresolved."
        case .promptRejected:
            "The Recovery security command presented an unsupported prompt."
        case .timedOut:
            "The Recovery security command timed out."
        case .outputTooLarge:
            "The Recovery security command returned too much output."
        }
    }
}

struct PommeGuestSecurityCredentials: Sendable, Equatable {
    let username: String
    let password: String

    init(username: String, password: String) throws {
        guard !username.isEmpty,
              username.utf8.count <= 256,
              !username.contains("\0"),
              !password.isEmpty,
              password.utf8.count <= 64 * 1024,
              !password.contains("\0")
        else { throw PommeGuestRecoverySecurityError.credentialRequired }
        self.username = username
        self.password = password
    }
}

struct PommeGuestProcessCapture: Sendable, Equatable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Exact, owner-only persistence for the pre-mutation AMFI state.  Production
/// instances are rooted at the resolved target Data volume and carry the
/// selected APFS volume-group UUID, so Recovery's ephemeral root cannot become
/// the journal location for a later enable operation. The file contains no
/// credential material and is left in place when rollback cannot be proved.
struct PommeGuestAMFISnapshotStore: Sendable {
    static let snapshotRelativePath = "private/var/db/pomme/amfi-recovery.snapshot"

    let url: URL
    let dataRoot: URL?
    let volumeGroupUUID: UUID
    let expectedOwner: uid_t
    let expectedGroup: gid_t?

    init(
        url: URL,
        volumeGroupUUID: UUID,
        expectedOwner: uid_t = 0,
        expectedGroup: gid_t? = 0
    ) {
        self.url = url.standardizedFileURL
        self.dataRoot = nil
        self.volumeGroupUUID = volumeGroupUUID
        self.expectedOwner = expectedOwner
        self.expectedGroup = expectedGroup
    }

    init(
        dataRoot: URL,
        volumeGroupUUID: UUID,
        expectedOwner: uid_t = 0,
        expectedGroup: gid_t? = 0
    ) throws {
        let root = dataRoot.standardizedFileURL
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        self.url = root.appendingPathComponent(Self.snapshotRelativePath)
        self.dataRoot = root
        self.volumeGroupUUID = volumeGroupUUID
        self.expectedOwner = expectedOwner
        self.expectedGroup = expectedGroup
    }

    func isPresent() throws -> Bool {
        try validateDataRoot()
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
            return false
        }
        try validate(info, regular: true)
        return true
    }

    func save(_ snapshot: PommeAMFISecuritySnapshot) throws {
        try validateDataRoot()
        guard snapshot.isWellFormed else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        let parent = url.deletingLastPathComponent()
        try ensureDirectory(parent)

        var existing = stat()
        guard lstat(url.path, &existing) != 0, errno == ENOENT else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        guard data.count <= 1024 * 1024 else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }

        let temporary = parent.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString.lowercased())"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        var completed = false
        defer {
            _ = Darwin.close(descriptor)
            if !completed { _ = unlink(temporary.path) }
        }
        do {
            try writeAll(descriptor, data)
            guard fchmod(descriptor, mode_t(0o600)) == 0,
                  fchown(descriptor, expectedOwner, expectedGroup ?? getegid()) == 0,
                  fsync(descriptor) == 0,
                  rename(temporary.path, url.path) == 0
            else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
            try syncDirectory(parent)
            completed = true
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        var written = stat()
        guard lstat(url.path, &written) == 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        try validate(written, regular: true)
    }

    func load() throws -> PommeAMFISecuritySnapshot {
        try validateDataRoot()
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        try validate(info, regular: true)
        guard info.st_size > 0, info.st_size <= 1024 * 1024 else {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let snapshot = try JSONDecoder().decode(PommeAMFISecuritySnapshot.self, from: data)
            guard snapshot.isWellFormed else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
            return snapshot
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    func clear() throws {
        try validateDataRoot()
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
            return
        }
        try validate(info, regular: true)
        guard unlink(url.path) == 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func validateDataRoot() throws {
        guard let dataRoot else { return }
        var info = stat()
        guard lstat(dataRoot.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              dataRoot.path.hasPrefix("/"),
              dataRoot.path == dataRoot.resolvingSymlinksInPath().standardizedFileURL.path,
              url.path.hasPrefix(dataRoot.path.hasSuffix("/") ? dataRoot.path : dataRoot.path + "/")
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
    }

    private func ensureDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            guard lstat(directory.path, &info) == 0 else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == expectedOwner,
              info.st_mode & 0o077 == 0,
              expectedGroup.map({ info.st_gid == $0 }) ?? true
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
    }

    private func validate(_ info: stat, regular: Bool) throws {
        guard (!regular || (info.st_mode & S_IFMT) == S_IFREG),
              info.st_uid == expectedOwner,
              info.st_mode & 0o077 == 0,
              expectedGroup.map({ info.st_gid == $0 }) ?? true
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }
    }

    private func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw PommeGuestRecoverySecurityError.invalidSnapshot
                }
            }
        }
    }
}

/// Guest-side Recovery security dispatcher.  PommeAgent can call this value
/// directly from its Recovery branch; no normal-role caller is admitted.
struct PommeGuestRecoverySecurityOperations: Sendable {
    typealias ProcessRunner = @Sendable (_ executable: String, _ arguments: [String]) throws -> PommeGuestProcessCapture
    typealias SecretProcessRunner = @Sendable (_ executable: String, _ arguments: [String], _ credentials: PommeGuestSecurityCredentials) throws -> PommeGuestProcessCapture
    typealias DataRootResolver = @Sendable (_ expectedVolumeGroupUUID: UUID) throws -> URL

    private let process: ProcessRunner
    private let secretProcess: SecretProcessRunner
    private let effectiveUserID: @Sendable () -> uid_t
    private let snapshotStore: PommeGuestAMFISnapshotStore?
    private let dataRootResolver: DataRootResolver?
    private let nvramMutationVerified: @Sendable () -> Bool

    init(
        process: @escaping ProcessRunner = Self.runProcess,
        secretProcess: @escaping SecretProcessRunner = Self.runSecretProcess,
        effectiveUserID: @escaping @Sendable () -> uid_t = { geteuid() },
        snapshotStore: PommeGuestAMFISnapshotStore? = nil,
        dataRootResolver: DataRootResolver? = nil,
        nvramMutationVerified: @escaping @Sendable () -> Bool = { false }
    ) {
        self.process = process
        self.secretProcess = secretProcess
        self.effectiveUserID = effectiveUserID
        self.snapshotStore = snapshotStore
        self.dataRootResolver = dataRootResolver
        self.nvramMutationVerified = nvramMutationVerified
    }

    /// Execute exactly one of the six Recovery operations. Mutation payloads
    /// contain only an authorized username and password; neither is returned
    /// or interpolated into an error.
    func execute(role: PommeAgentRole, operation: String, payload: JSONValue) throws -> JSONValue {
        guard role == .recovery else { throw PommeGuestRecoverySecurityError.recoveryRoleRequired }
        guard effectiveUserID() == 0 else { throw PommeGuestRecoverySecurityError.rootRequired }
        guard let operation = Operation(rawValue: operation) else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }

        do {
            switch operation {
            case .sipStatus:
                try requireEmptyPayload(payload)
                return try sipStatusResult(operation: operation.rawValue)
            case .sipDisable:
                return try sipMutation(operation: operation, credentials: credentials(from: payload))
            case .sipEnable:
                return try sipMutation(operation: operation, credentials: credentials(from: payload))
            case .amfiStatus:
                try requireEmptyPayload(payload)
                return try amfiStatusResult(operation: operation.rawValue)
            case .amfiDisable:
                let request = try amfiRequest(from: payload)
                return try amfiDisable(expectedVolumeGroupUUID: request.volumeGroupUUID, credentials: request.credentials)
            case .amfiEnable:
                let request = try amfiRequest(from: payload)
                return try amfiEnable(expectedVolumeGroupUUID: request.volumeGroupUUID, credentials: request.credentials)
            }
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
    }

    private enum Operation: String {
        case sipStatus = "sip.status"
        case sipDisable = "sip.disable"
        case sipEnable = "sip.enable"
        case amfiStatus = "amfi.status"
        case amfiDisable = "amfi.disable"
        case amfiEnable = "amfi.enable"

        var mutationAction: String {
            switch self {
            case .sipDisable, .amfiDisable: "disable"
            case .sipEnable, .amfiEnable: "enable"
            case .sipStatus, .amfiStatus: "status"
            }
        }
    }

    private func requireEmptyPayload(_ payload: JSONValue) throws {
        guard let object = payload.objectValue, object.isEmpty else {
            throw PommeGuestRecoverySecurityError.invalidPayload
        }
    }

    private func credentials(from payload: JSONValue) throws -> PommeGuestSecurityCredentials {
        guard let object = payload.objectValue,
              Set(object.keys) == ["authorizedUser", "password"],
              let username = object["authorizedUser"]?.stringValue,
              let password = object["password"]?.stringValue
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        return try PommeGuestSecurityCredentials(username: username, password: password)
    }

    private func amfiRequest(from payload: JSONValue) throws -> (credentials: PommeGuestSecurityCredentials, volumeGroupUUID: UUID) {
        guard let object = payload.objectValue,
              Set(object.keys) == ["authorizedUser", "password", "volumeGroupUUID"],
              let rawUUID = object["volumeGroupUUID"]?.stringValue,
              let volumeGroupUUID = UUID(uuidString: rawUUID),
              volumeGroupUUID.uuidString.lowercased() == rawUUID
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        return try (credentials(from: .object([
            "authorizedUser": object["authorizedUser"] ?? .null,
            "password": object["password"] ?? .null
        ])), volumeGroupUUID)
    }

    private func sipStatus() throws -> Bool {
        let result = try process("/usr/bin/csrutil", ["status"])
        guard result.status == 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
        let text = String(decoding: result.stdout, as: UTF8.self)
        let matches = ["enabled", "disabled"].filter { state in
            text.range(of: #"(?i)\bstatus\s*:\s*\#(state)\b"#, options: .regularExpression) != nil
        }
        guard matches.count == 1 else { throw PommeGuestRecoverySecurityError.verificationFailed }
        return matches[0] == "enabled"
    }

    private func sipStatusResult(operation: String) throws -> JSONValue {
        let enabled = try sipStatus()
        return .object([
            "operation": .string(operation),
            "sipEnabled": .bool(enabled),
            "sipDisabled": .bool(!enabled),
            "verified": .bool(true)
        ])
    }

    private func sipMutation(operation: Operation, credentials: PommeGuestSecurityCredentials) throws -> JSONValue {
        let expectedEnabled = operation == .sipEnable
        let result = try secretProcess(
            "/usr/bin/csrutil",
            [operation.mutationAction],
            credentials
        )
        guard result.status == 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
        let observedEnabled = try sipStatus()
        guard observedEnabled == expectedEnabled else {
            throw PommeGuestRecoverySecurityError.verificationFailed
        }
        return .object([
            "operation": .string(operation.rawValue),
            "sipEnabled": .bool(observedEnabled),
            "sipDisabled": .bool(!observedEnabled),
            "verified": .bool(true)
        ])
    }

    private func amfiStatusResult(operation: String) throws -> JSONValue {
        let state = try captureAMFIState()
        let active = PommeBootArguments.containsOverride(state.snapshot.nvram.value(for: "boot-args")?.value)
        return .object([
            "operation": .string(operation),
            "amfiBootArgActive": .bool(active),
            "amfiDisabled": .bool(active && state.policy.allowsCustomBootArguments),
            "bootPolicyAllowsCustomBootArgs": .bool(state.policy.allowsCustomBootArguments),
            "securityMode": .string(state.policy.securityMode),
            "verified": .bool(true)
        ])
    }

    private func amfiDisable(
        expectedVolumeGroupUUID: UUID,
        credentials: PommeGuestSecurityCredentials
    ) throws -> JSONValue {
        guard nvramMutationVerified() else {
            throw PommeGuestRecoverySecurityError.nvramMutationUnqualified
        }
        let before = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        let snapshotStore = try snapshotStore(for: expectedVolumeGroupUUID)
        let pending = try snapshotStore.isPresent()
        guard !pending else {
            throw PommeGuestRecoverySecurityError.snapshotPending
        }
        try snapshotStore.save(before.snapshot)
        do {
            let authorization = try secretProcess(
                "/usr/bin/bputil",
                ["-a", "-v", before.policy.volumeGroupUUID],
                credentials
            )
            guard authorization.status == 0 else { throw PommeGuestRecoverySecurityError.commandFailed }

            let currentBoot = before.snapshot.nvram.value(for: "boot-args") ?? .absent
            let nextBoot = try PommeNVRAMDelta.bootArguments(
                present: true,
                value: PommeBootArguments.addingOverride(to: currentBoot.value)
            )
            try applyNVRAM(nextBoot)
            let after = try captureAMFIState()
            guard after.policy.matchesDisabledTarget(of: before.policy),
                  after.snapshot.nvram == nextBoot
            else { throw PommeGuestRecoverySecurityError.verificationFailed }

            let active = PommeBootArguments.containsOverride(nextBoot.value(for: "boot-args")?.value)
            return .object([
                "operation": .string(Operation.amfiDisable.rawValue),
                "amfiBootArgActive": .bool(active),
                "amfiDisabled": .bool(active && after.policy.allowsCustomBootArguments),
                "bootPolicyAllowsCustomBootArgs": .bool(after.policy.allowsCustomBootArguments),
                "verified": .bool(true)
            ])
        } catch let error as PommeGuestRecoverySecurityError {
            do {
                try rollbackAMFI(to: before, credentials: credentials)
                try snapshotStore.clear()
            } catch {
                throw PommeGuestRecoverySecurityError.rollbackFailed
            }
            throw error
        } catch {
            do {
                try rollbackAMFI(to: before, credentials: credentials)
                try snapshotStore.clear()
            } catch {
                throw PommeGuestRecoverySecurityError.rollbackFailed
            }
            throw PommeGuestRecoverySecurityError.commandFailed
        }
    }

    private func amfiEnable(
        expectedVolumeGroupUUID: UUID,
        credentials: PommeGuestSecurityCredentials
    ) throws -> JSONValue {
        guard nvramMutationVerified() else {
            throw PommeGuestRecoverySecurityError.nvramMutationUnqualified
        }
        let before = try captureAMFIState(expectedVolumeGroupUUID: expectedVolumeGroupUUID)
        let snapshotStore = try snapshotStore(for: expectedVolumeGroupUUID)
        let snapshot = try snapshotStore.load()
        let policy = try parsePolicy(snapshot.localPolicy, expectedVolumeGroupUUID: nil)
        guard before.policy.volumeGroupUUID == policy.volumeGroupUUID,
              policy.volumeGroupUUID == expectedVolumeGroupUUID.uuidString.lowercased(),
              before.policy.vuid == policy.vuid
        else { throw PommeGuestRecoverySecurityError.invalidSnapshot }

        do {
            let after = try restoreAMFI(snapshot: snapshot, policy: policy, credentials: credentials)
            try snapshotStore.clear()
            let active = PommeBootArguments.containsOverride(after.snapshot.nvram.value(for: "boot-args")?.value)
            return .object([
                "operation": .string(Operation.amfiEnable.rawValue),
                "amfiBootArgActive": .bool(active),
                "amfiDisabled": .bool(active && after.policy.allowsCustomBootArguments),
                "bootPolicyAllowsCustomBootArgs": .bool(after.policy.allowsCustomBootArguments),
                "verified": .bool(true)
            ])
        } catch let error as PommeGuestRecoverySecurityError {
            try rollbackAMFI(to: before, credentials: credentials)
            throw error
        } catch {
            try rollbackAMFI(to: before, credentials: credentials)
            throw PommeGuestRecoverySecurityError.commandFailed
        }
    }

    private func rollbackAMFI(
        to state: PommeGuestAMFIState,
        credentials: PommeGuestSecurityCredentials
    ) throws {
        do {
            _ = try restoreAMFI(snapshot: state.snapshot, policy: state.policy, credentials: credentials)
        } catch {
            throw PommeGuestRecoverySecurityError.rollbackFailed
        }
    }

    private func restoreAMFI(
        snapshot: PommeAMFISecuritySnapshot,
        policy: PommeGuestAMFIPolicy,
        credentials: PommeGuestSecurityCredentials
    ) throws -> PommeGuestAMFIState {
        let result = try secretProcess(
            "/usr/bin/bputil",
            policy.restoreArguments,
            credentials
        )
        guard result.status == 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
        try applyNVRAM(snapshot.nvram)
        let observed = try captureAMFIState()
        guard observed.snapshot.resourcesEqual(to: snapshot) else {
            throw PommeGuestRecoverySecurityError.verificationFailed
        }
        return observed
    }

    private func applyNVRAM(_ delta: PommeNVRAMDelta) throws {
        guard Set(delta.values.keys) == ["boot-args"],
              let value = delta.value(for: "boot-args")
        else { throw PommeGuestRecoverySecurityError.invalidNVRAM }
        let result: PommeGuestProcessCapture
        if value.present {
            result = try process("/usr/sbin/nvram", ["boot-args=\(value.value ?? "")"])
        } else {
            result = try process("/usr/sbin/nvram", ["-d", "boot-args"])
        }
        guard result.status == 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
    }

    private struct PommeGuestAMFIState: Sendable {
        let policy: PommeGuestAMFIPolicy
        let snapshot: PommeAMFISecuritySnapshot
    }

    private func captureAMFIState(expectedVolumeGroupUUID: UUID? = nil) throws -> PommeGuestAMFIState {
        let groupUUID = try currentVolumeGroupUUID()
        if let expectedVolumeGroupUUID,
           groupUUID != expectedVolumeGroupUUID.uuidString.lowercased() {
            throw PommeGuestRecoverySecurityError.invalidPolicy
        }
        let policy = try capturePolicy(groupUUID: groupUUID)
        let boot = try readBootArguments()
        let delta = try PommeNVRAMDelta.bootArguments(present: boot.present, value: boot.value)
        let snapshot = try PommeAMFISecuritySnapshot(
            localPolicy: policy.snapshotCanonical,
            nvram: delta
        )
        return .init(policy: policy, snapshot: snapshot)
    }

    private func snapshotStore(for volumeGroupUUID: UUID) throws -> PommeGuestAMFISnapshotStore {
        if let snapshotStore {
            guard snapshotStore.volumeGroupUUID == volumeGroupUUID else {
                throw PommeGuestRecoverySecurityError.invalidSnapshot
            }
            return snapshotStore
        }

        let root: URL
        do {
            if let dataRootResolver {
                root = try dataRootResolver(volumeGroupUUID)
            } else {
                let resolver = PommeRecoveryDataVolumeResolver { executable, arguments in
                    let result = try process(executable, arguments)
                    return (status: result.status, stdout: result.stdout)
                }
                root = try resolver.resolve(expectedVolumeGroupUUID: volumeGroupUUID)
            }
            return try PommeGuestAMFISnapshotStore(
                dataRoot: root,
                volumeGroupUUID: volumeGroupUUID
            )
        } catch let error as PommeGuestRecoverySecurityError {
            throw error
        } catch {
            throw PommeGuestRecoverySecurityError.invalidSnapshot
        }
    }

    private func currentVolumeGroupUUID() throws -> String {
        let result = try process("/usr/sbin/diskutil", ["apfs", "listVolumeGroups", "-plist"])
        guard result.status == 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
        do {
            let volume = try PommeRecoveryDataVolumeResolver.resolveDataVolume(
                from: result.stdout,
                expectedVolumeGroupUUID: nil
            )
            return volume.volumeGroupUUID.uuidString.lowercased()
        } catch {
            throw PommeGuestRecoverySecurityError.invalidPolicy
        }
    }

    private func readBootArguments() throws -> PommeNVRAMValue {
        let result = try process("/usr/sbin/nvram", ["boot-args"])
        guard result.status == 0 else {
            guard result.stdout.isEmpty else { throw PommeGuestRecoverySecurityError.invalidNVRAM }
            return .absent
        }
        let text = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PommeGuestRecoverySecurityError.invalidNVRAM }
        guard let separator = text.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            guard text == "boot-args" else { throw PommeGuestRecoverySecurityError.invalidNVRAM }
            return try .init(present: true, value: "")
        }
        guard String(text[..<separator]) == "boot-args" else {
            throw PommeGuestRecoverySecurityError.invalidNVRAM
        }
        let value = String(text[text.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try .init(present: true, value: value)
    }

    private func capturePolicy(groupUUID: String) throws -> PommeGuestAMFIPolicy {
        let targeted = try process(
            "/usr/bin/bputil",
            ["--json", "--display-policy", "-v", groupUUID]
        )
        do {
            return try parsePolicy(targeted.stdout, expectedVolumeGroupUUID: groupUUID)
        } catch {
            let all = try process(
                "/usr/bin/bputil",
                ["--json", "--display-all-policies"]
            )
            return try parsePolicy(all.stdout, expectedVolumeGroupUUID: groupUUID)
        }
    }

    private struct PommeGuestAMFIPolicy: Sendable, Equatable {
        let volumeGroupUUID: String
        let vuid: String
        let securityMode: String
        let allowsMDM: Bool
        let allowsKexts: Bool
        let kernelCTRRDisabled: Bool
        let allowsCustomBootArguments: Bool
        let ssvDisabled: Bool
        let canonical: Data

        /// PommeAMFISecuritySnapshot deliberately stores opaque LocalPolicy
        /// bytes. Include the selected volume-group identity in that opaque
        /// envelope so a later enable operation cannot guess its target.
        var snapshotCanonical: Data {
            guard let policy = try? JSONSerialization.jsonObject(with: canonical) else {
                return canonical
            }
            return (try? JSONSerialization.data(
                withJSONObject: ["volumeGroupUUID": volumeGroupUUID, "policy": policy],
                options: [.sortedKeys]
            )) ?? canonical
        }

        var restoreArguments: [String] {
            var arguments = [securityMode == "full" ? "-f" : securityMode == "reduced" ? "-g" : "-n", "-v", volumeGroupUUID]
            if allowsMDM { arguments.append("-m") }
            if allowsKexts { arguments.append("-k") }
            if kernelCTRRDisabled { arguments.append("-c") }
            if allowsCustomBootArguments { arguments.append("-a") }
            if ssvDisabled { arguments.append("-s") }
            return arguments
        }

        func matchesDisabledTarget(of original: Self) -> Bool {
            guard volumeGroupUUID == original.volumeGroupUUID,
                  vuid == original.vuid,
                  securityMode == "permissive",
                  allowsMDM == original.allowsMDM,
                  allowsKexts == original.allowsKexts,
                  kernelCTRRDisabled == original.kernelCTRRDisabled,
                  ssvDisabled == original.ssvDisabled,
                  allowsCustomBootArguments
            else { return false }
            return true
        }
    }

    private func parsePolicy(_ data: Data, expectedVolumeGroupUUID: String?) throws -> PommeGuestAMFIPolicy {
        guard data.count <= 512 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw PommeGuestRecoverySecurityError.invalidPolicy }

        if expectedVolumeGroupUUID == nil,
           Set(root.keys) == ["volumeGroupUUID", "policy"],
           let rawGroup = root["volumeGroupUUID"] as? String,
           let group = UUID(uuidString: rawGroup)?.uuidString.lowercased(),
           let wrappedPolicy = root["policy"] as? [String: Any],
           let (rootVUID, rawPolicy) = wrappedPolicy.first,
           wrappedPolicy.count == 1,
           let policy = rawPolicy as? [String: Any] {
            return try parsePolicyObject(
                root: wrappedPolicy,
                rootVUID: rootVUID,
                policy: policy,
                volumeGroupUUID: group
            )
        }

        guard root.count == 1,
              let (rootVUID, rawPolicy) = root.first,
              let policy = rawPolicy as? [String: Any],
              let expectedVolumeGroupUUID,
              let group = UUID(uuidString: expectedVolumeGroupUUID)?.uuidString.lowercased()
        else { throw PommeGuestRecoverySecurityError.invalidPolicy }
        return try parsePolicyObject(
            root: root,
            rootVUID: rootVUID,
            policy: policy,
            volumeGroupUUID: group
        )
    }

    private func parsePolicyObject(
        root: [String: Any],
        rootVUID: String,
        policy: [String: Any],
        volumeGroupUUID: String
    ) throws -> PommeGuestAMFIPolicy {
        guard let embedded = policy["vuid"] as? String,
              let vuid = UUID(uuidString: embedded)?.uuidString.lowercased(),
              UUID(uuidString: rootVUID)?.uuidString.lowercased() == vuid,
              let mode = policy["security_mode"] as? String,
              ["full", "reduced", "permissive"].contains(mode.lowercased()),
              let smb0 = Self.exactBool(policy["smb0"]),
              let smb1 = Self.exactBool(policy["smb1"]),
              let allowsKexts = Self.exactBool(policy["smb2"]),
              let allowsMDM = Self.exactBool(policy["smb3"]),
              let unmanagedMDM = Self.exactBool(policy["smb4"]),
              let ssvDisabled = Self.exactBool(policy["sip1"]),
              let kernelCTRRDisabled = Self.exactBool(policy["sip2"]),
              let allowsCustomBootArguments = Self.exactBool(policy["sip3"]),
              Self.requiredUnsignedInteger(policy["sip0"]) != nil
        else { throw PommeGuestRecoverySecurityError.invalidPolicy }

        let expectedMode: String
        switch (smb0, smb1) {
        case (false, false): expectedMode = "full"
        case (true, false): expectedMode = "reduced"
        case (true, true): expectedMode = "permissive"
        case (false, true): throw PommeGuestRecoverySecurityError.invalidPolicy
        }
        guard mode.lowercased() == expectedMode else {
            throw PommeGuestRecoverySecurityError.invalidPolicy
        }
        guard !unmanagedMDM else { throw PommeGuestRecoverySecurityError.invalidPolicy }
        if let smb5 = policy["smb5"] {
            guard Self.exactBool(smb5) == false else { throw PommeGuestRecoverySecurityError.invalidPolicy }
        }
        if let paired = policy["properly_paired"] {
            guard Self.exactBool(paired) == true else { throw PommeGuestRecoverySecurityError.invalidPolicy }
        }
        if let paired = policy["os_paired_to_current"] {
            guard Self.exactBool(paired) == true else { throw PommeGuestRecoverySecurityError.invalidPolicy }
        }
        if let osType = policy["os_type"] {
            guard (osType as? String)?.caseInsensitiveCompare("macOS") == .orderedSame else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        }

        switch expectedMode {
        case "full":
            guard !allowsMDM, !allowsKexts, !kernelCTRRDisabled,
                  !allowsCustomBootArguments, !ssvDisabled else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        case "reduced":
            guard !kernelCTRRDisabled, !allowsCustomBootArguments, !ssvDisabled else {
                throw PommeGuestRecoverySecurityError.invalidPolicy
            }
        default:
            break
        }
        guard let canonical = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        ) else { throw PommeGuestRecoverySecurityError.invalidPolicy }
        return .init(
            volumeGroupUUID: volumeGroupUUID,
            vuid: vuid,
            securityMode: expectedMode,
            allowsMDM: allowsMDM,
            allowsKexts: allowsKexts,
            kernelCTRRDisabled: kernelCTRRDisabled,
            allowsCustomBootArguments: allowsCustomBootArguments,
            ssvDisabled: ssvDisabled,
            canonical: canonical
        )
    }

    private static func exactBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func requiredUnsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { return nil }
        return UInt64(number.stringValue)
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> PommeGuestProcessCapture {
        guard executable.hasPrefix("/"),
              !executable.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") })
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [:]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        guard stdout.count <= 512 * 1024, stderr.count <= 512 * 1024 else {
            throw PommeGuestRecoverySecurityError.outputTooLarge
        }
        return .init(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func runSecretProcess(
        _ executable: String,
        _ arguments: [String],
        _ credentials: PommeGuestSecurityCredentials
    ) throws -> PommeGuestProcessCapture {
        if executable == "/usr/bin/csrutil" {
            return try PommeGuestSecurityPTY.runSIP(
                action: arguments == ["enable"] ? "enable" : "disable",
                credentials: credentials,
                timeout: 120
            )
        }
        guard executable == "/usr/bin/bputil" else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        return try PommeGuestSecurityPTY.runBputil(
            arguments: arguments,
            credentials: credentials,
            timeout: 120
        )
    }
}

private enum PommeGuestSecurityPTY {
    private static let maximumTranscriptBytes = 512 * 1024

    static func runSIP(
        action: String,
        credentials: PommeGuestSecurityCredentials,
        timeout: TimeInterval
    ) throws -> PommeGuestProcessCapture {
        guard action == "enable" || action == "disable" else {
            throw PommeGuestRecoverySecurityError.invalidOperation
        }
        var sentConfirmation = false
        var sentUsername = false
        var sentPassword = false
        return try run(
            executable: "/usr/bin/csrutil",
            arguments: [action],
            timeout: timeout
        ) { text, descriptor in
            if text.localizedCaseInsensitiveContains("pick a macOS installation") {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
            if !sentConfirmation,
               text.range(of: #"(?m)^\s*\[\s*[yY]\s*/\s*[nN]\s*\]\s*:?\s*$"#, options: .regularExpression) != nil {
                try write("Y\r", to: descriptor)
                sentConfirmation = true
            }
            if !sentUsername,
               text.range(of: #"(?im)^\s*(?:authorized\s+user|local\s+owner\s+username|owner\s+username|user\s+name|username)\s*:\s*$"#, options: .regularExpression) != nil {
                try write(credentials.username + "\r", to: descriptor)
                sentUsername = true
            }
            if !sentPassword,
               text.range(of: #"(?im)^\s*(?:enter\s+)?password(?:\s+for\s+user\s+[A-Za-z0-9_.-]+)?\s*:\s*$"#, options: .regularExpression) != nil {
                try write(credentials.password + "\r", to: descriptor)
                sentPassword = true
            }
        }
    }

    static func runBputil(
        arguments: [String],
        credentials: PommeGuestSecurityCredentials,
        timeout: TimeInterval
    ) throws -> PommeGuestProcessCapture {
        var responder = PommeGuestAMFIPromptResponder()
        let result = try run(
            executable: "/usr/bin/bputil",
            arguments: arguments,
            timeout: timeout
        ) { text, descriptor in
            if let input = try responder.nextInput(for: text, credentials: credentials) {
                try write(input + "\r", to: descriptor)
            }
        }
        guard responder.completed else {
            throw PommeGuestRecoverySecurityError.promptRejected
        }
        return result
    }

    private static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        handle: (String, Int32) throws -> Void
    ) throws -> PommeGuestProcessCapture {
        guard timeout.isFinite, timeout > 0,
              executable.hasPrefix("/"),
              arguments.allSatisfy({ !$0.contains("\0") })
        else { throw PommeGuestRecoverySecurityError.invalidPayload }
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            throw PommeGuestRecoverySecurityError.commandFailed
        }
        defer {
            if master >= 0 { _ = Darwin.close(master) }
            if slave >= 0 { _ = Darwin.close(slave) }
        }
        let child = pommeGuestFork()
        guard child >= 0 else { throw PommeGuestRecoverySecurityError.commandFailed }
        if child == 0 {
            _ = Darwin.close(master)
            _ = setsid()
            _ = ioctl(slave, TIOCSCTTY, 0)
            _ = dup2(slave, STDIN_FILENO)
            _ = dup2(slave, STDOUT_FILENO)
            _ = dup2(slave, STDERR_FILENO)
            if slave > STDERR_FILENO { _ = Darwin.close(slave) }
            let command = strdup(executable)
            var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
            argv.append(nil)
            _ = execv(command, &argv)
            _exit(127)
        }
        _ = Darwin.close(slave)
        slave = -1
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
            terminate(child, status: nil)
            throw PommeGuestRecoverySecurityError.commandFailed
        }
        var transcript = Data()
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < deadline {
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child { finished = true }
            drain(master, into: &transcript)
            guard transcript.count <= maximumTranscriptBytes else {
                terminate(child, status: &status)
                throw PommeGuestRecoverySecurityError.outputTooLarge
            }
            do {
                let text = String(decoding: transcript, as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: "\n")
                try handle(text, master)
            } catch {
                terminate(child, status: &status)
                throw error
            }
            if finished { break }
            usleep(50_000)
        }
        guard finished else {
            terminate(child, status: &status)
            throw PommeGuestRecoverySecurityError.timedOut
        }
        drain(master, into: &transcript)
        guard transcript.count <= maximumTranscriptBytes else {
            throw PommeGuestRecoverySecurityError.outputTooLarge
        }
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        transcript.resetBytes(in: 0..<transcript.count)
        return .init(status: exitCode)
    }

    private static func drain(_ descriptor: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private static func write(_ text: String, to descriptor: Int32) throws {
        let data = Data(text.utf8)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw PommeGuestRecoverySecurityError.commandFailed
                }
            }
        }
    }

    private static func terminate(_ child: pid_t, status: inout Int32?) {
        _ = kill(-child, SIGTERM)
        _ = kill(child, SIGTERM)
        for _ in 0..<20 {
            var observed: Int32 = 0
            if waitpid(child, &observed, WNOHANG) == child {
                status = observed
                return
            }
            usleep(100_000)
        }
        _ = kill(-child, SIGKILL)
        _ = kill(child, SIGKILL)
        var observed: Int32 = 0
        _ = waitpid(child, &observed, 0)
        status = observed
    }

    private static func terminate(_ child: pid_t, status: inout Int32) {
        var optional: Int32? = status
        terminate(child, status: &optional)
        if let optional { status = optional }
    }

    private static func terminate(_ child: pid_t, status: Int32?) {
        var optional = status
        terminate(child, status: &optional)
    }
}

private struct PommeGuestAMFIPromptResponder {
    private enum State { case username, password, complete }
    private var state: State = .username
    private var consumedUTF8Count = 0

    mutating func nextInput(
        for transcript: String,
        credentials: PommeGuestSecurityCredentials
    ) throws -> String? {
        guard transcript.utf8.count >= consumedUTF8Count else {
            throw PommeGuestRecoverySecurityError.promptRejected
        }
        let delta = String(decoding: transcript.utf8.dropFirst(consumedUTF8Count), as: UTF8.self)
        let normalized = delta.lowercased()
        if normalized.contains("unknown user")
            || normalized.contains("no admin users authorized for recovery")
            || normalized.contains("enter recovery key")
            || normalized.contains("authentication token") {
            throw PommeGuestRecoverySecurityError.promptRejected
        }
        switch state {
        case .username:
            if Self.usernamePrompt(delta) {
                consumedUTF8Count = transcript.utf8.count
                state = .password
                return credentials.username
            }
            if Self.passwordPrompt(delta) {
                consumedUTF8Count = transcript.utf8.count
                state = .complete
                return credentials.password
            }
        case .password:
            if Self.passwordPrompt(delta) {
                consumedUTF8Count = transcript.utf8.count
                state = .complete
                return credentials.password
            }
        case .complete:
            if Self.usernamePrompt(delta) || Self.passwordPrompt(delta) {
                throw PommeGuestRecoverySecurityError.promptRejected
            }
        }
        return nil
    }

    var completed: Bool {
        if case .complete = state { return true }
        return false
    }

    private static func usernamePrompt(_ text: String) -> Bool {
        text.range(
            of: #"(?im)^\s*(?:authorized\s+user|administrator\s+username|user\s*name|username)\s*:\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func passwordPrompt(_ text: String) -> Bool {
        text.range(
            of: #"(?im)^\s*(?:please\s+enter\s+)?password(?:\s+for\s+user\s+[A-Za-z0-9_.-]+)?\s*:\s*$"#,
            options: .regularExpression
        ) != nil
    }
}

@_silgen_name("fork")
private func pommeGuestFork() -> pid_t
