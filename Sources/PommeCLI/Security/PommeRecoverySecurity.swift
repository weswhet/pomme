import CryptoKit
import Foundation

enum PommeRecoverySecurityError: Error, LocalizedError, Equatable, Sendable {
    case invalidSnapshot
    case invalidPolicy
    case invalidNVRAM
    case operationRejected
    case verificationFailed
    case rollbackFailed
    case journalFailed

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            "Security snapshot was rejected."
        case .invalidPolicy:
            "LocalPolicy mutation was rejected."
        case .invalidNVRAM:
            "NVRAM mutation was rejected."
        case .operationRejected:
            "Recovery security operation was rejected."
        case .verificationFailed:
            "Recovery security operation could not be verified."
        case .rollbackFailed:
            "Recovery security rollback could not be verified."
        case .journalFailed:
            "Recovery security snapshot could not be durably recorded."
        }
    }
}

struct PommeNVRAMValue: Codable, Equatable, Sendable {
    let present: Bool
    let value: String?

    init(present: Bool, value: String?) throws {
        guard present == (value != nil),
              value.map({ $0.utf8.count <= 64 * 1024 && !$0.contains("\0") }) ?? true
        else { throw PommeRecoverySecurityError.invalidNVRAM }
        self.present = present
        self.value = value
    }

    static let absent = try! PommeNVRAMValue(present: false, value: nil)
}

struct PommeNVRAMDelta: Codable, Equatable, Sendable {
    let values: [String: PommeNVRAMValue]

    init(values: [String: PommeNVRAMValue]) throws {
        guard !values.isEmpty,
              values.keys.allSatisfy(Self.validKey)
        else { throw PommeRecoverySecurityError.invalidNVRAM }
        self.values = values
    }

    static func bootArguments(
        present: Bool,
        value: String?
    ) throws -> Self {
        try .init(values: ["boot-args": .init(present: present, value: value)])
    }

    func value(for key: String) -> PommeNVRAMValue? { values[key] }

    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty
            && key.utf8.count <= 128
            && key.unicodeScalars.allSatisfy {
                let value = $0.value
                return (0x41...0x5a).contains(value)
                    || (0x61...0x7a).contains(value)
                    || (0x30...0x39).contains(value)
                    || value == 0x2d
                    || value == 0x5f
            }
    }
}

/// NVRAM boot arguments are treated as a token sequence for the AMFI switch.
/// The original string remains in the durable snapshot and is restored byte
/// for byte; only the requested override is added or removed in a mutation.
enum PommeBootArguments {
    static let amfiOverride = "amfi_get_out_of_my_way=0x1"

    static func addingOverride(to value: String?) -> String {
        let tokens = tokenize(value ?? "")
        guard !tokens.contains(amfiOverride) else { return tokens.joined(separator: " ") }
        return (tokens + [amfiOverride]).joined(separator: " ")
    }

    static func removingOverride(from value: String?) -> String {
        tokenize(value ?? "")
            .filter { $0 != amfiOverride }
            .joined(separator: " ")
    }

    static func containsOverride(_ value: String?) -> Bool {
        tokenize(value ?? "").contains(amfiOverride)
    }

    private static func tokenize(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}

struct PommeAMFISecuritySnapshot: Codable, Equatable, Sendable {
    let localPolicy: Data
    let nvram: PommeNVRAMDelta
    let capturedAt: Date
    let localPolicySHA256: String

    init(localPolicy: Data, nvram: PommeNVRAMDelta, capturedAt: Date = Date()) throws {
        guard !localPolicy.isEmpty else { throw PommeRecoverySecurityError.invalidSnapshot }
        self.localPolicy = localPolicy
        self.nvram = nvram
        self.capturedAt = capturedAt
        localPolicySHA256 = PommeRecoveryCrypto.hex(SHA256.hash(data: localPolicy))
    }

    var isWellFormed: Bool {
        !localPolicy.isEmpty
            && localPolicySHA256 == PommeRecoveryCrypto.hex(SHA256.hash(data: localPolicy))
            && !nvram.values.isEmpty
    }

    /// Durable metadata (capture time) is intentionally not part of the
    /// resource comparison. Recovery read-back can produce a fresh envelope
    /// while the LocalPolicy bytes and exact NVRAM values remain identical.
    func resourcesEqual(to other: Self) -> Bool {
        localPolicy == other.localPolicy
            && localPolicySHA256 == other.localPolicySHA256
            && nvram == other.nvram
    }
}

struct PommeAMFIMutation: Equatable, Sendable {
    let localPolicy: Data
    let nvram: PommeNVRAMDelta

    init(localPolicy: Data, nvram: PommeNVRAMDelta) throws {
        guard !localPolicy.isEmpty else { throw PommeRecoverySecurityError.invalidPolicy }
        self.localPolicy = localPolicy
        self.nvram = nvram
    }
}

struct PommeAMFITransactionReport: Equatable, Sendable {
    let snapshotDigest: String
    let appliedDigest: String
    let verified: Bool
    let rolledBack: Bool
    let rollbackVerified: Bool

    var payload: [String: Any] {
        [
            "snapshotDigest": snapshotDigest,
            "appliedDigest": appliedDigest,
            "verified": verified,
            "rolledBack": rolledBack,
            "rollbackVerified": rollbackVerified
        ]
    }
}

/// Dependencies are the smallest surface required to mutate the Recovery
/// LocalPolicy and NVRAM. The policy and NVRAM writes remain separate so a
/// failure between them can restore both exact preflight values.
struct PommeAMFITransactionDependencies: Sendable {
    let capture: @Sendable () async throws -> PommeAMFISecuritySnapshot
    let applyLocalPolicy: @Sendable (Data) async throws -> Void
    let applyNVRAM: @Sendable (PommeNVRAMDelta) async throws -> Void
    let read: @Sendable () async throws -> PommeAMFISecuritySnapshot
    let persistSnapshot: @Sendable (PommeAMFISecuritySnapshot) throws -> Void
    let clearSnapshot: @Sendable () throws -> Void

    init(
        capture: @escaping @Sendable () async throws -> PommeAMFISecuritySnapshot,
        applyLocalPolicy: @escaping @Sendable (Data) async throws -> Void,
        applyNVRAM: @escaping @Sendable (PommeNVRAMDelta) async throws -> Void,
        read: @escaping @Sendable () async throws -> PommeAMFISecuritySnapshot,
        persistSnapshot: @escaping @Sendable (PommeAMFISecuritySnapshot) throws -> Void = { _ in },
        clearSnapshot: @escaping @Sendable () throws -> Void = {}
    ) {
        self.capture = capture
        self.applyLocalPolicy = applyLocalPolicy
        self.applyNVRAM = applyNVRAM
        self.read = read
        self.persistSnapshot = persistSnapshot
        self.clearSnapshot = clearSnapshot
    }
}

/// Atomic AMFI mutation over LocalPolicy and the exact NVRAM delta. A partial
/// write or a failed read-back immediately runs the same rollback path for
/// both resources and verifies the original snapshot before returning.
struct PommeAMFITransaction: Sendable {
    let dependencies: PommeAMFITransactionDependencies

    init(dependencies: PommeAMFITransactionDependencies) {
        self.dependencies = dependencies
    }

    func execute(_ mutation: PommeAMFIMutation) async throws -> PommeAMFITransactionReport {
        let snapshot = try await dependencies.capture()
        guard snapshot.isWellFormed else { throw PommeRecoverySecurityError.invalidSnapshot }
        do {
            try dependencies.persistSnapshot(snapshot)
        } catch {
            throw PommeRecoverySecurityError.journalFailed
        }

        do {
            try await dependencies.applyLocalPolicy(mutation.localPolicy)
            try await dependencies.applyNVRAM(mutation.nvram)
            let observed = try await dependencies.read()
            guard observed.isWellFormed,
                  observed.localPolicy == mutation.localPolicy,
                  observed.nvram == mutation.nvram
            else { throw PommeRecoverySecurityError.verificationFailed }
            try dependencies.clearSnapshot()
            return .init(
                snapshotDigest: snapshot.localPolicySHA256,
                appliedDigest: PommeRecoveryCrypto.hex(SHA256.hash(data: mutation.localPolicy)),
                verified: true,
                rolledBack: false,
                rollbackVerified: false
            )
        } catch {
            do {
                try await dependencies.applyLocalPolicy(snapshot.localPolicy)
                try await dependencies.applyNVRAM(snapshot.nvram)
                let restored = try await dependencies.read()
                guard restored.resourcesEqual(to: snapshot) else {
                    throw PommeRecoverySecurityError.rollbackFailed
                }
            } catch {
                throw PommeRecoverySecurityError.rollbackFailed
            }
            throw (error is PommeRecoverySecurityError)
                ? error
                : PommeRecoverySecurityError.operationRejected
        }
    }

    /// Disable AMFI while preserving unrelated boot arguments and the exact
    /// original key-presence state in the caller's snapshot.
    func disable(localPolicy: Data, currentBootArguments: PommeNVRAMValue) async throws -> PommeAMFITransactionReport {
        let next = try PommeNVRAMDelta.bootArguments(
            present: true,
            value: PommeBootArguments.addingOverride(to: currentBootArguments.value)
        )
        return try await execute(.init(localPolicy: localPolicy, nvram: next))
    }

    /// Full-state variant for live adapters that read more than `boot-args`.
    /// Every unrelated NVRAM value is copied into the exact mutation so the
    /// apply and read-back phases cannot silently discard neighboring keys.
    func disable(localPolicy: Data, currentNVRAM: PommeNVRAMDelta) async throws -> PommeAMFITransactionReport {
        let currentBootArguments = currentNVRAM.value(for: "boot-args") ?? .absent
        var values = currentNVRAM.values
        values["boot-args"] = try .init(
            present: true,
            value: PommeBootArguments.addingOverride(to: currentBootArguments.value)
        )
        return try await execute(.init(localPolicy: localPolicy, nvram: .init(values: values)))
    }

    /// Enable AMFI by restoring the supplied snapshot exactly, including an
    /// absent `boot-args` key and every unrelated argument in its original
    /// order.
    func enable(using snapshot: PommeAMFISecuritySnapshot) async throws -> PommeAMFITransactionReport {
        guard snapshot.isWellFormed else { throw PommeRecoverySecurityError.invalidSnapshot }
        return try await execute(.init(localPolicy: snapshot.localPolicy, nvram: snapshot.nvram))
    }
}

/// Every security action is represented as a Recovery-session request. A
/// normal-boot integration can only receive the final-state request emitted
/// after teardown; it cannot execute SIP or AMFI work.
protocol PommeRecoverySecurityPort: Sendable {
    func execute(action: SIPAction, payload: Data) async throws -> Data
    func execute(action: AMFIAction, payload: Data) async throws -> Data
}

struct PommeRecoverySecurityRouter: PommeRecoverySecurityPort, Sendable {
    let session: PommeRecoverySession

    init(session: PommeRecoverySession) {
        self.session = session
    }

    func execute(action: SIPAction, payload: Data = Data()) async throws -> Data {
        try await execute(operation: PommeRecoveryOperation.sip(action), payload: payload)
    }

    func execute(action: AMFIAction, payload: Data = Data()) async throws -> Data {
        try await execute(operation: PommeRecoveryOperation.amfi(action), payload: payload)
    }

    private func execute(operation: PommeRecoveryOperation, payload: Data) async throws -> Data {
        // The operation is bound in the immutable request. Requiring the same
        // operation here prevents a caller from swapping SIP and AMFI after
        // authentication.
        let request = await session.requestSnapshot()
        let requestOperation = request.operation
        guard operation.wireName == requestOperation else {
            throw PommeRecoverySecurityError.operationRejected
        }
        do {
            return try await session.perform(payload: payload)
        } catch {
            throw PommeRecoverySecurityError.operationRejected
        }
    }
}
