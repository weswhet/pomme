import Foundation
import ArgumentParser
@preconcurrency import AppKit
import Security
// Virtualization reference types are confined to their documented serial VM queue below.
// Remove this when the SDK models these queue-confined APIs with Sendable-aware annotations.
@preconcurrency import Virtualization
import Darwin

enum MDMEnrollmentMethod: String, Sendable {
    case privateXPC = "private-xpc"

    static let defaultMethod: MDMEnrollmentMethod = .privateXPC

    static func parse(_ value: String, flag: String = "MDM transport method") throws -> MDMEnrollmentMethod {
        switch value {
        case "private-xpc", "privateXPC", "xpc":
            return .privateXPC
        case "system-settings", "systemSettings", "settings", "ui":
            throw RunnerError.invalidUICommand("\(flag) only supports private-xpc; System Settings UI enrollment is no longer supported.")
        default:
            throw RunnerError.invalidUICommand("\(flag) must be private-xpc.")
        }
    }
}

struct MDMEnrollmentRequest: Sendable {
    var method: MDMEnrollmentMethod
    var profilePath: String
    var guestPath: String?
}

/// The enrollment boundary accepts only a persistent normal-boot PommeAgent.
/// This description is deliberately small so control/runtime code can verify
/// it without importing MDM implementation details.
struct MDMEnrollmentAgentDescription: Equatable, Sendable {
    static let protocolName = "PommeAgentProtocol"
    static let protocolVersion = 1
    /// The durable normal-boot daemon identifies itself as `persistent` on
    /// the authenticated wire protocol.  Keep this distinct from the public
    /// status projection's normal boot-mode vocabulary.
    static let normalRole = "persistent"
    /// Every operation used by the private helper transaction is required on
    /// the same authenticated persistent agent.  Keeping this list closed
    /// prevents an older daemon from accepting only the semantic MDM label
    /// while lacking the file/process primitives used to stage and reap the
    /// helper.
    static let requiredCapabilities: Set<String> = [
        "agent.describe",
        "file.abort",
        "file.commit",
        "file.flush",
        "file.open",
        "file.write",
        "mdm.enrollment",
        "mdm.staging.cleanup",
        "mdm.staging.prepare",
        "process.signal",
        "process.start",
        "process.status",
    ]

    let connected: Bool
    /// True only when the status comes from the authenticated persistent-agent
    /// session, never from an unauthenticated control reply.
    let authenticated: Bool
    let role: String
    let protocolName: String
    let protocolVersion: Int
    /// Digest attested by the authenticated `agent.describe` response. This
    /// remains verification evidence and is never included in result output.
    let executableDigest: String?
    let capabilities: Set<String>

    init(
        connected: Bool,
        authenticated: Bool,
        role: String,
        protocolName: String,
        protocolVersion: Int,
        executableDigest: String?,
        capabilities: Set<String>
    ) {
        self.connected = connected
        self.authenticated = authenticated
        self.role = role
        self.protocolName = protocolName
        self.protocolVersion = protocolVersion
        self.executableDigest = executableDigest
        self.capabilities = capabilities
    }

    /// Parses only the exact response shape emitted by an authenticated
    /// `agent.describe` exchange.  The transport is the source of the
    /// authentication fact; this parser does not trust a status projection or
    /// a caller-supplied role/digest.
    static func fromAuthenticatedDescribe(_ value: JSONValue) throws -> Self {
        guard let object = value.objectValue,
              Set(object.keys).isSubset(of: ["role", "protocol", "version", "executableSHA256", "capabilities", "terminalSessionVersion"]),
              Set(["role", "protocol", "version", "executableSHA256", "capabilities"]).isSubset(of: Set(object.keys)),
              let role = object["role"]?.stringValue,
              let protocolName = object["protocol"]?.stringValue,
              case .integer(let version)? = object["version"],
              version >= 0, version <= Int64(Int.max),
              let digest = object["executableSHA256"]?.stringValue,
              case .array(let rawCapabilities)? = object["capabilities"],
              rawCapabilities.allSatisfy({ $0.stringValue != nil }) else {
            throw PommeMDMEnrollmentError.agentUnverified
        }
        let capabilities = Set(rawCapabilities.compactMap(\.stringValue))
        guard capabilities.count == rawCapabilities.count else {
            throw PommeMDMEnrollmentError.agentUnverified
        }
        return .init(
            connected: true,
            authenticated: true,
            role: role,
            protocolName: protocolName,
            protocolVersion: Int(version),
            executableDigest: digest,
            capabilities: capabilities
        )
    }
}

/// Runtime/control owns obtaining this evidence from the authenticated guest
/// connection. MDM owns only the closed acceptance policy below.
protocol MDMEnrollmentAgentProviding: Sendable {
    func enrollmentAgentDescription() throws -> MDMEnrollmentAgentDescription
}

/// The host-side MDM transaction talks to exactly one already-authenticated
/// normal-role PommeAgent.  The implementation is intentionally expressed as
/// typed operations instead of an arbitrary operation string so callers
/// cannot accidentally route enrollment through Recovery or a legacy
/// transport.
protocol PommeMDMEnrollmentAgentTransport: Sendable {
    /// This method must obtain and validate the response to the authenticated
    /// `agent.describe` request.  A status projection is not sufficient
    /// evidence because it cannot prove authentication or the executable
    /// digest.
    func authenticatedAgentDescription() async throws -> MDMEnrollmentAgentDescription

    /// Executes one of the closed MDM operations below over the authenticated
    /// PommeAgent session.  Implementations must map `operation.wireName` and
    /// `operation.payload` to the guest protocol without accepting additional
    /// fields.
    func perform(_ operation: PommeMDMEnrollmentAgentOperation) async throws -> JSONValue

    /// Transfers a host profile through the authenticated Pomme file path.
    /// This is deliberately separate from `perform`: profile bytes never
    /// become an operation payload or a diagnostic value.
    func transferProfile(from source: URL, to destination: String) async throws -> PommeMDMProfileTransferReceipt
}

/// A small closure-backed adapter keeps the production wiring explicit and
/// lets offline tests prove ordering without a VM, helper, or file transport.
struct PommeMDMEnrollmentAgentDependencies: PommeMDMEnrollmentAgentTransport {
    let describe: @Sendable () async throws -> MDMEnrollmentAgentDescription
    let performOperation: @Sendable (PommeMDMEnrollmentAgentOperation) async throws -> JSONValue
    let transfer: @Sendable (URL, String) async throws -> PommeMDMProfileTransferReceipt

    init(
        describe: @escaping @Sendable () async throws -> MDMEnrollmentAgentDescription,
        perform: @escaping @Sendable (PommeMDMEnrollmentAgentOperation) async throws -> JSONValue,
        transferProfile: @escaping @Sendable (URL, String) async throws -> PommeMDMProfileTransferReceipt
    ) {
        self.describe = describe
        performOperation = perform
        transfer = transferProfile
    }

    func authenticatedAgentDescription() async throws -> MDMEnrollmentAgentDescription {
        try await describe()
    }

    func perform(_ operation: PommeMDMEnrollmentAgentOperation) async throws -> JSONValue {
        try await performOperation(operation)
    }

    func transferProfile(from source: URL, to destination: String) async throws -> PommeMDMProfileTransferReceipt {
        try await transfer(source, destination)
    }
}

/// Adapter for the authenticated session already owned by the VM coordinator.
/// The profile transfer closure must use that same session's authenticated
/// file operations; no second channel is selected here.
struct PommeMDMEnrollmentAgentSessionAdapter: PommeMDMEnrollmentAgentTransport {
    let session: any PommeAgentSessionProtocol
    let transfer: @Sendable (URL, String) async throws -> PommeMDMProfileTransferReceipt

    init(
        session: any PommeAgentSessionProtocol,
        transferProfile: @escaping @Sendable (URL, String) async throws -> PommeMDMProfileTransferReceipt
    ) {
        self.session = session
        transfer = transferProfile
    }

    func authenticatedAgentDescription() async throws -> MDMEnrollmentAgentDescription {
        do {
            let value = try await session.perform(operation: "agent.describe", payload: nil)
            return try MDMEnrollmentAgentDescription.fromAuthenticatedDescribe(value)
        } catch let error as PommeMDMEnrollmentError {
            throw error
        } catch {
            throw PommeMDMEnrollmentError.agentUnavailable
        }
    }

    func perform(_ operation: PommeMDMEnrollmentAgentOperation) async throws -> JSONValue {
        do {
            return try await session.perform(
                operation: operation.wireName,
                payload: try operation.payload()
            )
        } catch {
            throw error
        }
    }

    func transferProfile(from source: URL, to destination: String) async throws -> PommeMDMProfileTransferReceipt {
        try await transfer(source, destination)
    }
}

/// Operations accepted by the host MDM transaction.  The staging directory
/// is fixed by the guest contract; callers can select only the direct-child
/// profile name, never an arbitrary directory or cleanup target.
enum PommeMDMEnrollmentAgentOperation: Equatable, Sendable {
    case prepareStaging
    case enroll(profilePath: String, timeout: TimeInterval)
    case approve(profileIdentifier: String, timeout: TimeInterval)
    case cleanup(profilePath: String)

    var wireName: String {
        switch self {
        case .prepareStaging: "mdm.staging.prepare"
        case .enroll, .approve: "mdm.enrollment"
        case .cleanup: "mdm.staging.cleanup"
        }
    }

    func payload() throws -> JSONValue {
        switch self {
        case .prepareStaging:
            return .object([:])
        case let .enroll(profilePath, timeout):
            try Self.validateProfilePath(profilePath)
            guard timeout.isFinite, timeout >= 1, timeout <= 300 else {
                throw PommeMDMEnrollmentError.invalidRequest
            }
            return .object([
                "action": .string("enroll"),
                "profilePath": .string(profilePath),
                "timeout": .number(timeout)
            ])
        case let .approve(profileIdentifier, timeout):
            try Self.validateProfileIdentifier(profileIdentifier)
            guard timeout.isFinite, timeout >= 1, timeout <= 300 else {
                throw PommeMDMEnrollmentError.invalidRequest
            }
            return .object([
                "action": .string("approve"),
                "profileIdentifier": .string(profileIdentifier),
                "timeout": .number(timeout)
            ])
        case let .cleanup(profilePath):
            try Self.validateCleanupPath(profilePath)
            return .object(["profilePath": .string(profilePath)])
        }
    }

    private static func validateProfilePath(_ path: String) throws {
        guard (try? MDMProfileStaging.destination(requestedPath: path)) == path else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
    }

    private static func validateCleanupPath(_ path: String) throws {
        if (try? MDMProfileStaging.destination(requestedPath: path)) == path
            || PommeMDMTemporaryHelperWorkspace.isArtifactPath(path) {
            return
        }
        throw PommeMDMEnrollmentError.invalidRequest
    }

    private static func validateProfileIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty,
              identifier.utf8.count <= 255,
              !identifier.contains("\0"),
              identifier.trimmingCharacters(in: .whitespacesAndNewlines) == identifier else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
    }
}

/// The file transport returns only transfer proof.  It never returns the
/// profile bytes, profile path, or a retry token to the public result.
struct PommeMDMProfileTransferReceipt: Equatable, Sendable {
    static let maximumBytes = 16 * 1024 * 1024

    let destination: String
    let bytes: Int
    let sha256: String

    init(destination: String, bytes: Int, sha256: String) throws {
        guard (try? MDMProfileStaging.destination(requestedPath: destination)) == destination,
              bytes > 0,
              bytes <= Self.maximumBytes,
              sha256.count == 64,
              sha256 == sha256.lowercased(),
              sha256.allSatisfy(\.isHexDigit) else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }
        self.destination = destination
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// Typed response validation for the three closed guest operations.  Extra
/// keys are rejected so private diagnostics and accidental credentials cannot
/// cross the agent boundary.
enum PommeMDMEnrollmentAgentResponse {
    static func requireStagingReady(_ value: JSONValue) throws {
        guard let object = value.objectValue,
              Set(object.keys) == ["ready"],
              isTrue(object["ready"]) else {
            throw PommeMDMEnrollmentError.stagingPreparationFailed
        }
    }

    static func enrollment(_ value: JSONValue) throws -> (completed: Bool, profileIdentifier: String) {
        guard let object = value.objectValue,
              Set(object.keys) == ["completed", "profileIdentifier"],
              isTrue(object["completed"]),
              let identifier = object["profileIdentifier"]?.stringValue,
              !identifier.isEmpty,
              identifier.utf8.count <= 255,
              !identifier.contains("\0"),
              identifier.trimmingCharacters(in: .whitespacesAndNewlines) == identifier else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        return (true, identifier)
    }

    static func approval(_ value: JSONValue) throws {
        guard let object = value.objectValue,
              Set(object.keys) == ["completed"],
              isTrue(object["completed"]) else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
    }

    static func requireCleanup(_ value: JSONValue) throws {
        guard let object = value.objectValue,
              Set(object.keys) == ["removed"],
              isTrue(object["removed"]) else {
            throw PommeMDMEnrollmentError.cleanupFailed
        }
    }

    private static func isTrue(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        guard case .bool(true) = value else { return false }
        return true
    }
}

/// SIP and AMFI implementations use different opaque snapshot formats.  The
/// transaction keeps those bytes in memory only and delegates interpretation
/// and restoration to the injected security port.  The run-state component is
/// typed so a failed MDM operation cannot silently lose pause/boot intent.
struct PommeMDMEnrollmentStateBaseline: Equatable, Sendable {
    let sip: Data
    let amfi: Data
    let runState: VMRunStateSnapshot

    var isWellFormed: Bool { !sip.isEmpty && !amfi.isEmpty }
}

protocol PommeMDMEnrollmentStatePort: Sendable {
    func captureBaseline() async throws -> PommeMDMEnrollmentStateBaseline
    func restoreBaseline(_ baseline: PommeMDMEnrollmentStateBaseline) async throws
    func verifyBaseline(_ baseline: PommeMDMEnrollmentStateBaseline) async throws -> Bool
}

struct PommeMDMEnrollmentStateDependencies: PommeMDMEnrollmentStatePort {
    let capture: @Sendable () async throws -> PommeMDMEnrollmentStateBaseline
    let restore: @Sendable (PommeMDMEnrollmentStateBaseline) async throws -> Void
    let verify: @Sendable (PommeMDMEnrollmentStateBaseline) async throws -> Bool

    init(
        capture: @escaping @Sendable () async throws -> PommeMDMEnrollmentStateBaseline,
        restore: @escaping @Sendable (PommeMDMEnrollmentStateBaseline) async throws -> Void,
        verify: @escaping @Sendable (PommeMDMEnrollmentStateBaseline) async throws -> Bool
    ) {
        self.capture = capture
        self.restore = restore
        self.verify = verify
    }

    func captureBaseline() async throws -> PommeMDMEnrollmentStateBaseline { try await capture() }
    func restoreBaseline(_ baseline: PommeMDMEnrollmentStateBaseline) async throws { try await restore(baseline) }
    func verifyBaseline(_ baseline: PommeMDMEnrollmentStateBaseline) async throws -> Bool { try await verify(baseline) }
}

enum PommeMDMEnrollmentError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest
    case invalidProfile
    case invalidTransfer
    case agentUnavailable
    case agentUnverified
    case baselineCaptureFailed
    case stagingPreparationFailed
    case transferFailed
    case enrollmentFailed
    /// The helper may have committed the profile before its reply was lost.
    /// Callers must inspect the guest enrollment state before retrying.
    case enrollmentOutcomeUnknown
    case evidenceUnavailable
    /// A launched helper process could not be proven reaped. Its artifacts
    /// must remain in place until an operator verifies termination.
    case helperProcessTerminationUnproven
    case cleanupFailed
    case restorationFailed

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The MDM enrollment request is invalid."
        case .invalidProfile: "The MDM profile is unavailable."
        case .invalidTransfer: "The MDM profile transfer could not be verified."
        case .agentUnavailable: "The persistent PommeAgent is unavailable."
        case .agentUnverified: "The persistent PommeAgent could not be verified for MDM enrollment."
        case .baselineCaptureFailed: "The SIP, AMFI, and VM baseline could not be captured."
        case .stagingPreparationFailed: "The private MDM staging directory could not be prepared."
        case .transferFailed: "The MDM profile transfer failed."
        case .enrollmentFailed: "The PommeAgent MDM enrollment operation failed."
        case .enrollmentOutcomeUnknown: "The MDM enrollment outcome is unknown; verify the guest profile state before retrying."
        case .evidenceUnavailable: "Independent MDM enrollment evidence is unavailable or invalid."
        case .helperProcessTerminationUnproven: "The MDM helper process could not be proven terminated; staged artifacts were retained. Verify process termination and guest enrollment state before retrying."
        case .cleanupFailed: "The private MDM staging file could not be cleaned up. Enrollment may have completed; verify the guest profile state before retrying."
        case .restorationFailed: "The SIP, AMFI, and VM baseline could not be restored and verified. Enrollment may have completed; verify security and guest profile state before retrying."
        }
    }
}

struct PommeMDMEnrollmentTransactionResult: Equatable, Sendable {
    let profileIdentifier: String
    let transferredBytes: Int
    let transferredSHA256: String
    let agentCapabilities: [String]
}

/// Recovery/security owns the concrete state transition. The MDM workflow
/// requires this transaction to restore SIP, AMFI, and the prior run state on
/// both success and failure.
protocol MDMEnrollmentStateRestoring: Sendable {
    func prepareForMDMEnrollment() throws
    func restoreAfterMDMEnrollment() throws
}

enum MDMEnrollmentStateTransaction {
    static func execute<Output>(
        using restorer: some MDMEnrollmentStateRestoring,
        operation: () throws -> Output
    ) throws -> Output {
        do {
            try restorer.prepareForMDMEnrollment()
        } catch {
            do {
                try restorer.restoreAfterMDMEnrollment()
            } catch {
                throw MDMEnrollmentRestorationError.operationAndRestorationFailed
            }
            throw error
        }

        let output: Output
        do {
            output = try operation()
        } catch {
            do {
                try restorer.restoreAfterMDMEnrollment()
            } catch {
                throw MDMEnrollmentRestorationError.operationAndRestorationFailed
            }
            throw error
        }

        do {
            try restorer.restoreAfterMDMEnrollment()
        } catch {
            throw MDMEnrollmentRestorationError.operationAndRestorationFailed
        }
        return output
    }
}

enum MDMEnrollmentRestorationError: LocalizedError, Sendable {
    case operationAndRestorationFailed

    var errorDescription: String? {
        "MDM enrollment failed and required state restoration could not be confirmed."
    }
}

enum MDMEnrollmentRedaction {
    /// Do not return profile content, private paths, credentials, or raw guest
    /// diagnostics from an enrollment error.
    static func errorMessage(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("credential") || text.contains("password") || text.contains("secret") || text.contains("token") {
            return "MDM enrollment failed; sensitive details were redacted."
        }
        return "MDM enrollment failed."
    }
}
