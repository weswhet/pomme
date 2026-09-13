import CryptoKit
import Foundation
import Security

/// The two listener numbers reserved for a temporary Recovery session.
/// Keeping this list closed prevents a caller from turning a Recovery request
/// into an arbitrary guest listener.
enum PommeRecoveryListenerPort: UInt32, Codable, CaseIterable, Sendable {
    case bootstrap = 505_052
    case operation = 505_053
}

enum PommeRecoveryOperation: Equatable, Sendable {
    case installAgent
    case terminalSession
    case sip(SIPAction)
    case amfi(AMFIAction)

    var wireName: String {
        switch self {
        case .installAgent:
            "agent.install"
        case .terminalSession:
            "terminal.session"
        case .sip(let action):
            "sip.\(action.rawValue)"
        case .amfi(let action):
            "amfi.\(action.rawValue)"
        }
    }

    init?(wireName: String) {
        switch wireName {
        case "agent.install":
            self = .installAgent
        case "terminal.session":
            self = .terminalSession
        case "sip.status":
            self = .sip(.status)
        case "sip.disable":
            self = .sip(.disable)
        case "sip.enable":
            self = .sip(.enable)
        case "amfi.status":
            self = .amfi(.status)
        case "amfi.disable":
            self = .amfi(.disable)
        case "amfi.enable":
            self = .amfi(.enable)
        default:
            return nil
        }
    }

    var listenerPort: PommeRecoveryListenerPort {
        switch self {
        case .installAgent:
            .bootstrap
        case .terminalSession, .sip, .amfi:
            .operation
        }
    }
}

enum PommeRecoverySessionError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest
    case expiredCredential
    case invalidCredential
    case invalidProof
    case replayedCredential
    case requestMismatch
    case notPrepared
    case unauthenticated
    case invalidLifecycle
    case observationTimedOut
    case terminalProofFailed
    case rootEvidenceRejected
    case preparationFailed
    case guestOperationFailed
    case cleanupFailed
    case finalStateUnverified

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Recovery request was rejected."
        case .expiredCredential:
            "Recovery credential has expired."
        case .invalidCredential:
            "Recovery credential was rejected."
        case .invalidProof:
            "Recovery authentication proof was rejected."
        case .replayedCredential:
            "Recovery credential has already been consumed."
        case .requestMismatch:
            "Recovery request binding did not match the active VM."
        case .notPrepared:
            "Recovery session has not prepared its request-bound workspace."
        case .unauthenticated:
            "Recovery operation requires an authenticated session."
        case .invalidLifecycle:
            "Recovery session lifecycle transition was rejected."
        case .observationTimedOut:
            "Recovery display observation timed out."
        case .terminalProofFailed:
            "Recovery Terminal capability proof failed."
        case .rootEvidenceRejected:
            "Recovery workspace evidence was incomplete."
        case .preparationFailed:
            "Recovery session preparation failed."
        case .guestOperationFailed:
            "Recovery operation did not complete."
        case .cleanupFailed:
            "Recovery cleanup could not be proven complete."
        case .finalStateUnverified:
            "The requested VM final state could not be verified."
        }
    }
}

/// A request is the sole authority for which Recovery operation may be
/// admitted. It contains no credential material; only a digest of the
/// one-shot credential is retained.
struct PommeRecoverySessionRequest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let requestID: UUID
    let vmUUID: UUID
    let operation: String
    let listenerPort: UInt32
    let issuedAt: Date
    let expiresAt: Date
    let executableSHA256: String
    let payloadSHA256: String
    let requestedFinalState: String
    let credentialID: UUID
    let credentialSHA256: String

    init(
        requestID: UUID = UUID(),
        vmUUID: UUID,
        operation: PommeRecoveryOperation,
        issuedAt: Date = Date(),
        expiresAt: Date,
        executableSHA256: String,
        payloadSHA256: String = PommeRecoveryCrypto.emptySHA256,
        requestedFinalState: VMFinalState = .stopped,
        credential: PommeRecoveryCredential
    ) throws {
        try self.init(
            requestID: requestID,
            vmUUID: vmUUID,
            operation: operation.wireName,
            listenerPort: operation.listenerPort.rawValue,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            executableSHA256: executableSHA256,
            payloadSHA256: payloadSHA256,
            requestedFinalState: requestedFinalState.rawValue,
            credentialID: credential.id,
            credentialSHA256: credential.sha256
        )
    }

    init(
        requestID: UUID = UUID(),
        vmUUID: UUID,
        operation: String,
        listenerPort: UInt32,
        issuedAt: Date = Date(),
        expiresAt: Date,
        executableSHA256: String,
        payloadSHA256: String = PommeRecoveryCrypto.emptySHA256,
        requestedFinalState: String = VMFinalState.stopped.rawValue,
        credentialID: UUID,
        credentialSHA256: String
    ) throws {
        self.schemaVersion = Self.schemaVersion
        self.requestID = requestID
        self.vmUUID = vmUUID
        self.operation = operation
        self.listenerPort = listenerPort
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.executableSHA256 = executableSHA256.lowercased()
        self.payloadSHA256 = payloadSHA256.lowercased()
        self.requestedFinalState = requestedFinalState
        self.credentialID = credentialID
        self.credentialSHA256 = credentialSHA256.lowercased()
        guard isWellFormed else { throw PommeRecoverySessionError.invalidRequest }
    }

    var listener: PommeRecoveryListenerPort? {
        PommeRecoveryListenerPort(rawValue: listenerPort)
    }

    var isWellFormed: Bool {
        schemaVersion == Self.schemaVersion
            && !operation.isEmpty
            && operation.utf8.count <= 128
            && operation.unicodeScalars.allSatisfy {
                let value = $0.value
                return (0x41...0x5a).contains(value)
                    || (0x61...0x7a).contains(value)
                    || (0x30...0x39).contains(value)
                    || value == 0x2e
                    || value == 0x2d
            }
            && listener != nil
            && PommeRecoveryOperation(wireName: operation)?.listenerPort.rawValue == listenerPort
            && expiresAt > issuedAt
            && expiresAt.timeIntervalSince(issuedAt) <= 15 * 60
            && Self.isSHA256(executableSHA256)
            && Self.isSHA256(payloadSHA256)
            && VMFinalState(rawValue: requestedFinalState) != nil
            && Self.isSHA256(credentialSHA256)
    }

    func validate(now: Date) throws {
        guard isWellFormed else { throw PommeRecoverySessionError.invalidRequest }
        guard now >= issuedAt else { throw PommeRecoverySessionError.invalidRequest }
        guard now < expiresAt else { throw PommeRecoverySessionError.expiredCredential }
    }

    /// Canonical bytes covered by the admission HMAC. Date precision is
    /// explicit so independently encoded requests cannot authenticate under a
    /// different textual representation.
    func authenticationContext(challenge: String) -> Data {
        let fields = [
            "PommeRecoverySession/1",
            requestID.uuidString.lowercased(),
            vmUUID.uuidString.lowercased(),
            operation,
            String(listenerPort),
            Self.microseconds(issuedAt),
            Self.microseconds(expiresAt),
            executableSHA256,
            payloadSHA256,
            requestedFinalState,
            credentialID.uuidString.lowercased(),
            credentialSHA256,
            challenge
        ]
        return Data(fields.joined(separator: "\u{1f}").utf8)
    }

    private static func microseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000_000).rounded()))
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

/// Secret material is deliberately not Codable and never appears in session
/// evidence or diagnostics. The only public use is creating an HMAC proof.
struct PommeRecoveryCredential: Equatable, Sendable {
    let id: UUID
    private let secret: Data
    let expiresAt: Date

    init(id: UUID = UUID(), secret: Data, expiresAt: Date) throws {
        guard secret.count >= 32, secret.count <= 64 else {
            throw PommeRecoverySessionError.invalidCredential
        }
        self.id = id
        self.secret = secret
        self.expiresAt = expiresAt
    }

    init(id: UUID = UUID(), hexadecimal: String, expiresAt: Date) throws {
        let normalized = hexadecimal.lowercased()
        guard normalized.utf8.count.isMultiple(of: 2),
              let data = Data(hexadecimal: normalized)
        else { throw PommeRecoverySessionError.invalidCredential }
        try self.init(id: id, secret: data, expiresAt: expiresAt)
    }

    var sha256: String {
        PommeRecoveryCrypto.hex(SHA256.hash(data: secret))
    }

    func proof(for request: PommeRecoverySessionRequest, challenge: String) -> String {
        PommeRecoveryCrypto.hex(
            HMAC<SHA256>.authenticationCode(
                for: request.authenticationContext(challenge: challenge),
                using: SymmetricKey(data: secret)
            )
        )
    }

    func matches(request: PommeRecoverySessionRequest) -> Bool {
        id == request.credentialID && sha256 == request.credentialSHA256
    }

    /// Called only while constructing the request-bound 0400 staging file.
    /// The daemon accepts a canonical 256-bit hexadecimal token; returning
    /// bytes in that exact encoding avoids ever converting the credential in
    /// a launcher argument, diagnostic, or Codable request model.
    func hexadecimalDataForStaging() -> Data {
        Data(PommeRecoveryCrypto.hex(secret).utf8)
    }
}

/// The registry makes one-shot semantics apply across separate session
/// objects, not only across calls on one actor. It is intentionally tiny and
/// stores identifiers rather than credentials.
actor PommeRecoveryCredentialRegistry {
    static let shared = PommeRecoveryCredentialRegistry()
    private var claimed: Set<UUID> = []

    func claim(_ id: UUID) -> Bool {
        claimed.insert(id).inserted
    }

    func resetForTesting() {
        claimed.removeAll(keepingCapacity: false)
    }
}

enum PommeRecoveryCredentialIssuer {
    static func issue(
        lifetime: TimeInterval = 120,
        now: Date = Date(),
        registry: PommeRecoveryCredentialRegistry = .shared
    ) async throws -> PommeRecoveryCredential {
        guard lifetime > 0, lifetime <= 15 * 60 else {
            throw PommeRecoverySessionError.invalidCredential
        }
        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw PommeRecoverySessionError.invalidCredential
        }
        let credential = try PommeRecoveryCredential(
            secret: bytes,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        // A claim is made only on successful authentication. Touching the
        // actor here keeps the API explicit for callers that want a fresh
        // registry in an offline test without retaining any secret.
        _ = registry
        return credential
    }
}

enum PommeRecoveryCrypto {
    static let emptySHA256 = hex(SHA256.hash(data: Data()))

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func verify(
        proof: String,
        credential: PommeRecoveryCredential,
        request: PommeRecoverySessionRequest,
        challenge: String
    ) -> Bool {
        let expected = credential.proof(for: request, challenge: challenge)
        return constantTimeEqual(Data(proof.lowercased().utf8), Data(expected.utf8))
    }

    static func hex<H: Sequence>(_ bytes: H) -> String where H.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(left, right) { difference |= a ^ b }
        return difference == 0
    }
}

private extension Data {
    init?(hexadecimal: String) {
        guard hexadecimal.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hexadecimal.utf8.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

struct PommeRecoveryRootEvidence: Equatable, Sendable {
    let requestID: UUID
    let vmUUID: UUID
    let listenerPort: UInt32
    let shareReadOnly: Bool
    let executableSignatureVerified: Bool
    let executableDigestVerified: Bool
    let inodeVerified: Bool
    let modeVerified: Bool
    let launcherInstalled: Bool
    let listenerReady: Bool

    var isAcceptable: Bool {
        shareReadOnly
            && executableSignatureVerified
            && executableDigestVerified
            && inodeVerified
            && modeVerified
            && launcherInstalled
            && listenerReady
    }
}

struct PommeRecoveryCleanupEvidence: Equatable, Sendable {
    let shareRemoved: Bool
    let launcherRemoved: Bool
    let credentialRemoved: Bool
    let listenerClosed: Bool
    let sensitiveFramesCleared: Bool
    let unknownStateRejected: Bool

    var isComplete: Bool {
        shareRemoved
            && launcherRemoved
            && credentialRemoved
            && listenerClosed
            && sensitiveFramesCleared
            && unknownStateRejected
    }
}

protocol PommeRecoveryRootPort: Sendable {
    func prepare(request: PommeRecoverySessionRequest) async throws -> PommeRecoveryRootEvidence
    func cleanup(request: PommeRecoverySessionRequest) async throws -> PommeRecoveryCleanupEvidence
}

enum PommeRecoveryRunState: Equatable, Sendable {
    case stopped
    case running(BootMode)
    case paused(previousBootMode: BootMode)
}

protocol PommeRecoveryVMPort: Sendable {
    func captureState() async throws -> PommeRecoveryRunState
    /// This is the only VM transition exposed by the session. Security
    /// operations never ask this port to boot a mode as part of their work.
    func requestFinalState(_ state: VMFinalState) async throws
    func proveFinalState(_ state: VMFinalState) async throws -> Bool
}

protocol PommeRecoveryGuestPort: Sendable {
    /// `payload` is an opaque bounded value owned by the authenticated
    /// Recovery operation. This port does not expose a second guest protocol
    /// or an execution-channel selector.
    func perform(operation: String, requestID: UUID, payload: Data) async throws -> Data
    func close() async
}

struct PommeRecoverySessionEvidence: Equatable, Sendable {
    let requestID: UUID
    let vmUUID: UUID
    let listenerPort: UInt32
    let authenticated: Bool
    let requestBound: Bool
    let credentialConsumed: Bool
    let lifecycle: PommeRecoverySessionLifecycle
}

enum PommeRecoverySessionLifecycle: String, Codable, Equatable, Sendable {
    case created
    case prepared
    case authenticated
    case operating
    case cleanup
    case cleaned
    case finalized
    case failed
}

/// Actor-owned orchestration for every authenticated Recovery mutation.
/// Root, VM, and guest integration are deliberately injected through narrow
/// ports so tests cannot accidentally use a normal-boot path.
actor PommeRecoverySession {
    let request: PommeRecoverySessionRequest

    private let credential: PommeRecoveryCredential
    private let root: any PommeRecoveryRootPort
    private let vm: any PommeRecoveryVMPort
    private let guest: any PommeRecoveryGuestPort
    private let registry: PommeRecoveryCredentialRegistry
    private let now: @Sendable () -> Date

    private(set) var lifecycle: PommeRecoverySessionLifecycle = .created
    private var rootEvidence: PommeRecoveryRootEvidence?
    private var vmState: PommeRecoveryRunState?
    private var challengeValue: String?
    private var authenticationAttempted = false
    private var authenticated = false
    private var credentialConsumed = false
    private var cleaned = false
    private var preparationAttempted = false
    private var operationAttempted = false

    init(
        request: PommeRecoverySessionRequest,
        credential: PommeRecoveryCredential,
        root: any PommeRecoveryRootPort,
        vm: any PommeRecoveryVMPort,
        guest: any PommeRecoveryGuestPort,
        registry: PommeRecoveryCredentialRegistry = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard request.isWellFormed,
              credential.matches(request: request)
        else { throw PommeRecoverySessionError.requestMismatch }
        self.request = request
        self.credential = credential
        self.root = root
        self.vm = vm
        self.guest = guest
        self.registry = registry
        self.now = now
    }

    /// Actor-isolated accessor for adapters that need to inspect the
    /// immutable binding before starting a transaction.
    func requestSnapshot() -> PommeRecoverySessionRequest { request }

    func evidence() -> PommeRecoverySessionEvidence {
        .init(
            requestID: request.requestID,
            vmUUID: request.vmUUID,
            listenerPort: request.listenerPort,
            authenticated: authenticated,
            requestBound: rootEvidence?.requestID == request.requestID
                && rootEvidence?.vmUUID == request.vmUUID,
            credentialConsumed: credentialConsumed,
            lifecycle: lifecycle
        )
    }

    func prepare() async throws -> PommeRecoverySessionEvidence {
        guard lifecycle == .created else { throw PommeRecoverySessionError.invalidLifecycle }
        preparationAttempted = true
        do {
            try request.validate(now: now())
            guard credential.expiresAt >= request.expiresAt else {
                throw PommeRecoverySessionError.invalidCredential
            }
            let state = try await vm.captureState()
            // Preserve the independently captured lifecycle state before any
            // Recovery preparation effect. Preparation may fail after it has
            // started and then cleaned the VM; `.previous` must still resolve
            // to the exact pre-request state and surface the primary failure.
            vmState = state
            let rootEvidenceValue = try await root.prepare(request: request)
            guard rootEvidenceValue.requestID == request.requestID,
                  rootEvidenceValue.vmUUID == request.vmUUID,
                  rootEvidenceValue.listenerPort == request.listenerPort,
                  rootEvidenceValue.isAcceptable
            else {
                throw PommeRecoverySessionError.rootEvidenceRejected
            }
            rootEvidence = rootEvidenceValue
            lifecycle = .prepared
            return evidence()
        } catch let error as PommeRecoverySessionError {
            lifecycle = .failed
            throw error
        } catch let error as PommeRecoveryRuntimeError {
            lifecycle = .failed
            throw error
        } catch is CancellationError {
            lifecycle = .failed
            throw CancellationError()
        } catch {
            lifecycle = .failed
            throw PommeRecoverySessionError.preparationFailed
        }
    }

    func challenge() throws -> String {
        guard lifecycle == .prepared else { throw PommeRecoverySessionError.notPrepared }
        if let challengeValue { return challengeValue }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw PommeRecoverySessionError.invalidProof }
        let challenge = PommeRecoveryCrypto.hex(bytes)
        challengeValue = challenge
        return challenge
    }

    func authenticate(challenge: String, proof: String) async throws -> PommeRecoverySessionEvidence {
        guard !authenticationAttempted else { throw PommeRecoverySessionError.replayedCredential }
        guard lifecycle == .prepared else { throw PommeRecoverySessionError.notPrepared }
        authenticationAttempted = true
        try request.validate(now: now())
        guard challenge.utf8.count <= 128,
              proof.utf8.count == 64,
              proof.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              })
        else { throw PommeRecoverySessionError.invalidProof }
        guard credential.expiresAt >= request.expiresAt,
              credential.matches(request: request),
              challenge == challengeValue,
              PommeRecoveryCrypto.verify(
                proof: proof,
                credential: credential,
                request: request,
                challenge: challenge
              )
        else { throw PommeRecoverySessionError.invalidProof }
        guard await registry.claim(credential.id) else {
            throw PommeRecoverySessionError.replayedCredential
        }
        credentialConsumed = true
        authenticated = true
        lifecycle = .authenticated
        return evidence()
    }

    func perform(payload: Data = Data()) async throws -> Data {
        guard lifecycle == .authenticated,
              authenticated,
              !operationAttempted,
              payload.count <= 256 * 1024,
              PommeRecoveryCrypto.sha256(payload) == request.payloadSHA256
        else { throw PommeRecoverySessionError.unauthenticated }
        operationAttempted = true
        lifecycle = .operating
        do {
            let result = try await guest.perform(
                operation: request.operation,
                requestID: request.requestID,
                payload: payload
            )
            guard result.count <= 256 * 1024 else {
                throw PommeRecoverySessionError.guestOperationFailed
            }
            return result
        } catch let error as PommeRecoveryGuestOperationFailure {
            lifecycle = .failed
            throw error
        } catch let error as PommeRecoverySessionError {
            lifecycle = .failed
            throw error
        } catch {
            lifecycle = .failed
            throw PommeRecoverySessionError.guestOperationFailed
        }
    }

    /// Teardown is authoritative. The caller cannot claim a successful
    /// operation or request a VM final-state transition until this returns.
    func teardown() async throws -> PommeRecoveryCleanupEvidence {
        guard !cleaned else {
            throw PommeRecoverySessionError.invalidLifecycle
        }
        guard preparationAttempted else {
            // No root was prepared, so there is no known artifact set to
            // clean. This is an unknown state and must fail closed.
            lifecycle = .failed
            throw PommeRecoverySessionError.cleanupFailed
        }
        lifecycle = .cleanup
        await guest.close()
        do {
            let cleanup = try await root.cleanup(request: request)
            guard cleanup.isComplete else {
                lifecycle = .failed
                throw PommeRecoverySessionError.cleanupFailed
            }
            cleaned = true
            lifecycle = .cleaned
            return cleanup
        } catch let error as PommeRecoverySessionError {
            lifecycle = .failed
            throw error
        } catch {
            lifecycle = .failed
            throw PommeRecoverySessionError.cleanupFailed
        }
    }

    /// Cleanup precedes the requested final-state transition. A failed
    /// cleanup intentionally leaves final state untouched and unverified.
    func finalize(_ finalState: VMFinalState) async throws -> PommeRecoverySessionEvidence {
        guard lifecycle == .cleaned else { throw PommeRecoverySessionError.cleanupFailed }
        guard request.requestedFinalState == finalState.rawValue else {
            lifecycle = .failed
            throw PommeRecoverySessionError.requestMismatch
        }
        let resolvedFinalState = try resolvedFinalState(finalState)
        do {
            try await vm.requestFinalState(resolvedFinalState)
            guard try await vm.proveFinalState(resolvedFinalState) else {
                throw PommeRecoverySessionError.finalStateUnverified
            }
            lifecycle = .finalized
            return evidence()
        } catch {
            lifecycle = .failed
            // The requested transition may have partially succeeded before
            // its proof failed. Make one bounded best-effort return to the
            // independently captured pre-session state so an unverified
            // helper is not knowingly left behind. The caller still receives
            // finalStateUnverified even when this recovery succeeds.
            await restoreCapturedStateAfterFinalizationFailure()
            throw PommeRecoverySessionError.finalStateUnverified
        }
    }

    private func restoreCapturedStateAfterFinalizationFailure() async {
        guard let vmState else { return }
        let capturedFinalState: VMFinalState
        switch vmState {
        case .stopped:
            capturedFinalState = .stopped
        case .running(.normal):
            capturedFinalState = .normal
        case .running(.recovery):
            capturedFinalState = .recovery
        case .paused:
            capturedFinalState = .paused
        }
        do {
            try await vm.requestFinalState(capturedFinalState)
            _ = try await vm.proveFinalState(capturedFinalState)
        } catch {
            // The stable public error already communicates that no final
            // state can be trusted; never surface an underlying host error.
        }
    }

    private func resolvedFinalState(_ requested: VMFinalState) throws -> VMFinalState {
        guard requested == .previous else { return requested }
        guard let vmState else { throw PommeRecoverySessionError.finalStateUnverified }
        switch vmState {
        case .stopped:
            return .stopped
        case .running(.normal):
            return .normal
        case .running(.recovery):
            return .recovery
        case .paused:
            return .paused
        }
    }

    /// Convenience transaction for callers that need all phases to run even
    /// when authentication or the operation itself throws.
    func execute(
        challenge: String,
        proof: String,
        payload: Data = Data(),
        finalState: VMFinalState
    ) async throws -> Data {
        var primary: Result<Data, Error>
        do {
            if lifecycle == .created { _ = try await prepare() }
            guard challenge == (try self.challenge()) else {
                throw PommeRecoverySessionError.invalidProof
            }
            _ = try await authenticate(challenge: challenge, proof: proof)
            primary = .success(try await perform(payload: payload))
        } catch {
            primary = .failure(error)
        }

        do {
            if lifecycle != .created { _ = try await teardown() }
            else { throw PommeRecoverySessionError.cleanupFailed }
        } catch {
            throw PommeRecoverySessionError.cleanupFailed
        }
        _ = try await finalize(finalState)
        return try primary.get()
    }

    /// Runs the complete authenticated operation transaction. The session
    /// owns challenge generation, proof creation, cleanup, and final-state
    /// restoration so an application adapter cannot accidentally skip a
    /// lifecycle phase.
    func run(
        payload: Data = Data(),
        finalState: VMFinalState
    ) async throws -> PommeRecoveryExecutionResult {
        var primary: Result<Data, Error>
        do {
            if lifecycle == .created { _ = try await prepare() }
            let admissionChallenge = try self.challenge()
            let proof = credential.proof(for: request, challenge: admissionChallenge)
            _ = try await authenticate(challenge: admissionChallenge, proof: proof)
            primary = .success(try await perform(payload: payload))
        } catch {
            primary = .failure(error)
        }

        guard preparationAttempted else {
            throw PommeRecoverySessionError.cleanupFailed
        }
        let cleanup: PommeRecoveryCleanupEvidence
        do {
            cleanup = try await teardown()
        } catch {
            throw PommeRecoverySessionError.cleanupFailed
        }
        _ = try await finalize(finalState)
        let output: Data
        do {
            output = try primary.get()
        } catch {
            throw error
        }
        return .init(
            output: output,
            cleanup: cleanup,
            finalState: finalState,
            evidence: evidence()
        )
    }
}
