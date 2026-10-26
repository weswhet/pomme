import CryptoKit
import Darwin
import Foundation
import os

/// The caller must hold the VM mutation lease and keep the VM stopped until
/// this operation returns a completed receipt. No credentials are created here.
enum PommeExperimentalRecoveryImage {
    struct Artifacts: Sendable {
        let executableURL: URL
        /// Staged only while preparation embeds it. The request's credential
        /// digest binds the receipt afterwards.
        let tokenURL: URL
        let autostartURL: URL
        let launchdPlistURL: URL
    }
    struct Request: Sendable {
        let diskURL: URL
        let workspaceURL: URL
        let vmID: UUID
        let sessionID: UUID
        let artifacts: Artifacts
        let executableSHA256: String
        /// Required to start preparation. Boot selection and admission omit it,
        /// so a locked Keychain doesn't block a boot; the host authenticates
        /// the resident with the Keychain credential when it connects.
        let credentialSHA256: String?
        let manifestSHA256: String
    }
    enum BackingMode: String, Codable, Sendable { case normal, recovery }
    struct Receipt: Codable, Equatable, Sendable {
        let vmID: UUID
        let sessionID: UUID
        let manifestSHA256: String
        let executableSHA256: String
        var relativeImagePath: String
        var originalSHA256: String
        var imageSHA256: String
        var completed: Bool
        var pendingAttachmentImages: [String]
        var activeBacking: BackingMode? = nil // Legacy completed receipts used Recovery.
        var desiredBacking: BackingMode? = nil
        /// The guest replaced its Recovery image, as a macOS update does.
        /// Neither recorded image belongs on the disk again, so normal boots
        /// need no selection and Recovery uses the standard route.
        var recoveryReplaced: Bool? = nil
    }
    struct Failure: LocalizedError, Sendable {
        let reason: String
        var pendingAttachmentImages: [String] = []
        var processTerminationUnconfirmed = false
        var errorDescription: String? {
            "Pomme couldn't prepare or select the experimental Recovery image: \(reason)."
                + (pendingAttachmentImages.isEmpty ? "" : " Image attachments remain unresolved; do not boot the VM.")
        }
    }
    struct Command: Sendable {
        let executable: String
        let arguments: [String]
        var timeout: TimeInterval = 600
    }
    struct CommandResult: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }
    typealias Executor = @Sendable (Command) async throws -> CommandResult
    private struct Journal: Codable {
        var receipt: Receipt
        let diskPath: String
        let diskDevice: UInt64
        let diskInode: UInt64
        let assetHashes: [String: String] // Private receipt only; includes credential hash.
        var companions: [String: String]
        var jobInode: UInt64?
        var unconfirmedCommand: Bool?
    }
    struct Volume: Equatable, Sendable {
        let device: String
        let roles: [String]
    }
    private static let plistRelative = "System/Library/LaunchDaemons/\(PommeExperimentalRecoveryPayload.jobLabel).plist"
    private static let payloadName = PommeExperimentalRecoveryPayload.embeddedDirectoryName
    private static let workFiles: Set<String> = ["receipt.json", "receipt.next", "original.dmg", "original.dmg.partial", "working.dmg", "working.shadow", "prepared.dmg", "prepared.dmg.partial", "recovery", "image", "verify"]

    static func prepare(_ request: Request, executor: @escaping Executor = execute) async throws -> Receipt {
        try await perform(request, executor: executor, mode: nil, preservingDisk: false)
    }

    /// Requires the caller's stopped-VM mutation lease. When the receipt
    /// already records `mode`, returns without attaching the disk. Otherwise
    /// it reconciles the actual backing bytes with durable intent and detaches
    /// before admitting boot. `preservingDisk` refuses any change to the disk,
    /// as a pending saved-state restore requires.
    static func activate(
        _ request: Request, mode: BackingMode, preservingDisk: Bool = false, executor: @escaping Executor = execute
    ) async throws -> Receipt {
        try await perform(request, executor: executor, mode: mode, preservingDisk: preservingDisk)
    }

    /// The private receipt, read without running a host command.
    static func receipt(_ request: Request) throws -> Receipt {
        try Transaction(request: request, executor: execute).journal.receipt
    }

    private static func perform(
        _ request: Request, executor: @escaping Executor, mode: BackingMode?, preservingDisk: Bool
    ) async throws -> Receipt {
        let operation = mode.map { "activate \($0.rawValue) backing" } ?? "prepare image"
        let vmID = request.vmID.uuidString.lowercased()
        PommeUnifiedLog.experimentalRecovery.notice(
            "image \(operation, privacy: .public) started: vmID=\(vmID, privacy: .public) preservingDisk=\(preservingDisk, privacy: .public) workspace=\(request.workspaceURL.path, privacy: .public)"
        )
        let transaction: Transaction
        do { transaction = try Transaction(request: request, executor: executor) }
        catch {
            PommeUnifiedLog.error(error, context: "experimental Recovery image transaction open", logger: PommeUnifiedLog.experimentalRecovery)
            throw error
        }
        do {
            let receipt: Receipt
            if let mode { receipt = try await transaction.activate(mode, preservingDisk: preservingDisk) }
            else { receipt = try await transaction.run() }
            PommeUnifiedLog.experimentalRecovery.notice("""
                image \(operation, privacy: .public) finished: vmID=\(vmID, privacy: .public) \
                completed=\(receipt.completed, privacy: .public) \
                activeBacking=\(receipt.activeBacking?.rawValue ?? "none", privacy: .public) \
                recoveryReplaced=\(receipt.recoveryReplaced ?? false, privacy: .public)
                """)
            return receipt
        }
        catch {
            PommeUnifiedLog.error(error, context: "experimental Recovery image \(operation)", logger: PommeUnifiedLog.experimentalRecovery)
            if transaction.commandTerminationUnconfirmed {
                PommeUnifiedLog.experimentalRecovery.error("image command termination is unconfirmed; skipping attachment cleanup")
                throw Failure(reason: "host image command termination is unconfirmed; attachment cleanup was not attempted",
                              pendingAttachmentImages: transaction.journal.receipt.pendingAttachmentImages,
                              processTerminationUnconfirmed: true)
            }
            // Cancellation must not cancel the detach attempt itself.
            let unresolved = await Task.detached { await transaction.detachAll() }.value
            if !unresolved.isEmpty {
                PommeUnifiedLog.experimentalRecovery.error(
                    "cleanup could not verify detachment of \(unresolved.count, privacy: .public) image(s): \(unresolved.joined(separator: ", "), privacy: .public)"
                )
            }
            if !unresolved.isEmpty { throw Failure(reason: "cleanup could not verify detachment", pendingAttachmentImages: unresolved) }
            throw error
        }
    }

    enum BackingState: Equatable { case original, prepared }
    static func backingState(current: String, original: String, prepared: String) throws -> BackingState {
        if !prepared.isEmpty, current == prepared { return .prepared }
        if current == original { return .original }
        throw Failure(reason: "backing image conflicts with receipt")
    }

    /// Read-only boot admission. Checks the completed receipt, asset binding,
    /// disk inode, and absence of host attachments. It does not mount or hash
    /// the guest disk, whose normal OS contents may have changed since preparation.
    static func validateCompleted(_ request: Request, expectedMode: BackingMode? = nil, executor: @escaping Executor = execute) async throws -> Receipt {
        let transaction = try Transaction(request: request, executor: executor)
        return try await transaction.validateCompleted(expectedMode: expectedMode)
    }

    /// Parses APFS physical-store linkage, not disk number proximity.
    static func volumes(apfs: Data, attachedDevices: Set<String>) throws -> [Volume] {
        let root = try dictionary(apfs)
        guard let containers = root["Containers"] as? [[String: Any]] else { throw Failure(reason: "APFS container response is malformed") }
        var result: [Volume] = []
        for container in containers {
            guard let stores = container["PhysicalStores"] as? [[String: Any]], !stores.isEmpty else { continue }
            let names = try stores.map { try device($0["DeviceIdentifier"] as? String) }
            guard names.allSatisfy({ attachedDevices.contains($0) }) else { continue }
            guard let entries = container["Volumes"] as? [[String: Any]] else { throw Failure(reason: "APFS volume response is malformed") }
            for entry in entries {
                result.append(Volume(device: try device(entry["DeviceIdentifier"] as? String), roles: entry["Roles"] as? [String] ?? []))
            }
        }
        guard !result.isEmpty else { throw Failure(reason: "no APFS volumes belong to the exact attached image") }
        return result
    }
    /// Apple silicon disks also contain iSC and fallback Recovery volumes.
    /// Select only the Recovery sibling of the unique installed System/Data
    /// container, while retaining exact physical-store ownership checks.
    static func installedRecovery(apfs: Data, attachedDevices: Set<String>) throws -> Volume {
        guard let containers = try dictionary(apfs)["Containers"] as? [[String: Any]] else {
            throw Failure(reason: "APFS container response is malformed")
        }
        var candidates: [Volume] = []
        for container in containers {
            guard let stores = container["PhysicalStores"] as? [[String: Any]], !stores.isEmpty else { continue }
            let names = try stores.map { try device($0["DeviceIdentifier"] as? String) }
            guard names.allSatisfy({ attachedDevices.contains($0) }) else { continue }
            guard let entries = container["Volumes"] as? [[String: Any]] else { throw Failure(reason: "APFS volume response is malformed") }
            let volumes = try entries.map { entry in
                Volume(device: try device(entry["DeviceIdentifier"] as? String), roles: entry["Roles"] as? [String] ?? [])
            }
            let systems = volumes.filter { $0.roles == ["System"] }
            let data = volumes.filter { $0.roles == ["Data"] }
            let recovery = volumes.filter { $0.roles == ["Recovery"] }
            if systems.count == 1, data.count == 1, recovery.count == 1 { candidates.append(recovery[0]) }
        }
        guard candidates.count == 1 else {
            throw Failure(reason: "expected one owned APFS container with exactly one System, Data, and Recovery volume; matched \(candidates.count)")
        }
        return candidates[0]
    }

    static func attachedDevices(_ data: Data) throws -> Set<String> {
        guard let entities = try dictionary(data)["system-entities"] as? [[String: Any]] else { throw Failure(reason: "attachment response is malformed") }
        let names = try entities.compactMap { entry -> String? in
            guard let value = entry["dev-entry"] as? String else { return nil }
            return try device(value)
        }
        guard !names.isEmpty else { throw Failure(reason: "attachment returned no devices") }
        return Set(names)
    }
    static func partitionDevice(_ entities: [[String: Any]]) throws -> String {
        let schemes = entities.filter {
            ["GUID_partition_scheme", "Apple_partition_scheme"].contains($0["content-hint"] as? String ?? "")
        }
        guard schemes.count == 1 else { throw Failure(reason: "attachment has no unique partition-scheme device") }
        let name = try device(schemes[0]["dev-entry"] as? String)
        guard name.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { throw Failure(reason: "partition scheme is not a whole device") }
        return name
    }

    static func select(_ volumes: [Volume], role: String?) throws -> Volume {
        let matches = volumes.filter { volume in
            if let role { return volume.roles == [role] }
            return volume.roles.isEmpty
        }
        guard matches.count == 1 else {
            let known: Set<String> = ["System", "Data", "Recovery", "Preboot", "VM", "Update", "None"]
            let actual = volumes.map { volume in
                let roles = volume.roles.map { known.contains($0) ? $0 : "unrecognized" }.joined(separator: ",")
                return "\(volume.device)=[\(roles)]"
            }.joined(separator: "; ")
            throw Failure(reason: "expected one APFS volume with role \(role ?? "NONE"), matched \(matches.count) of \(volumes.count): \(actual)")
        }
        return matches[0]
    }
    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw Failure(reason: "expected a property-list dictionary") }
        return value
    }
    private static func device(_ input: String?) throws -> String {
        guard let input else { throw Failure(reason: "missing device identity") }
        let name = input.hasPrefix("/dev/") ? String(input.dropFirst(5)) : input
        guard name.range(of: #"^disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil else { throw Failure(reason: "unsafe device identity") }
        return name
    }
    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Whether `url` names any file system object. Only a missing leaf is
    /// absence; every other lookup failure is reported.
    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure(reason: "cannot inspect \(url.lastPathComponent)") }
        return false
    }
    private static func checked(_ url: URL, directory: Bool = false, privateOwner: Bool = false) throws -> stat {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw Failure(reason: "invalid filesystem path") }
        var path = ""
        let parts = url.path.split(separator: "/")
        for (index, part) in parts.enumerated() {
            guard part != ".", part != ".." else { throw Failure(reason: "noncanonical filesystem path") }
            path += "/" + part
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw Failure(reason: "missing path or symlink") }
            if index < parts.count - 1 { guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure(reason: "non-directory path component") } }
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw Failure(reason: "unexpected filesystem object") }
        if privateOwner { guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure(reason: "workspace must be private and user-owned") } }
        return info
    }

    /// The caller has verified the backing target matches one of the receipt's
    /// two recognized images before allowing removal of an interrupted copy.
    static func copyVerified(_ source: URL, to destination: URL, expected: String, mode: Int) throws {
        let partial = URL(fileURLWithPath: destination.path + ".partial")
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try checked(destination)
            if try digest(destination) == expected {
                if FileManager.default.fileExists(atPath: partial.path) { _ = try checked(partial); try FileManager.default.removeItem(at: partial) }
                return
            }
            // Compatibility with a copy interrupted before atomic staging
            // existed. These are exact receipt-owned paths, never arbitrary files.
            try FileManager.default.removeItem(at: destination)
        }
        if FileManager.default.fileExists(atPath: partial.path) { _ = try checked(partial); try FileManager.default.removeItem(at: partial) }
        _ = try checked(source)
        guard !FileManager.default.fileExists(atPath: partial.path) else { throw Failure(reason: "partial copy unexpectedly exists") }
        try FileManager.default.copyItem(at: source, to: partial)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: partial.path)
        guard try digest(partial) == expected else { throw Failure(reason: "staged copy verification failed") }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.synchronize(); try handle.close()
        guard rename(partial.path, destination.path) == 0 else { throw Failure(reason: "verified copy rename failed") }
        let fd = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(reason: "cannot sync verified copy directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure(reason: "cannot sync verified copy") }
    }

    private final class Transaction: @unchecked Sendable {
        let request: Request
        let executor: Executor
        var journal: Journal
        var commandTerminationUnconfirmed = false
        let receiptURL: URL
        var workspace: URL { request.workspaceURL }
        func file(_ name: String) -> URL { workspace.appendingPathComponent(name) }

        init(request: Request, executor: @escaping Executor) throws {
            self.request = request
            self.executor = executor
            receiptURL = request.workspaceURL.appendingPathComponent("receipt.json")
            let disk = try checked(request.diskURL)
            guard disk.st_uid == getuid(), disk.st_nlink == 1 else { throw Failure(reason: "disk must be an owned, unaliased regular file") }
            _ = try checked(request.workspaceURL, directory: true, privateOwner: true)
            guard !request.diskURL.path.hasPrefix(request.workspaceURL.path + "/") else { throw Failure(reason: "workspace cannot contain the VM disk") }
            let isDigest = { (value: String) in value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }
            guard [request.executableSHA256, request.manifestSHA256].allSatisfy(isDigest),
                  request.credentialSHA256.map(isDigest) ?? true else { throw Failure(reason: "invalid pinned digest") }
            var assets: [String: String] = [:]
            for (name, url) in [("pomme", request.artifacts.executableURL), ("autostart.sh", request.artifacts.autostartURL), ("launchd.plist", request.artifacts.launchdPlistURL)] {
                _ = try checked(url)
                assets[name] = try digest(url)
            }
            guard assets["pomme"] == request.executableSHA256 else { throw Failure(reason: "pinned executable changed") }
            // The staged credential exists only until preparation completes;
            // afterwards Keychain holds the only host copy.
            var credentialDigest = request.credentialSHA256
            if try exists(request.artifacts.tokenURL) {
                let tokenInfo = try checked(request.artifacts.tokenURL, privateOwner: true)
                let staged = try digest(request.artifacts.tokenURL)
                guard tokenInfo.st_size > 0, tokenInfo.st_size <= 4096,
                      credentialDigest.map({ $0 == staged }) ?? true else {
                    throw Failure(reason: "invalid credential artifact")
                }
                credentialDigest = staged
            }
            let entries = try FileManager.default.contentsOfDirectory(atPath: request.workspaceURL.path)
            guard Set(entries).isSubset(of: workFiles) else { throw Failure(reason: "unexpected workspace entry") }
            for name in entries { _ = try checked(request.workspaceURL.appendingPathComponent(name), directory: ["recovery", "image", "verify"].contains(name)) }
            if entries.contains("receipt.json") {
                _ = try checked(receiptURL, privateOwner: true)
                journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: receiptURL))
                // Without a credential to compare, keep the receipt's binding.
                assets["agent.token"] = credentialDigest ?? journal.assetHashes["agent.token"]
                guard journal.diskPath == request.diskURL.path, journal.diskDevice == UInt64(disk.st_dev), journal.diskInode == UInt64(disk.st_ino), journal.assetHashes == assets,
                      journal.receipt.vmID == request.vmID, journal.receipt.sessionID == request.sessionID,
                      journal.receipt.manifestSHA256 == request.manifestSHA256,
                      journal.receipt.executableSHA256 == request.executableSHA256 else { throw Failure(reason: "retry does not match private receipt") }
                guard journal.unconfirmedCommand != true else {
                    throw Failure(reason: "prior image command termination remains unconfirmed; operator reconciliation is required",
                                  pendingAttachmentImages: journal.receipt.pendingAttachmentImages,
                                  processTerminationUnconfirmed: true)
                }
                let pending = journal.receipt.pendingAttachmentImages
                let permitted: Set<String> = [request.diskURL.path,
                    request.workspaceURL.appendingPathComponent("working.dmg").path,
                    request.workspaceURL.appendingPathComponent("prepared.dmg").path]
                guard Set(pending).count == pending.count, Set(pending).isSubset(of: permitted) else {
                    throw Failure(reason: "private receipt contains an unauthorized attachment intent")
                }
            } else {
                guard entries.isEmpty else { throw Failure(reason: "workspace has artifacts without a receipt") }
                guard let credentialDigest else { throw Failure(reason: "preparation requires the resident credential") }
                assets["agent.token"] = credentialDigest
                journal = Journal(receipt: Receipt(vmID: request.vmID, sessionID: request.sessionID, manifestSHA256: request.manifestSHA256, executableSHA256: request.executableSHA256, relativeImagePath: "", originalSHA256: "", imageSHA256: "", completed: false, pendingAttachmentImages: []), diskPath: request.diskURL.path, diskDevice: UInt64(disk.st_dev), diskInode: UInt64(disk.st_ino), assetHashes: assets, companions: [:], jobInode: nil, unconfirmedCommand: false)
            }
        }
        func save() throws {
            let data = try JSONEncoder().encode(journal)
            let next = file("receipt.next")
            if FileManager.default.fileExists(atPath: next.path) { _ = try checked(next, privateOwner: true); try FileManager.default.removeItem(at: next) }
            let fd = open(next.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure(reason: "cannot write private receipt") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            guard fsync(fd) == 0, rename(next.path, receiptURL.path) == 0 else { throw Failure(reason: "cannot commit private receipt") }
            let parent = open(workspace.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { throw Failure(reason: "cannot sync workspace") }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw Failure(reason: "cannot sync receipt directory") }
        }
        func command(_ executable: String, _ arguments: [String]) async throws -> Data {
            try Task.checkCancellation()
            let name = URL(fileURLWithPath: executable).lastPathComponent
            // Arguments are image paths, device identifiers, and fixed verbs.
            PommeUnifiedLog.process.debug(
                "run \(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public)"
            )
            let result: CommandResult
            do { result = try await executor(Command(executable: executable, arguments: arguments)) }
            catch let failure as Failure {
                PommeUnifiedLog.error(failure, context: "\(name) \(arguments.first ?? "")", logger: PommeUnifiedLog.process)
                if failure.processTerminationUnconfirmed {
                    commandTerminationUnconfirmed = true
                    journal.unconfirmedCommand = true
                    try save()
                }
                throw failure
            }
            guard result.status == 0 else {
                let stderr = PommeUnifiedLog.scrubbed(String(decoding: result.stderr.prefix(1024), as: UTF8.self))
                PommeUnifiedLog.process.error("""
                    \(executable, privacy: .public) \(arguments.joined(separator: " "), privacy: .public) \
                    exited with status \(result.status, privacy: .public): \(stderr, privacy: .public)
                    """)
                throw Failure(reason: "\(name) failed with status \(result.status)")
            }
            PommeUnifiedLog.process.debug("\(name, privacy: .public) \(arguments.first ?? "", privacy: .public) exited 0")
            return result.stdout
        }
        func attach(_ url: URL, readOnly: Bool, raw: Bool = false, shadow: URL? = nil) async throws -> Set<String> {
            // Never adopt an attachment created outside this transaction.
            let existing = try dictionary(await command("/usr/bin/hdiutil", ["info", "-plist"]))
            guard let images = existing["images"] as? [[String: Any]],
                  !images.contains(where: { ($0["image-path"] as? String) == url.path }) else {
                throw Failure(reason: "image is already attached outside the active operation", pendingAttachmentImages: [url.path])
            }
            // Write intent before starting hdiutil, including an interrupted attach.
            if !journal.receipt.pendingAttachmentImages.contains(url.path) {
                journal.receipt.pendingAttachmentImages.append(url.path)
                try save()
            }
            var args = ["attach", readOnly ? "-readonly" : "-readwrite", "-nomount", "-plist"]
            if raw { args += ["-imagekey", "diskimage-class=CRawDiskImage"] }
            if let shadow { args += ["-shadow", shadow.path] }
            args.append(url.path)
            let devices = try attachedDevices(await command("/usr/bin/hdiutil", args))
            PommeUnifiedLog.experimentalRecovery.info("""
                attached \(url.path, privacy: .public) readOnly=\(readOnly, privacy: .public) raw=\(raw, privacy: .public) \
                shadow=\(shadow != nil, privacy: .public) devices=\(devices.sorted().joined(separator: ","), privacy: .public)
                """)
            return devices
        }
        func apfs(_ devices: Set<String>) async throws -> [Volume] {
            try volumes(apfs: await command("/usr/sbin/diskutil", ["apfs", "list", "-plist"]), attachedDevices: devices)
        }
        func installedRecovery(_ devices: Set<String>) async throws -> Volume {
            try PommeExperimentalRecoveryImage.installedRecovery(
                apfs: await command("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
                attachedDevices: devices
            )
        }
        func mount(_ volume: Volume, name: String, readOnly: Bool) async throws -> URL {
            let mount = file(name)
            if !FileManager.default.fileExists(atPath: mount.path) { try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            _ = try checked(mount, directory: true, privateOwner: true)
            guard try FileManager.default.contentsOfDirectory(atPath: mount.path).isEmpty else { throw Failure(reason: "mountpoint is not empty") }
            var args = ["mount"]
            if readOnly { args.append("readOnly") }
            // Keeps the guest volume out of Finder and Spotlight indexing.
            args += ["nobrowse", "-mountPoint", mount.path, "/dev/" + volume.device]
            _ = try await command("/usr/sbin/diskutil", args)
            let info = try dictionary(await command("/usr/sbin/diskutil", ["info", "-plist", "/dev/" + volume.device]))
            guard info["DeviceIdentifier"] as? String == volume.device, info["MountPoint"] as? String == mount.path else { throw Failure(reason: "mounted volume identity does not match") }
            PommeUnifiedLog.experimentalRecovery.info(
                "mounted /dev/\(volume.device, privacy: .public) at \(mount.path, privacy: .public) readOnly=\(readOnly, privacy: .public)"
            )
            return mount
        }
        func detachAll() async -> [String] {
            if commandTerminationUnconfirmed { return journal.receipt.pendingAttachmentImages }
            var unresolved: [String] = []
            for image in journal.receipt.pendingAttachmentImages.reversed() {
                do {
                    let info = try dictionary(await command("/usr/bin/hdiutil", ["info", "-plist"]))
                    guard let images = info["images"] as? [[String: Any]] else { throw Failure(reason: "cannot enumerate attachments") }
                    let matches = images.filter { ($0["image-path"] as? String) == image }
                    guard matches.count <= 1 else { throw Failure(reason: "ambiguous attachment ownership") }
                    if let match = matches.first {
                        guard let entities = match["system-entities"] as? [[String: Any]] else { throw Failure(reason: "attachment entities missing") }
                        let physical = try partitionDevice(entities)
                        // hdiutil detaches the complete image graph, including mounted APFS children.
                        _ = try await command("/usr/bin/hdiutil", ["detach", "/dev/" + physical])
                    }
                    let after = try dictionary(await command("/usr/bin/hdiutil", ["info", "-plist"]))
                    guard let remaining = after["images"] as? [[String: Any]], !remaining.contains(where: { ($0["image-path"] as? String) == image }) else { throw Failure(reason: "image remains attached") }
                    PommeUnifiedLog.experimentalRecovery.info("detached \(image, privacy: .public)")
                } catch {
                    PommeUnifiedLog.error(error, context: "detach \(image)", logger: PommeUnifiedLog.experimentalRecovery)
                    if commandTerminationUnconfirmed { return journal.receipt.pendingAttachmentImages }
                    unresolved.append(image)
                }
            }
            journal.receipt.pendingAttachmentImages = unresolved
            do { try save() } catch { return unresolved.isEmpty ? [request.diskURL.path] : unresolved }
            return unresolved
        }
        func detached() async throws {
            let unresolved = await detachAll()
            guard unresolved.isEmpty else { throw Failure(reason: "image detach failed", pendingAttachmentImages: unresolved) }
        }
        func locateImage(_ recovery: URL) throws -> URL {
            var matches: [URL] = []
            for name in try FileManager.default.contentsOfDirectory(atPath: recovery.path) where UUID(uuidString: name) != nil {
                let image = recovery.appendingPathComponent(name).appendingPathComponent("usr/standalone/firmware/arm64eBaseSystem.dmg")
                if FileManager.default.fileExists(atPath: image.path) { _ = try checked(image); matches.append(image) }
            }
            guard matches.count == 1 else { throw Failure(reason: "Recovery does not contain one uniquely identified BaseSystem image") }
            return matches[0]
        }
        func companionHashes(_ image: URL) throws -> [String: String] {
            let directory = image.deletingLastPathComponent()
            let adjacentName = ".pomme-experimental-" + request.vmID.uuidString.lowercased() + ".dmg"
            var hashes: [String: String] = [:]
            var count = 0
            func visit(_ parent: URL, prefix: String, depth: Int) throws {
                guard depth <= 8 else { throw Failure(reason: "companion tree exceeds bounded depth") }
                for name in try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() {
                    if prefix.isEmpty && [image.lastPathComponent, adjacentName, adjacentName + ".partial"].contains(name) { continue }
                    count += 1
                    guard count <= 4096 else { throw Failure(reason: "companion tree exceeds bounded entry count") }
                    let url = parent.appendingPathComponent(name), relative = prefix + name
                    var info = stat()
                    guard lstat(url.path, &info) == 0 else { throw Failure(reason: "missing companion entry") }
                    switch info.st_mode & S_IFMT {
                    case S_IFREG: hashes[relative] = try digest(url)
                    case S_IFDIR:
                        hashes[relative + "/"] = "directory"
                        try visit(url, prefix: relative + "/", depth: depth + 1)
                    default: throw Failure(reason: "unsafe companion entry type")
                    }
                }
            }
            try visit(directory, prefix: "", depth: 0)
            return hashes
        }
        func copyNew(_ source: URL, _ destination: URL, mode: Int) throws {
            _ = try checked(source)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure(reason: "refusing to replace workspace artifact") }
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
        }
        func validatePayload(_ root: URL) throws {
            let payload = root.appendingPathComponent(payloadName)
            _ = try checked(payload, directory: true)
            for (name, mode) in [("pomme", 0o555), ("agent.token", 0o400), ("autostart.sh", 0o500)] {
                let path = payload.appendingPathComponent(name)
                let info = try checked(path)
                guard info.st_mode & 0o777 == mode, try digest(path) == journal.assetHashes[name] else { throw Failure(reason: "prepared payload verification failed") }
            }
            let plist = root.appendingPathComponent(plistRelative)
            let plistInfo = try checked(plist)
            guard journal.jobInode == UInt64(plistInfo.st_ino), try digest(plist) == journal.assetHashes["launchd.plist"] else { throw Failure(reason: "prepared job verification failed") }
        }
        func embed(_ root: URL) throws {
            let plist = root.appendingPathComponent(plistRelative)
            let before = try checked(plist)
            let original = try dictionary(Data(contentsOf: plist))
            let proposed = try dictionary(Data(contentsOf: request.artifacts.launchdPlistURL))
            for key in ["Label", "_LimitLoadToBootMode", "EnablePressuredExit", "EnableTransactions"] {
                guard let old = original[key] as? NSObject, let new = proposed[key] as? NSObject, old == new else { throw Failure(reason: "existing Recovery job identity or filter differs") }
            }
            guard proposed["Label"] as? String == "com.apple.DumpPanicRecoveryOS" else { throw Failure(reason: "unsupported existing Recovery job") }
            let payload = root.appendingPathComponent(payloadName)
            guard !FileManager.default.fileExists(atPath: payload.path) else { throw Failure(reason: "payload directory already exists in source image") }
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (source, name, mode) in [(request.artifacts.executableURL, "pomme", 0o555), (request.artifacts.tokenURL, "agent.token", 0o400), (request.artifacts.autostartURL, "autostart.sh", 0o500)] {
                try copyNew(source, payload.appendingPathComponent(name), mode: mode)
            }
            // Preserve the existing inode: launchd did not discover a newly added label in the lab.
            let handle = try FileHandle(forWritingTo: plist)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(contentsOf: request.artifacts.launchdPlistURL))
            try handle.synchronize()
            guard try checked(plist).st_ino == before.st_ino else { throw Failure(reason: "existing job inode changed") }
            journal.jobInode = UInt64(before.st_ino)
            try save()
            try validatePayload(root)
        }
        func finish() throws -> Receipt {
            journal.receipt.activeBacking = .recovery
            journal.receipt.desiredBacking = nil
            journal.receipt.completed = true
            try save()
            PommeUnifiedLog.experimentalRecovery.notice("receipt committed: image preparation completed")
            // The verified original and private receipt remain available for
            // review/recovery. Delete only known disposable artifacts after detach.
            for name in ["working.dmg", "working.shadow"] where FileManager.default.fileExists(atPath: file(name).path) {
                _ = try checked(file(name))
                try FileManager.default.removeItem(at: file(name))
            }
            for name in ["recovery", "image", "verify"] where FileManager.default.fileExists(atPath: file(name).path) {
                _ = try checked(file(name), directory: true, privateOwner: true)
                guard try FileManager.default.contentsOfDirectory(atPath: file(name).path).isEmpty else { throw Failure(reason: "detached mountpoint contains unexpected files") }
                try FileManager.default.removeItem(at: file(name))
            }
            return journal.receipt
        }

        func validateCompleted(expectedMode: BackingMode? = nil) async throws -> Receipt {
            let receipt = journal.receipt
            guard receipt.completed, receipt.desiredBacking == nil, receipt.pendingAttachmentImages.isEmpty,
                  !receipt.relativeImagePath.isEmpty,
                  [receipt.originalSHA256, receipt.imageSHA256].allSatisfy({ $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }) else {
                throw Failure(reason: "Recovery image preparation is not complete", pendingAttachmentImages: receipt.pendingAttachmentImages)
            }
            // A replaced image has no backing to select. The caller uses the
            // standard Recovery route instead of the resident.
            if let expectedMode, receipt.recoveryReplaced != true, (receipt.activeBacking ?? .recovery) != expectedMode {
                throw Failure(reason: "Recovery backing is not activated for requested boot mode")
            }
            let info = try dictionary(await command("/usr/bin/hdiutil", ["info", "-plist"]))
            guard let images = info["images"] as? [[String: Any]] else { throw Failure(reason: "cannot verify attachment absence") }
            let attached = images.compactMap { $0["image-path"] as? String }.filter {
                $0 == request.diskURL.path || $0.hasPrefix(workspace.path + "/")
            }
            guard attached.isEmpty else { throw Failure(reason: "prepared image is still attached", pendingAttachmentImages: attached) }
            return receipt
        }

        func activate(_ mode: BackingMode, preservingDisk: Bool) async throws -> Receipt {
            guard journal.receipt.completed, !journal.receipt.relativeImagePath.isEmpty,
                  [journal.receipt.originalSHA256, journal.receipt.imageSHA256].allSatisfy({ $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }) else {
                throw Failure(reason: "image preparation must complete before activation")
            }
            // Neither a replaced image nor a completed selection needs host
            // access. Only a switch, or an interrupted one, attaches the disk:
            // a selection ends by clearing intent only after it verifies the
            // bytes and detaches, and nothing else installs the prepared image.
            if journal.receipt.recoveryReplaced == true { return journal.receipt }
            if journal.receipt.desiredBacking == nil, (journal.receipt.activeBacking ?? .recovery) == mode {
                return journal.receipt
            }
            guard !preservingDisk else {
                throw Failure(reason: "a saved VM state is waiting to be restored, and selecting the \(mode.rawValue) Recovery backing would change the disk under it. Start the VM in normal macOS and stop it, then restore the snapshot")
            }
            PommeUnifiedLog.experimentalRecovery.notice("""
                switching Recovery backing: from=\(self.journal.receipt.activeBacking?.rawValue ?? "recovery", privacy: .public) \
                to=\(mode.rawValue, privacy: .public) interrupted=\(self.journal.receipt.desiredBacking != nil, privacy: .public)
                """)
            journal.receipt.desiredBacking = mode
            try save() // Fence boot admission throughout activation, including failed verification.
            try await detached()
            let devices = try await attach(request.diskURL, readOnly: false, raw: true)
            let recovery = try await mount(await installedRecovery(devices), name: "recovery", readOnly: false)
            let image = recovery.appendingPathComponent(journal.receipt.relativeImagePath)
            guard try exists(image) else { return try await retire(image) }
            _ = try checked(image)
            let current = try digest(image)
            let companionsMatch = try companionHashes(image) == journal.companions
            let recognized = try? backingState(current: current, original: journal.receipt.originalSHA256, prepared: journal.receipt.imageSHA256)
            PommeUnifiedLog.experimentalRecovery.info("""
                current backing: state=\(recognized.map { "\($0)" } ?? "unrecognized", privacy: .public) \
                companionsMatch=\(companionsMatch, privacy: .public) sha256=\(current, privacy: .public)
                """)
            switch (recognized, companionsMatch) {
            case (.prepared?, false):
                throw Failure(reason: "Recovery image identity or companion files changed")
            case (nil, _), (.original?, false):
                // An update installs its own BaseSystem and companions.
                return try await retire(image)
            case (.prepared?, true), (.original?, true):
                break
            }
            let state = try backingState(current: current, original: journal.receipt.originalSHA256, prepared: journal.receipt.imageSHA256)
            let expected = mode == .normal ? journal.receipt.originalSHA256 : journal.receipt.imageSHA256
            // Old completed receipts deleted prepared.dmg. Recover it only from
            // backing bytes that independently match the recorded prepared hash.
            // A missing copy blocks only the switch that needs it as a source.
            for (name, retained, available) in [
                ("original.dmg", journal.receipt.originalSHA256, state == .original),
                ("prepared.dmg", journal.receipt.imageSHA256, state == .prepared)
            ] {
                if FileManager.default.fileExists(atPath: file(name).path) {
                    _ = try checked(file(name), privateOwner: true)
                    guard try digest(file(name)) == retained else { throw Failure(reason: "retained \(name) does not match receipt") }
                    let partial = file(name + ".partial")
                    if FileManager.default.fileExists(atPath: partial.path) {
                        _ = try checked(partial)
                        try FileManager.default.removeItem(at: partial)
                    }
                } else if available {
                    try copyVerified(image, to: file(name), expected: retained, mode: 0o600)
                } else if current != expected {
                    throw Failure(reason: "retained \(name) is missing; restore the verified matching backing before retrying activation")
                }
            }
            journal.receipt.desiredBacking = mode
            try save() // Intent survives a crash before or after the atomic rename.
            if current != expected {
                let source = file(mode == .normal ? "original.dmg" : "prepared.dmg")
                let adjacent = image.deletingLastPathComponent().appendingPathComponent(".pomme-experimental-" + request.vmID.uuidString.lowercased() + ".dmg")
                try copyVerified(source, to: adjacent, expected: expected, mode: Int(try checked(image).st_mode & 0o777))
                guard rename(adjacent.path, image.path) == 0 else { throw Failure(reason: "backing activation rename failed") }
                let fd = open(image.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard fd >= 0 else { throw Failure(reason: "cannot sync activated backing directory") }
                defer { close(fd) }
                guard fsync(fd) == 0 else { throw Failure(reason: "cannot sync activated backing") }
                PommeUnifiedLog.experimentalRecovery.notice("replaced BaseSystem with the \(mode.rawValue, privacy: .public) backing")
            }
            guard try digest(image) == expected, try companionHashes(image) == journal.companions else {
                throw Failure(reason: "activated backing verification failed")
            }
            PommeUnifiedLog.experimentalRecovery.info("verified activated \(mode.rawValue, privacy: .public) backing")
            // An interrupted copy may belong to a previous requested mode.
            // Remove only our exact staging names after verifying current bytes.
            try removeAdjacentStaging(beside: image)
            try await detached()
            journal.receipt.activeBacking = mode
            journal.receipt.desiredBacking = nil
            try save()
            return journal.receipt
        }

        func removeAdjacentStaging(beside image: URL) throws {
            let adjacentName = ".pomme-experimental-" + request.vmID.uuidString.lowercased() + ".dmg"
            for name in [adjacentName, adjacentName + ".partial"] {
                let temporary = image.deletingLastPathComponent().appendingPathComponent(name)
                var temporaryInfo = stat()
                if lstat(temporary.path, &temporaryInfo) == 0 {
                    _ = try checked(temporary)
                    try FileManager.default.removeItem(at: temporary)
                } else if errno != ENOENT {
                    throw Failure(reason: "cannot inspect adjacent staging artifact")
                }
            }
        }

        /// Records that the guest replaced its Recovery image. Neither
        /// retained copy can be selected again, and the prepared one embeds
        /// the resident credential, so both are removed before the record.
        func retire(_ image: URL) async throws -> Receipt {
            PommeUnifiedLog.experimentalRecovery.notice("guest replaced its Recovery image; retiring the prepared and original backings")
            try removeAdjacentStaging(beside: image)
            try await detached()
            for name in ["prepared.dmg", "prepared.dmg.partial", "original.dmg", "original.dmg.partial"] {
                guard try exists(file(name)) else { continue }
                _ = try checked(file(name))
                try FileManager.default.removeItem(at: file(name))
            }
            journal.receipt.recoveryReplaced = true
            journal.receipt.activeBacking = .normal
            journal.receipt.desiredBacking = nil
            try save()
            return journal.receipt
        }

        func run() async throws -> Receipt {
            if journal.receipt.completed { return try await activate(.recovery, preservingDisk: false) }
            PommeUnifiedLog.experimentalRecovery.notice("preparing image: resuming=\(!self.journal.receipt.relativeImagePath.isEmpty, privacy: .public)")
            try save()
            try await detached() // recover only attachment intents from this private receipt
            var devices = try await attach(request.diskURL, readOnly: false, raw: true)
            var recovery = try await mount(await installedRecovery(devices), name: "recovery", readOnly: false)
            var image = try locateImage(recovery)
            let relative = String(image.path.dropFirst(recovery.path.count + 1))
            let current = try digest(image)
            if journal.receipt.relativeImagePath.isEmpty {
                journal.receipt.relativeImagePath = relative
                journal.receipt.originalSHA256 = current
                journal.companions = try companionHashes(image)
                try save()
            }
            guard journal.receipt.relativeImagePath == relative, try companionHashes(image) == journal.companions else { throw Failure(reason: "Recovery image identity or companion files changed") }
            PommeUnifiedLog.experimentalRecovery.info("located BaseSystem \(relative, privacy: .public) sha256=\(current, privacy: .public)")
            if try backingState(current: current, original: journal.receipt.originalSHA256, prepared: journal.receipt.imageSHA256) == .prepared {
                try await detached()
                return try finish()
            }
            guard !journal.receipt.completed, current == journal.receipt.originalSHA256 else { throw Failure(reason: "backing image conflicts with receipt") }
            guard try exists(request.artifacts.tokenURL) else { throw Failure(reason: "the staged Recovery credential is missing") }
            try copyVerified(image, to: file("original.dmg"), expected: current, mode: 0o600)
            PommeUnifiedLog.experimentalRecovery.info("copied and verified original BaseSystem")
            try await detached()
            // A retry rebuilds only known scratch artifacts; the original remains intact.
            for name in ["working.dmg", "working.shadow", "prepared.dmg"] where FileManager.default.fileExists(atPath: file(name).path) {
                _ = try checked(file(name)); try FileManager.default.removeItem(at: file(name))
            }
            try copyNew(file("original.dmg"), file("working.dmg"), mode: 0o600)
            devices = try await attach(file("working.dmg"), readOnly: false, shadow: file("working.shadow"))
            let system = try select(await apfs(devices), role: "System")
            _ = try await command("/usr/sbin/diskutil", ["apfs", "changeVolumeRole", "/dev/" + system.device, "clear"])
            let cleared = try select(await apfs(devices), role: nil)
            guard cleared.device == system.device else { throw Failure(reason: "role change selected a different volume") }
            PommeUnifiedLog.experimentalRecovery.info("cleared System role on /dev/\(system.device, privacy: .public)")
            let root = try await mount(cleared, name: "image", readOnly: false)
            try embed(root)
            PommeUnifiedLog.experimentalRecovery.info("embedded the Recovery payload in the working image")
            try await detached()
            _ = try await command("/usr/bin/hdiutil", ["convert", file("working.dmg").path, "-shadow", file("working.shadow").path, "-format", "UDZO", "-o", file("prepared.dmg").path])
            devices = try await attach(file("prepared.dmg"), readOnly: true)
            let verifiedRoot = try await mount(select(await apfs(devices), role: nil), name: "verify", readOnly: true)
            try validatePayload(verifiedRoot)
            PommeUnifiedLog.experimentalRecovery.info("verified the payload in the converted prepared image")
            try await detached()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file("prepared.dmg").path)
            journal.receipt.imageSHA256 = try digest(file("prepared.dmg"))
            try save() // crash after rename can now be recognized by its exact hash
            PommeUnifiedLog.experimentalRecovery.info("recorded prepared image sha256=\(self.journal.receipt.imageSHA256, privacy: .public)")
            devices = try await attach(request.diskURL, readOnly: false, raw: true)
            recovery = try await mount(await installedRecovery(devices), name: "recovery", readOnly: false)
            image = try locateImage(recovery)
            guard String(image.path.dropFirst(recovery.path.count + 1)) == relative,
                  try digest(image) == journal.receipt.originalSHA256,
                  try companionHashes(image) == journal.companions else { throw Failure(reason: "backing image changed before replacement") }
            let adjacent = image.deletingLastPathComponent().appendingPathComponent(".pomme-experimental-" + request.vmID.uuidString.lowercased() + ".dmg")
            try copyVerified(file("prepared.dmg"), to: adjacent, expected: journal.receipt.imageSHA256,
                             mode: Int(try checked(image).st_mode & 0o777))
            guard try digest(adjacent) == journal.receipt.imageSHA256 else { throw Failure(reason: "adjacent replacement verification failed") }
            let handle = try FileHandle(forWritingTo: adjacent)
            try handle.synchronize(); try handle.close()
            try Task.checkCancellation()
            guard rename(adjacent.path, image.path) == 0 else { throw Failure(reason: "atomic BaseSystem replacement failed") }
            let parent = open(image.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { throw Failure(reason: "cannot sync replacement directory") }
            let synced = fsync(parent); close(parent)
            guard synced == 0, try digest(image) == journal.receipt.imageSHA256,
                  try companionHashes(image) == journal.companions else { throw Failure(reason: "replacement verification failed") }
            PommeUnifiedLog.experimentalRecovery.notice("replaced and verified BaseSystem with the prepared image")
            try await detached()
            return try finish()
        }
    }

    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var overflow = false
        func snapshot() -> (data: Data, overflow: Bool) {
            lock.lock(); defer { lock.unlock() }; return (data, overflow)
        }
        private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            let remaining = max(0, 4 * 1024 * 1024 - data.count)
            data.append(chunk.prefix(remaining))
            if chunk.count > remaining { overflow = true }
        }
    }
    private static func waitForReaders(_ group: DispatchGroup, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: group.wait(timeout: .now() + timeout) == .success)
            }
        }
    }
    private final class Termination: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        func record(_ value: Int32) { lock.lock(); status = value; lock.unlock() }
        func result() -> Int32? { lock.lock(); defer { lock.unlock() }; return status }
    }
    /// This delay deliberately remains bounded after task cancellation so
    /// termination cleanup does not busy-loop on an already cancelled sleep.
    private static func terminationPollDelay() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
    }
    static func execute(_ command: Command) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        let stdout = Capture(), stderr = Capture(), group = DispatchGroup()
        let termination = Termination()
        // Install before launch so even a child that exits immediately reports
        // completion. Never call waitUntilExit after an async thread hop.
        process.terminationHandler = { child in termination.record(child.terminationStatus) }
        try Task.checkCancellation()
        try process.run()
        PommeUnifiedLog.process.info(
            "launched \(command.executable, privacy: .public) pid=\(process.processIdentifier, privacy: .public)"
        )
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        for (pipe, capture) in [(out, stdout), (err, stderr)] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let fd = pipe.fileHandleForReading.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var buffer = [UInt8](repeating: 0, count: 65536)
                while !capture.shouldStop() {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if count > 0 { capture.append(Data(buffer.prefix(count))); continue }
                    if count == 0 { return }
                    if errno == EINTR { continue }
                    if errno == EAGAIN { usleep(10_000); continue }
                    return
                }
            }
        }
        let deadline = Date().addingTimeInterval(command.timeout)
        var cancelled = false, timedOut = false
        while termination.result() == nil {
            if Task.isCancelled || Date() >= deadline {
                cancelled = Task.isCancelled; timedOut = !cancelled
                PommeUnifiedLog.process.error("""
                    \(command.executable, privacy: .public) pid=\(process.processIdentifier, privacy: .public) \
                    \(cancelled ? "cancelled" : "timed out after \(command.timeout)s", privacy: .public); terminating
                    """)
                if process.isRunning { process.terminate() }
                let gracefulDeadline = Date().addingTimeInterval(1)
                while termination.result() == nil && Date() < gracefulDeadline { await terminationPollDelay() }
                if termination.result() == nil && process.isRunning { kill(process.processIdentifier, SIGKILL) }
                let forcedDeadline = Date().addingTimeInterval(5)
                while termination.result() == nil && Date() < forcedDeadline { await terminationPollDelay() }
                break
            }
            await terminationPollDelay()
        }
        guard let status = termination.result() else {
            stdout.stop(); stderr.stop()
            _ = await waitForReaders(group, timeout: 1)
            throw Failure(reason: "command termination was not confirmed", processTerminationUnconfirmed: true)
        }
        // Child descendants must not hold these readers indefinitely.
        guard await waitForReaders(group, timeout: 5) else {
            stdout.stop(); stderr.stop()
            _ = await waitForReaders(group, timeout: 1)
            throw Failure(reason: "command output did not close", processTerminationUnconfirmed: true)
        }
        if cancelled { throw CancellationError() }
        if timedOut { throw Failure(reason: "command timed out") }
        let capturedOutput = stdout.snapshot(), capturedError = stderr.snapshot()
        guard !capturedOutput.overflow, !capturedError.overflow else { throw Failure(reason: "command output exceeded the bounded capture limit") }
        return CommandResult(status: status, stdout: capturedOutput.data, stderr: capturedError.data)
    }
}
