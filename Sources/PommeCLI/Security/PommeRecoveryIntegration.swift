import Foundation

/// The result returned by an authenticated Recovery operation. It contains
/// no credential material, paths, or guest diagnostics.
struct PommeRecoveryExecutionResult: Equatable, Sendable {
    let output: Data
    let cleanup: PommeRecoveryCleanupEvidence
    let finalState: VMFinalState
    let evidence: PommeRecoverySessionEvidence
}

/// Injectable seam for the application and provisioning layers. A live
/// adapter supplies a request-bound `PommeRecoverySession`; an offline test
/// supplies the same protocol with deterministic ports. No normal-boot
/// operation or alternate guest execution channel is represented here.
protocol PommeRecoveryOperationAdapter: Sendable {
    func execute(
        operation: PommeRecoveryOperation,
        payload: Data,
        finalState: VMFinalState
    ) async throws -> PommeRecoveryExecutionResult
}

/// Builds one immutable Recovery integration for one VM and one operation.
/// A factory is required here because Recovery credentials are one-shot and
/// request-bound; retaining a single session across CLI operations would make
/// the second operation either a replay or an authority for the wrong VM.
struct PommeRecoveryIntegrationFactory: Sendable {
    typealias Builder = @Sendable (
        _ reference: VMReference,
        _ operation: PommeRecoveryOperation
    ) async throws -> PommeRecoveryIntegration

    private let builder: Builder

    init(builder: @escaping Builder) {
        self.builder = builder
    }

    func make(
        reference: VMReference,
        operation: PommeRecoveryOperation
    ) async throws -> PommeRecoveryIntegration {
        try await builder(reference, operation)
    }

    /// Useful for deterministic tests that intentionally own a single
    /// integration. Production installs `PommeLiveRecoveryIntegration.factory`.
    static func fixed(_ integration: PommeRecoveryIntegration) -> Self {
        .init { _, _ in integration }
    }
}

/// Session-backed live adapter. Construct one after the caller has built the
/// request, one-shot credential, and narrow root/VM/guest ports:
///
///     let session = try PommeRecoverySession(
///         request: request, credential: credential,
///         root: rootPort, vm: vmPort, guest: guestPort)
///     let recovery = PommeRecoveryIntegration(
///         adapter: PommeRecoverySessionAdapter(
///             session: session, credential: credential))
///     let result = try await recovery.sip(
///         action: action, payload: payload, finalState: finalState)
///
/// The credential is retained only by this adapter so it can produce the
/// admission proof inside `PommeRecoverySession.run`; it is never serialized
/// or returned in the result.
struct PommeRecoverySessionAdapter: PommeRecoveryOperationAdapter, Sendable {
    let session: PommeRecoverySession
    private let credential: PommeRecoveryCredential

    init(session: PommeRecoverySession, credential: PommeRecoveryCredential) {
        self.session = session
        self.credential = credential
    }

    func execute(
        operation: PommeRecoveryOperation,
        payload: Data = Data(),
        finalState: VMFinalState
    ) async throws -> PommeRecoveryExecutionResult {
        let request = await session.requestSnapshot()
        let requestOperation = request.operation
        guard requestOperation == operation.wireName else {
            throw PommeRecoverySecurityError.operationRejected
        }
        // Touch the immutable binding before entering the actor transaction.
        // This also makes construction mistakes fail before any guest call.
        guard credential.matches(request: request) else {
            throw PommeRecoverySecurityError.operationRejected
        }
        return try await session.run(payload: payload, finalState: finalState)
    }
}

/// Typed application facade used by SIP, AMFI, provisioning agent install,
/// and agent repair call sites. Each method maps to the single allowlisted
/// Recovery operation in the immutable request.
struct PommeRecoveryIntegration: Sendable {
    let adapter: any PommeRecoveryOperationAdapter

    init(adapter: any PommeRecoveryOperationAdapter) {
        self.adapter = adapter
    }

    func sip(
        action: SIPAction,
        payload: Data = Data(),
        finalState: VMFinalState
    ) async throws -> PommeRecoveryExecutionResult {
        try await adapter.execute(
            operation: .sip(action), payload: payload, finalState: finalState)
    }

    func amfi(
        action: AMFIAction,
        payload: Data = Data(),
        finalState: VMFinalState
    ) async throws -> PommeRecoveryExecutionResult {
        try await adapter.execute(
            operation: .amfi(action), payload: payload, finalState: finalState)
    }

    func installAgent(
        payload: Data = Data(),
        finalState: VMFinalState
    ) async throws -> PommeRecoveryExecutionResult {
        try await adapter.execute(
            operation: .installAgent, payload: payload, finalState: finalState)
    }

    func repairAgent(
        payload: Data = Data(),
        finalState: VMFinalState
    ) async throws -> PommeRecoveryExecutionResult {
        // Repair is intentionally the same Recovery-only request role as
        // installation; there is no normal-boot repair path.
        try await installAgent(payload: payload, finalState: finalState)
    }
}

/// Descriptive alias for call sites that prefer to spell out that this value
/// is the application boundary rather than a guest implementation.
typealias PommeRecoveryIntegrationFacade = PommeRecoveryIntegration
