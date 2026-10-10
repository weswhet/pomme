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
            throw PommeMDMEnrollmentError.wrapping(.agentUnavailable, error)
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

enum PommeMDMEnrollmentError: PommeDescribedError, Equatable, Sendable {
    case invalidRequest
    case invalidProfile
    case invalidTransfer
    case agentUnavailable
    case agentUnverified
    /// The agent isn't an authenticated, attested persistent agent on
    /// protocol v1.
    case agentNotAttested
    /// The agent isn't the signed executable recorded for the VM.
    case agentExecutableMismatch
    /// The agent lacks the enrollment or maintenance capability.
    case agentCapabilitiesMissing
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
    /// A step failed because of `cause`. Equality ignores the cause, so
    /// `error == .transferFailed` holds whether or not a cause is attached.
    indirect case failed(PommeMDMEnrollmentError, cause: PommeErrorReport)

    /// Wraps `error` as the cause of `kind`. An error that is already this
    /// kind is returned unchanged, so a step doesn't repeat its own message.
    static func wrapping(_ kind: Self, _ error: any Error) -> Self {
        if let existing = error as? Self, existing == kind { return existing }
        return .failed(kind.kind, cause: PommeErrorReport(error))
    }

    /// The failure without any attached cause.
    var kind: Self {
        if case .failed(let kind, _) = self { return kind.kind }
        return self
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        String(describing: lhs.kind) == String(describing: rhs.kind)
    }

    var underlying: (any Error)? {
        if case .failed(_, let cause) = self { return cause }
        return nil
    }

    var code: PommeErrorCode {
        switch kind {
        case .invalidRequest: .invalidRequest
        case .invalidProfile: .mdmProfileUnreadable
        case .invalidTransfer, .transferFailed: .mdmProfileTransferFailed
        case .agentUnavailable: .guestAgentUnavailable
        case .agentUnverified, .agentNotAttested, .agentExecutableMismatch, .agentCapabilitiesMissing: .mdmAgentUnverified
        case .baselineCaptureFailed: .mdmSecurityBaselineUnavailable
        case .stagingPreparationFailed: .mdmStagingFailed
        case .enrollmentFailed: .mdmEnrollmentFailed
        case .enrollmentOutcomeUnknown: .mdmEnrollmentOutcomeUnknown
        case .evidenceUnavailable: .mdmEvidenceUnavailable
        case .helperProcessTerminationUnproven: .mdmHelperNotStopped
        case .cleanupFailed: .mdmCleanupFailed
        case .restorationFailed: .mdmRestorationFailed
        case .failed: .internalError
        }
    }

    /// What happened, as one sentence without its final period.
    private var summary: String {
        switch kind {
        case .invalidRequest:
            "The MDM enrollment request has a value that isn't valid, such as the timeout or the guest staging path"
        case .invalidProfile:
            "Pomme couldn't read the MDM enrollment profile"
        case .invalidTransfer:
            "Pomme couldn't verify the copy of the MDM profile in the VM"
        case .agentUnavailable:
            "The VM's guest agent isn't available for MDM enrollment"
        case .agentUnverified:
            "Pomme couldn't verify the VM's guest agent for MDM enrollment"
        case .agentNotAttested:
            "MDM enrollment needs an authenticated, attested PommeAgent that uses protocol version 1, and the VM's agent isn't one"
        case .agentExecutableMismatch:
            "The VM's guest agent isn't the signed PommeAgent executable that Pomme recorded for the VM"
        case .agentCapabilitiesMissing:
            "The VM's guest agent doesn't have the MDM enrollment and maintenance capabilities"
        case .baselineCaptureFailed:
            "Pomme couldn't read the VM's SIP, AMFI, and run state before MDM enrollment"
        case .stagingPreparationFailed:
            "Pomme couldn't prepare the private MDM staging directory in the VM"
        case .transferFailed:
            "Pomme couldn't copy the MDM profile to the VM"
        case .enrollmentFailed:
            "MDM enrollment failed in the VM"
        case .enrollmentOutcomeUnknown:
            "Pomme can't tell whether the VM installed the MDM profile"
        case .evidenceUnavailable:
            "Pomme couldn't verify the MDM enrollment from the VM's profile and enrollment state"
        case .helperProcessTerminationUnproven:
            "Pomme couldn't confirm that the MDM enrollment helper stopped, so it kept the staged files in the VM"
        case .cleanupFailed:
            "Pomme couldn't remove the staged MDM files from the VM, and the enrollment might have finished"
        case .restorationFailed:
            "Pomme couldn't restore and verify the VM's SIP, AMFI, and run state after MDM enrollment, and the enrollment might have finished"
        case .failed:
            "MDM enrollment failed"
        }
    }

    var errorDescription: String? {
        if case .failed(_, let cause) = self {
            return "\(summary): \(PommeErrorDescriber.clause(for: cause))."
        }
        return summary + "."
    }

    var recoverySuggestion: String? {
        switch kind {
        case .invalidRequest:
            "Check the `--timeout` and `--guest-path` values, then run `pomme mdm` again."
        case .invalidProfile:
            "Check that `--profile` names a regular `.mobileconfig` file that you can read, not a link."
        case .agentUnavailable:
            "Run `pomme agent status NAME` to check the agent, then repeat the same `pomme mdm` command."
        case .agentUnverified, .agentNotAttested, .agentExecutableMismatch, .agentCapabilitiesMissing:
            "Run `pomme agent update NAME` to install this build's agent, then repeat the same `pomme mdm` command."
        case .baselineCaptureFailed:
            "Run `pomme sip status NAME` and `pomme amfi status NAME` to check the settings, then repeat the same `pomme mdm` command."
        case .stagingPreparationFailed, .invalidTransfer, .transferFailed, .enrollmentFailed:
            "Repeat the same `pomme mdm` command to retry. Add `--debug --format json` to see the failure stage."
        case .enrollmentOutcomeUnknown, .evidenceUnavailable:
            "Repeat the same `pomme mdm` command; Pomme checks the VM's enrollment before it installs anything again."
        case .helperProcessTerminationUnproven:
            "Check that no helper process remains with `pomme exec NAME -- /bin/ps -ax`, then repeat the same `pomme mdm` command."
        case .cleanupFailed, .restorationFailed:
            "Repeat the same `pomme mdm` command to finish cleanup and restoration."
        case .failed:
            nil
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
                throw MDMEnrollmentRestorationError.operationAndRestorationFailed(cause: PommeErrorReport(error))
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
                throw MDMEnrollmentRestorationError.operationAndRestorationFailed(cause: PommeErrorReport(error))
            }
            throw error
        }

        do {
            try restorer.restoreAfterMDMEnrollment()
        } catch {
            throw MDMEnrollmentRestorationError.operationAndRestorationFailed(cause: PommeErrorReport(error))
        }
        return output
    }
}

/// The VM's state couldn't be restored around MDM enrollment work. It keeps
/// the restoration failure as its cause, never the enrollment's own error.
enum MDMEnrollmentRestorationError: PommeDescribedError, Sendable {
    case operationAndRestorationFailed(cause: PommeErrorReport?)

    var code: PommeErrorCode { .mdmRestorationFailed }

    var underlying: (any Error)? {
        switch self {
        case .operationAndRestorationFailed(let cause): cause
        }
    }

    var errorDescription: String? {
        switch self {
        case .operationAndRestorationFailed(let cause?):
            "Pomme couldn't confirm that it restored the VM's state around MDM enrollment: \(PommeErrorDescriber.clause(for: cause))."
        case .operationAndRestorationFailed(nil):
            "Pomme couldn't confirm that it restored the VM's state around MDM enrollment."
        }
    }

    var recoverySuggestion: String? {
        "Repeat the same `pomme mdm` command to resume restoration."
    }
}

enum MDMEnrollmentRedaction {
    /// Do not return profile content, private paths, credentials, or raw guest
    /// diagnostics from an enrollment error. The message names only the
    /// error's stable code, never its text.
    static func errorMessage(_ error: Error) -> String {
        "MDM enrollment failed with error code \(PommeErrorReport(codesOnly: error).code)."
    }
}
