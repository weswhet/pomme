import CryptoKit
import Darwin
import Foundation

enum VMSecurityStatePolicyMode: String, Codable, Sendable {
    case restoreOriginal
    case preserveRequested
    case exactSnapshot
}

enum VMSecurityStatePhase: String, Codable, Sendable, CaseIterable {
    case captured
    case preflightComplete
    case securityMutationStarted
    case securityMutationComplete
    case restorationStarted
    case verifiedComplete

    private var index: Int {
        Self.allCases.firstIndex(of: self)!
    }

    func mayAdvance(to next: Self) -> Bool {
        next.index == index + 1
    }

    var next: Self? {
        let nextIndex = index + 1
        guard Self.allCases.indices.contains(nextIndex) else { return nil }
        return Self.allCases[nextIndex]
    }
}

struct VMSecurityStateIdentity: Codable, Equatable, Sendable {
    let vmUUID: String
    let machineIdentifierSHA256: String
    /// A cheap stable resource identifier; never hash the sparse guest disk
    /// during a security transition.
    let diskImageFileResourceID: String
    let buildVersion: String
    let volumeGroupUUID: String
    let volumeVUID: String

    func isWellFormed() -> Bool {
        UUID(uuidString: vmUUID) != nil
            && Self.isSHA256(machineIdentifierSHA256)
            && !diskImageFileResourceID.isEmpty
            && !buildVersion.isEmpty
            && UUID(uuidString: volumeGroupUUID) != nil
            && volumeVUID.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

struct VMSecurityStateSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 2
    static let requiredBootPolicyFlags: Set<String> = [
        "allowsMDM", "allowsKexts", "kernelCTRRDisabled",
        "allowsCustomBootArguments", "ssvDisabled"
    ]

    let schemaVersion: Int
    let identity: VMSecurityStateIdentity
    let policyMode: VMSecurityStatePolicyMode
    let reconstructible: Bool
    /// Typed boot-policy flags returned by the guest bputil parser. Unknown
    /// keys are rejected by that parser and are never inferred host-side.
    let bootPolicyFlags: [String: Bool]
    /// Exact typed `securityMode` field from AMFIPolicyPreflight.
    let securityMode: String?
    let bootPolicyPlatformVersion: String?
    /// Distinguish a missing `boot-args` NVRAM key from an explicitly empty
    /// key, so restoration can reproduce the original state exactly.
    let bootArgumentsPresent: Bool
    let bootArgumentsValue: String?
    /// SHA-256 supplied by the guest over every reconstructible preflight
    /// field. The host recomputes it rather than treating it as an opaque
    /// acknowledgement token.
    let preflightDigest: String
    let phase: VMSecurityStatePhase
    let createdAt: Date
    let updatedAt: Date

    init(
        identity: VMSecurityStateIdentity,
        policyMode: VMSecurityStatePolicyMode,
        reconstructible: Bool,
        bootPolicyFlags: [String: Bool] = [:],
        securityMode: String? = nil,
        bootPolicyPlatformVersion: String? = nil,
        bootArgumentsPresent: Bool,
        bootArgumentsValue: String?,
        preflightDigest: String,
        phase: VMSecurityStatePhase = .captured,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        schemaVersion = Self.schemaVersion
        self.identity = identity
        self.policyMode = policyMode
        self.reconstructible = reconstructible
        self.bootPolicyFlags = bootPolicyFlags
        self.securityMode = securityMode
        self.bootPolicyPlatformVersion = bootPolicyPlatformVersion
        self.bootArgumentsPresent = bootArgumentsPresent
        self.bootArgumentsValue = bootArgumentsValue
        self.preflightDigest = preflightDigest.lowercased()
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func advancing(to next: VMSecurityStatePhase, at date: Date = Date()) throws -> Self {
        guard phase.mayAdvance(to: next) else {
            throw VMSecurityStateStoreError.invalidPhaseTransition(current: phase, next: next)
        }
        return .init(
            identity: identity,
            policyMode: policyMode,
            reconstructible: reconstructible,
            bootPolicyFlags: bootPolicyFlags,
            securityMode: securityMode,
            bootPolicyPlatformVersion: bootPolicyPlatformVersion,
            bootArgumentsPresent: bootArgumentsPresent,
            bootArgumentsValue: bootArgumentsValue,
            preflightDigest: preflightDigest,
            phase: next,
            createdAt: createdAt,
            updatedAt: date
        )
    }

    func isWellFormed() -> Bool {
        schemaVersion == Self.schemaVersion
            && identity.isWellFormed()
            && (!reconstructible || (
                Set(bootPolicyFlags.keys) == Self.requiredBootPolicyFlags
                    && ["full", "reduced", "permissive"].contains(securityMode)
                    && bootPolicyPlatformVersion?.isEmpty == false
            ))
            && (bootArgumentsPresent == (bootArgumentsValue != nil))
            && Self.isSHA256(preflightDigest)
            && preflightDigest == computedPreflightDigest
            && policyFlagsAreConsistent
            && updatedAt >= createdAt
    }

    func preflightWirePayload() throws -> [String: Any] {
        guard isWellFormed(), let securityMode,
              let platformVersion = bootPolicyPlatformVersion
        else { throw VMSecurityStateStoreError.malformed }
        var flags = bootPolicyFlags.reduce(into: [String: Any]()) { result, entry in
            result[entry.key] = entry.value
        }
        flags["securityMode"] = securityMode
        return [
            "volumeGroupUUID": identity.volumeGroupUUID,
            "vuid": identity.volumeVUID,
            "platformVersion": platformVersion,
            "bootPolicyFlags": flags,
            "bootArgumentsPresent": bootArgumentsPresent,
            "bootArguments": bootArgumentsValue ?? "",
            "digest": preflightDigest
        ]
    }

    /// A non-secret, stable binding for an exact restoration capture.  The
    /// durable snapshot advances its phase as AMFI restoration progresses, so
    /// the evidence deliberately excludes `phase` and `updatedAt`.  It still
    /// covers every value used to reconstruct the policy, the captured time,
    /// and the host identity that owns the snapshot.
    ///
    /// This digest is safe to return in a public result: it never serializes
    /// boot arguments or any other snapshot field into that result.
    func exactRestorationEvidence() throws -> VMSecurityStateRestorationEvidence {
        guard isWellFormed(), policyMode == .exactSnapshot, reconstructible else {
            throw VMSecurityStateStoreError.malformed
        }
        let canonical = ExactRestorationDigestPayload(snapshot: self)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonical)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(
            snapshotSHA256: digest,
            preflightDigest: preflightDigest,
            identity: identity,
            securityMode: securityMode,
            bootPolicyFlags: bootPolicyFlags,
            bootArgumentsPresent: bootArgumentsPresent,
            bootArgumentsSHA256: SHA256.hash(data: Data((bootArgumentsValue ?? "").utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private var computedPreflightDigest: String? {
        guard reconstructible,
              let securityMode,
              let platformVersion = bootPolicyPlatformVersion,
              let bootArguments = bootArgumentsValue ?? (bootArgumentsPresent ? nil : "")
        else { return nil }
        let requiredFlags = Self.requiredBootPolicyFlags.sorted()
        guard Set(bootPolicyFlags.keys) == Self.requiredBootPolicyFlags,
              requiredFlags.allSatisfy({ bootPolicyFlags[$0] != nil })
        else { return nil }
        let text = [
            identity.volumeGroupUUID,
            identity.volumeVUID,
            securityMode,
            bootPolicyFlags["allowsMDM"]! ? "1" : "0",
            bootPolicyFlags["allowsKexts"]! ? "1" : "0",
            bootPolicyFlags["kernelCTRRDisabled"]! ? "1" : "0",
            bootPolicyFlags["allowsCustomBootArguments"]! ? "1" : "0",
            bootPolicyFlags["ssvDisabled"]! ? "1" : "0",
            platformVersion,
            bootArgumentsPresent ? "1" : "0",
            bootArguments
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var policyFlagsAreConsistent: Bool {
        guard reconstructible, let securityMode else { return false }
        switch securityMode {
        case "full":
            return bootPolicyFlags.values.allSatisfy { !$0 }
        case "reduced":
            return bootPolicyFlags["kernelCTRRDisabled"] == false
                && bootPolicyFlags["allowsCustomBootArguments"] == false
                && bootPolicyFlags["ssvDisabled"] == false
        case "permissive":
            return true
        default:
            return false
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

/// Public, non-secret evidence that an AMFI enable operation restored a
/// particular durable exact snapshot. Keep this deliberately narrower than
/// `VMSecurityStateSnapshot`: the public proof exposes the typed policy flags
/// needed to verify exact restoration, while boot arguments remain owner-only
/// in `SecurityState.json` and are represented only by their SHA-256 binding.
struct VMSecurityStateRestorationEvidence: Equatable, Sendable {
    let snapshotSHA256: String
    let preflightDigest: String
    let identity: VMSecurityStateIdentity
    let securityMode: String?
    let bootPolicyFlags: [String: Bool]
    let bootArgumentsPresent: Bool
    let bootArgumentsSHA256: String

    func payload(snapshotConsumed: Bool) -> [String: Any] {
        [
            "snapshotSHA256": snapshotSHA256,
            "preflightDigest": preflightDigest,
            "vmUUID": identity.vmUUID,
            "buildVersion": identity.buildVersion,
            "securityMode": securityMode ?? "",
            "allowsMDM": bootPolicyFlags["allowsMDM"] ?? false,
            "allowsKexts": bootPolicyFlags["allowsKexts"] ?? false,
            "kernelCTRRDisabled": bootPolicyFlags["kernelCTRRDisabled"] ?? false,
            "allowsCustomBootArguments": bootPolicyFlags["allowsCustomBootArguments"] ?? false,
            "ssvDisabled": bootPolicyFlags["ssvDisabled"] ?? false,
            "bootArgumentsPresent": bootArgumentsPresent,
            "bootArgumentsSHA256": bootArgumentsSHA256,
            "policyRestorationMode": VMSecurityStatePolicyMode.exactSnapshot.rawValue,
            "verified": true,
            "snapshotConsumed": snapshotConsumed
        ]
    }
}

/// The value encoded for the public evidence digest.  Do not substitute a
/// status payload here: status output does not bind the captured policy or
/// the identity-bearing durable file that AMFI enable validates.
private struct ExactRestorationDigestPayload: Codable {
    let schemaVersion: Int
    let identity: VMSecurityStateIdentity
    let policyMode: VMSecurityStatePolicyMode
    let reconstructible: Bool
    let bootPolicyFlags: [String: Bool]
    let securityMode: String?
    let bootPolicyPlatformVersion: String?
    let bootArgumentsPresent: Bool
    let bootArgumentsValue: String?
    let preflightDigest: String
    let createdAt: Date

    init(snapshot: VMSecurityStateSnapshot) {
        schemaVersion = snapshot.schemaVersion
        identity = snapshot.identity
        policyMode = snapshot.policyMode
        reconstructible = snapshot.reconstructible
        bootPolicyFlags = snapshot.bootPolicyFlags
        securityMode = snapshot.securityMode
        bootPolicyPlatformVersion = snapshot.bootPolicyPlatformVersion
        bootArgumentsPresent = snapshot.bootArgumentsPresent
        bootArgumentsValue = snapshot.bootArgumentsValue
        preflightDigest = snapshot.preflightDigest
        createdAt = snapshot.createdAt
    }
}

/// Strict host decoder for `AMFIPolicyPreflight.wirePayload`. It rejects
/// missing, unknown, aliased, or loosely typed fields before any durable state
/// or guest mutation is attempted.
enum VMSecurityStatePreflight {
    static func snapshot(
        guestPayload: [String: Any],
        bundle: BundleLayout,
        capturedAt: Date = Date()
    ) throws -> VMSecurityStateSnapshot {
        // JSONEncoder's ISO-8601 strategy persists whole seconds. Normalize
        // before the atomic round trip so an immediate reload can prove it is
        // byte-for-byte the same acknowledged snapshot.
        let capturedAt = Date(timeIntervalSince1970: floor(capturedAt.timeIntervalSince1970))
        let expectedKeys: Set<String> = [
            "volumeGroupUUID", "vuid", "platformVersion", "bootPolicyFlags",
            "bootArgumentsPresent", "bootArguments", "digest"
        ]
        guard Set(guestPayload.keys) == expectedKeys,
              let rawVolumeGroupUUID = guestPayload["volumeGroupUUID"] as? String,
              let volumeGroupUUID = UUID(uuidString: rawVolumeGroupUUID)?.uuidString.lowercased(),
              rawVolumeGroupUUID.lowercased() == volumeGroupUUID,
              let vuid = guestPayload["vuid"] as? String,
              vuid.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              let platformVersion = guestPayload["platformVersion"] as? String,
              !platformVersion.isEmpty,
              let flagsPayload = guestPayload["bootPolicyFlags"] as? [String: Any],
              Set(flagsPayload.keys) == VMSecurityStateSnapshot.requiredBootPolicyFlags.union(["securityMode"]),
              let securityMode = flagsPayload["securityMode"] as? String,
              let allowsMDM = exactBool(flagsPayload["allowsMDM"]),
              let allowsKexts = exactBool(flagsPayload["allowsKexts"]),
              let kernelCTRRDisabled = exactBool(flagsPayload["kernelCTRRDisabled"]),
              let allowsCustomBootArguments = exactBool(flagsPayload["allowsCustomBootArguments"]),
              let ssvDisabled = exactBool(flagsPayload["ssvDisabled"]),
              let bootArgumentsPresent = exactBool(guestPayload["bootArgumentsPresent"]),
              let bootArguments = guestPayload["bootArguments"] as? String,
              let digest = guestPayload["digest"] as? String,
              digest == digest.lowercased()
        else { throw VMSecurityStateStoreError.malformed }

        let hostIdentity = try hostIdentity(
            bundle: bundle,
            volumeGroupUUID: volumeGroupUUID,
            vuid: vuid
        )

        let snapshot = VMSecurityStateSnapshot(
            identity: hostIdentity,
            policyMode: .exactSnapshot,
            reconstructible: true,
            bootPolicyFlags: [
                "allowsMDM": allowsMDM,
                "allowsKexts": allowsKexts,
                "kernelCTRRDisabled": kernelCTRRDisabled,
                "allowsCustomBootArguments": allowsCustomBootArguments,
                "ssvDisabled": ssvDisabled
            ],
            securityMode: securityMode,
            bootPolicyPlatformVersion: platformVersion,
            bootArgumentsPresent: bootArgumentsPresent,
            bootArgumentsValue: bootArgumentsPresent ? bootArguments : nil,
            preflightDigest: digest,
            createdAt: capturedAt,
            updatedAt: capturedAt
        )
        guard snapshot.isWellFormed(), !bootArgumentsPresent || snapshot.bootArgumentsValue == bootArguments,
              bootArgumentsPresent || bootArguments.isEmpty
        else { throw VMSecurityStateStoreError.malformed }
        return snapshot
    }

    static func hostIdentity(
        bundle: BundleLayout,
        volumeGroupUUID: String,
        vuid: String
    ) throws -> VMSecurityStateIdentity {
        let metadata = try metadataPayload(bundle: bundle)
        guard let vmUUID = vmUUID(from: metadata),
              let buildVersion = metadata["buildVersion"] as? String,
              !buildVersion.isEmpty
        else { throw VMSecurityStateStoreError.identityMismatch }
        let machineIdentifier = try Data(contentsOf: bundle.machineIdentifierURL)
        guard !machineIdentifier.isEmpty else { throw VMSecurityStateStoreError.identityMismatch }
        let attributes = try FileManager.default.attributesOfItem(atPath: bundle.diskImageURL.path)
        guard let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber
        else { throw VMSecurityStateStoreError.identityMismatch }
        return VMSecurityStateIdentity(
            vmUUID: vmUUID,
            machineIdentifierSHA256: SHA256.hash(data: machineIdentifier)
                .map { String(format: "%02x", $0) }.joined(),
            diskImageFileResourceID: "\(systemNumber.uint64Value):\(fileNumber.uint64Value)",
            buildVersion: buildVersion,
            volumeGroupUUID: volumeGroupUUID,
            volumeVUID: vuid
        )
    }

    private static func exactBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }
}

enum VMSecurityStateStoreError: LocalizedError, Equatable {
    case malformed
    case insecurePermissions
    case identityMismatch
    case stale
    case notVerifiedComplete
    case invalidPhaseTransition(current: VMSecurityStatePhase, next: VMSecurityStatePhase)
    case alreadyExists
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .malformed:
            "Security state is malformed or uses an unsupported schema."
        case .insecurePermissions:
            "Security state permissions are not owner-only."
        case .identityMismatch:
            "Security state belongs to a different VM identity."
        case .stale:
            "Security state is older than the permitted recovery window."
        case .notVerifiedComplete:
            "Security state cannot be cleared before restoration is verified complete."
        case .invalidPhaseTransition:
            "Security state phase transition is invalid."
        case .alreadyExists:
            "Security state already exists and cannot be replaced."
        case .writeFailed(let detail):
            "Could not persist security state: \(detail)"
        }
    }
}

struct VMSecurityStateStore {
    static let maximumRestorationAge: TimeInterval = 24 * 60 * 60
    typealias AtomicWriter = (_ data: Data, _ destination: URL) throws -> Void
    typealias CreateIfAbsentWriter = (_ data: Data, _ destination: URL) throws -> Void
    typealias AttributeReader = (_ path: String) throws -> [FileAttributeKey: Any]

    private let destination: URL
    private let fileManager: FileManager
    private let writeAtomically: AtomicWriter
    private let createIfAbsent: CreateIfAbsentWriter
    private let readAttributes: AttributeReader

    init(
        bundle: BundleLayout,
        fileManager: FileManager = .default,
        writeAtomically: AtomicWriter? = nil,
        createIfAbsent: CreateIfAbsentWriter? = nil,
        readAttributes: AttributeReader? = nil
    ) {
        destination = bundle.securityStateURL
        self.fileManager = fileManager
        self.writeAtomically = writeAtomically ?? { data, destination in
            try Self.defaultAtomicWrite(data, to: destination, fileManager: fileManager)
        }
        self.createIfAbsent = createIfAbsent ?? { data, destination in
            try Self.defaultAtomicCreateIfAbsent(data, to: destination, fileManager: fileManager)
        }
        self.readAttributes = readAttributes ?? { try fileManager.attributesOfItem(atPath: $0) }
    }

    func save(_ snapshot: VMSecurityStateSnapshot) throws {
        guard snapshot.isWellFormed() else {
            throw VMSecurityStateStoreError.malformed
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try writeAtomically(try encoder.encode(snapshot), destination)
            try requireOwnerOnlyRegularFile()
        } catch let error as VMSecurityStateStoreError {
            throw error
        } catch {
            throw VMSecurityStateStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Persists the initial capture without ever replacing a concurrent or
    /// pre-existing snapshot.  This is the critical-lab counterpart to
    /// `save`: the link publication is create-if-absent at the filesystem
    /// boundary, closing the lstat-to-save race.
    func saveIfAbsent(_ snapshot: VMSecurityStateSnapshot) throws {
        guard snapshot.isWellFormed() else {
            throw VMSecurityStateStoreError.malformed
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try createIfAbsent(try encoder.encode(snapshot), destination)
            try requireOwnerOnlyRegularFile()
        } catch let error as VMSecurityStateStoreError {
            throw error
        } catch {
            throw VMSecurityStateStoreError.writeFailed(error.localizedDescription)
        }
    }

    func hasState() throws -> Bool {
        guard fileManager.fileExists(atPath: destination.path) else { return false }
        try requireOwnerOnlyRegularFile()
        return true
    }

    func load(
        maximumAge: TimeInterval? = nil,
        now: Date = Date()
    ) throws -> VMSecurityStateSnapshot {
        try requireOwnerOnlyRegularFile()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: VMSecurityStateSnapshot
        do {
            snapshot = try decoder.decode(VMSecurityStateSnapshot.self, from: Data(contentsOf: destination))
        } catch {
            throw VMSecurityStateStoreError.malformed
        }
        guard snapshot.isWellFormed() else {
            throw VMSecurityStateStoreError.malformed
        }
        if let maximumAge {
            let age = now.timeIntervalSince(snapshot.createdAt)
            if age < 0 || age > maximumAge {
                throw VMSecurityStateStoreError.stale
            }
        }
        return snapshot
    }

    func load(
        matching identity: VMSecurityStateIdentity,
        maximumAge: TimeInterval? = nil,
        now: Date = Date()
    ) throws -> VMSecurityStateSnapshot {
        let snapshot = try load(maximumAge: maximumAge, now: now)
        guard snapshot.identity == identity else {
            throw VMSecurityStateStoreError.identityMismatch
        }
        return snapshot
    }

    func advance(
        _ snapshot: VMSecurityStateSnapshot,
        to phase: VMSecurityStatePhase,
        at date: Date = Date()
    ) throws -> VMSecurityStateSnapshot {
        let advanced = try snapshot.advancing(to: phase, at: date)
        try save(advanced)
        return advanced
    }

    func advanceThrough(
        _ snapshot: VMSecurityStateSnapshot,
        to target: VMSecurityStatePhase,
        at date: Date = Date()
    ) throws -> VMSecurityStateSnapshot {
        var current = snapshot
        let date = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        while current.phase != target {
            guard let next = current.phase.next else {
                throw VMSecurityStateStoreError.invalidPhaseTransition(
                    current: current.phase,
                    next: target
                )
            }
            current = try advance(current, to: next, at: date)
        }
        return current
    }

    func clearIfVerifiedComplete(matching identity: VMSecurityStateIdentity) throws {
        let snapshot = try load(matching: identity)
        guard snapshot.phase == .verifiedComplete else {
            throw VMSecurityStateStoreError.notVerifiedComplete
        }
        do {
            try fileManager.removeItem(at: destination)
        } catch {
            throw VMSecurityStateStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func requireOwnerOnlyRegularFile() throws {
        var values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw VMSecurityStateStoreError.malformed
        }
        let attributes = try readAttributes(destination.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.intValue == Int32(geteuid())
        else {
            throw VMSecurityStateStoreError.insecurePermissions
        }
        values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw VMSecurityStateStoreError.malformed
        }
    }

    private static func defaultAtomicWrite(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let parent = destination.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw VMSecurityStateStoreError.writeFailed("bundle directory is unavailable")
        }
        let temporary = parent.appendingPathComponent(".SecurityState-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw VMSecurityStateStoreError.malformed
                }
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func defaultAtomicCreateIfAbsent(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let parent = destination.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw VMSecurityStateStoreError.writeFailed("bundle directory is unavailable")
        }
        let temporary = parent.appendingPathComponent(".SecurityState-create-\(UUID().uuidString)")
        var descriptor: Int32 = -1
        var published = false
        do {
            descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw VMSecurityStateStoreError.writeFailed("could not create initial security state staging file")
            }
            // `open` is filtered through the process umask. Set and prove
            // the exact mode on the opened inode before writing or naming it.
            guard fchmod(descriptor, 0o600) == 0 else {
                throw VMSecurityStateStoreError.writeFailed("could not set initial security state permissions")
            }
            try requireSingleOwnerRegularFile(descriptor, context: "initial security state staging file")
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else {
                        throw VMSecurityStateStoreError.writeFailed("could not write initial security state staging file")
                    }
                    offset += written
                }
            }
            let synchronized = fsync(descriptor) == 0
            let closed = close(descriptor) == 0
            descriptor = -1
            guard synchronized, closed else {
                throw VMSecurityStateStoreError.writeFailed("could not synchronize initial security state staging file")
            }
            // `link` would temporarily create two names for the mutable
            // inode. Rename-with-exclusive-create publishes the already
            // synced inode without an alias window and refuses every existing
            // destination, including dangling symlinks.
            guard renameatx_np(
                AT_FDCWD,
                temporary.path,
                AT_FDCWD,
                destination.path,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                if errno == EEXIST { throw VMSecurityStateStoreError.alreadyExists }
                throw VMSecurityStateStoreError.writeFailed("could not publish initial security state")
            }
            published = true
            let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY)
            guard parentDescriptor >= 0 else {
                throw VMSecurityStateStoreError.writeFailed("could not synchronize security state directory")
            }
            defer { close(parentDescriptor) }
            guard fsync(parentDescriptor) == 0 else {
                throw VMSecurityStateStoreError.writeFailed("could not synchronize published security state")
            }
            try requirePublishedSingleOwnerRegularFile(destination)
        } catch {
            if descriptor >= 0 { _ = close(descriptor) }
            // Before publication this is our exact staging name. After the
            // exclusive rename it has no staging alias to remove; report any
            // post-publication fsync/validation failure rather than claiming
            // success or deleting a durable destination.
            if !published { _ = unlink(temporary.path) }
            throw error
        }
    }

    private static func requireSingleOwnerRegularFile(
        _ descriptor: Int32,
        context: String
    ) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == geteuid(),
              value.st_mode & 0o777 == 0o600,
              value.st_nlink == 1
        else {
            throw VMSecurityStateStoreError.writeFailed("\(context) is not an owner-only unlinked regular file")
        }
    }

    private static func requirePublishedSingleOwnerRegularFile(
        _ destination: URL
    ) throws {
        var named = stat()
        guard lstat(destination.path, &named) == 0,
              named.st_mode & S_IFMT == S_IFREG,
              named.st_uid == geteuid(),
              named.st_mode & 0o777 == 0o600,
              named.st_nlink == 1
        else {
            throw VMSecurityStateStoreError.writeFailed("published initial security state is not owner-only")
        }
        let descriptor = open(destination.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw VMSecurityStateStoreError.writeFailed("could not reopen published initial security state")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino
        else {
            throw VMSecurityStateStoreError.writeFailed("published initial security state changed during validation")
        }
        try requireSingleOwnerRegularFile(descriptor, context: "published initial security state")
    }
}
