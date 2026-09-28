import Foundation
import Darwin

/// Validates the only guest directory that may hold an uploaded enrollment
/// profile. The running PommeAgent owns the actual file operation; this type
/// only derives a safe direct-child destination before that authenticated
/// operation is requested.
enum MDMProfileStaging {
    static let guestDirectory = "/private/var/db/pomme-mdm-enrollment"

    static func destination(requestedPath: String?) throws -> String {
        let candidate = requestedPath ?? "\(guestDirectory)/\(UUID().uuidString).mobileconfig"
        guard candidate.hasPrefix("/") else {
            throw RunnerError.hostCommandFailed("MDM profile staging requires an absolute guest destination.")
        }

        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard !candidate.contains("\0"),
              !components.dropFirst().contains(""),
              !components.contains("."), !components.contains("..") else {
            throw RunnerError.hostCommandFailed("MDM profile staging requires a canonical guest destination.")
        }
        // Guest paths are protocol values, not host filesystem URLs. On
        // macOS 15 standardizedFileURL aliases /private/var to /var.
        let resolved = candidate
        let root = guestDirectory
        let resolvedURL = URL(fileURLWithPath: resolved)
        guard resolvedURL.deletingLastPathComponent().path == root,
              resolvedURL.lastPathComponent != ".",
              resolvedURL.lastPathComponent != "..",
              !resolvedURL.lastPathComponent.hasPrefix(PommeMDMTemporaryHelperWorkspace.helperPrefix),
              !resolvedURL.lastPathComponent.hasPrefix(".pomme-stage-") else {
            throw RunnerError.hostCommandFailed(
                "mdm --guest-path must name a new direct child of \(guestDirectory)."
            )
        }
        return resolved
    }
}

enum MDMAgentReadiness: Equatable, Sendable {
    case ready
    /// Not an authenticated, attested persistent agent on protocol v1.
    case unattested
    /// A different executable than the one creation pinned.
    case digestMismatch
    case missingCapabilities([String])

    var code: String {
        switch self {
        case .ready: "ready"
        case .unattested: "unattested"
        case .digestMismatch: "digestMismatch"
        case .missingCapabilities: "missingCapabilities"
        }
    }
}

/// MDM accepts evidence only from an authenticated, connected normal PommeAgent
/// using the closed protocol-v1 capability contract.
enum MDMEnrollmentAgentGate {
    static func preflight(_ provider: some MDMEnrollmentAgentProviding) throws -> [String: Any] {
        try verify(provider.enrollmentAgentDescription())
    }

    static func verify(
        _ agent: MDMEnrollmentAgentDescription,
        expectedExecutableDigest: String? = nil
    ) throws -> [String: Any] {
        switch classify(agent, expectedExecutableDigest: expectedExecutableDigest) {
        case .ready:
            break
        case .unattested:
            throw RunnerError.hostCommandFailed(
                "MDM enrollment requires an authenticated, attested persistent PommeAgent using protocol v1."
            )
        case .digestMismatch:
            throw RunnerError.hostCommandFailed(
                "MDM enrollment requires the expected signed PommeAgent executable."
            )
        case .missingCapabilities:
            throw RunnerError.hostCommandFailed(
                "MDM enrollment requires verified PommeAgent enrollment and maintenance capabilities."
            )
        }

        return [
            "agent": "PommeAgent",
            "role": agent.role,
            "protocol": agent.protocolName,
            "version": agent.protocolVersion,
            "capabilities": MDMEnrollmentAgentDescription.requiredCapabilities.sorted()
        ]
    }

    /// The same closed policy as `verify`, as a value a planner can report.
    static func classify(
        _ agent: MDMEnrollmentAgentDescription,
        expectedExecutableDigest: String? = nil
    ) -> MDMAgentReadiness {
        guard agent.connected,
              agent.authenticated,
              agent.role == MDMEnrollmentAgentDescription.normalRole,
              agent.protocolName == MDMEnrollmentAgentDescription.protocolName,
              agent.protocolVersion == MDMEnrollmentAgentDescription.protocolVersion,
              isAttestedDigest(agent.executableDigest) else {
            return .unattested
        }
        if let expectedExecutableDigest {
            guard isAttestedDigest(expectedExecutableDigest),
                  agent.executableDigest == expectedExecutableDigest.lowercased() else {
                return .digestMismatch
            }
        }
        let missing = MDMEnrollmentAgentDescription.requiredCapabilities
            .subtracting(agent.capabilities)
            .sorted()
        return missing.isEmpty ? .ready : .missingCapabilities(missing)
    }

    private static func isAttestedDigest(_ value: String?) -> Bool {
        guard let value,
              value.count == 64,
              value == value.lowercased(),
              value.allSatisfy(\.isHexDigit) else {
            return false
        }
        return true
    }
}

/// Executes one complete MDM enrollment against the persistent normal-role
/// agent.  Every external effect is represented by a dependency-injected
/// method, which keeps this boundary independent of the helper socket and
/// makes it impossible to fall back to Recovery or a generic file command.
struct PommeMDMEnrollmentTransaction: Sendable {
    let agent: any PommeMDMEnrollmentAgentTransport
    let state: any PommeMDMEnrollmentStatePort
    let profileURL: URL
    let guestPath: String?
    let timeout: TimeInterval
    let enrollmentMode: MDMEnrollmentMode
    let expectedExecutableDigest: String?
    let temporaryHelper: (any PommeMDMTemporaryHelperTransport)?

    init(
        agent: any PommeMDMEnrollmentAgentTransport,
        state: any PommeMDMEnrollmentStatePort,
        profileURL: URL,
        guestPath: String? = nil,
        timeout: TimeInterval,
        enrollmentMode: MDMEnrollmentMode = .unapproved,
        expectedExecutableDigest: String? = nil,
        temporaryHelper: (any PommeMDMTemporaryHelperTransport)? = nil
    ) {
        self.agent = agent
        self.state = state
        self.profileURL = profileURL
        self.guestPath = guestPath
        self.timeout = timeout
        self.enrollmentMode = enrollmentMode
        self.expectedExecutableDigest = expectedExecutableDigest
        self.temporaryHelper = temporaryHelper
    }

    func execute() async throws -> PommeMDMEnrollmentTransactionResult {
        try validateRequest()

        let description: MDMEnrollmentAgentDescription
        do {
            description = try await agent.authenticatedAgentDescription()
        } catch {
            throw PommeMDMEnrollmentError.agentUnavailable
        }
        do {
            _ = try MDMEnrollmentAgentGate.verify(
                description,
                expectedExecutableDigest: expectedExecutableDigest
            )
        } catch {
            throw PommeMDMEnrollmentError.agentUnverified
        }

        let destination: String
        do {
            destination = try MDMProfileStaging.destination(requestedPath: guestPath)
        } catch {
            throw PommeMDMEnrollmentError.invalidRequest
        }

        let baseline: PommeMDMEnrollmentStateBaseline
        do {
            baseline = try await state.captureBaseline()
            guard baseline.isWellFormed else {
                throw PommeMDMEnrollmentError.baselineCaptureFailed
            }
        } catch let error as PommeMDMEnrollmentError {
            throw error
        } catch {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }

        // Failed enrollment retains guest artifacts and the current VM state.
        var transactionResult: PommeMDMEnrollmentTransactionResult?
        let prepared = try await agent.perform(.prepareStaging)
        try PommeMDMEnrollmentAgentResponse.requireStagingReady(prepared)

        let receipt: PommeMDMProfileTransferReceipt
        do {
            receipt = try await agent.transferProfile(from: profileURL, to: destination)
        } catch let error as PommeMDMEnrollmentError {
            throw error == .invalidTransfer ? error : .transferFailed
        } catch {
            throw PommeMDMEnrollmentError.transferFailed
        }
        guard receipt.destination == destination else {
            throw PommeMDMEnrollmentError.invalidTransfer
        }

        if let temporaryHelper {
            let response = try await temporaryHelper.enroll(
                profile: receipt,
                mode: enrollmentMode,
                baseline: baseline,
                timeout: timeout
            )
            transactionResult = .init(
                profileIdentifier: response.profileIdentifier,
                transferredBytes: receipt.bytes,
                transferredSHA256: receipt.sha256,
                agentCapabilities: description.capabilities.sorted()
            )
        } else {
            let enrollment: JSONValue
            do {
                enrollment = try await agent.perform(
                    .enroll(profilePath: destination, timeout: timeout)
                )
            } catch {
                throw PommeMDMEnrollmentError.enrollmentFailed
            }
            let response = try PommeMDMEnrollmentAgentResponse.enrollment(enrollment)
            transactionResult = .init(
                profileIdentifier: response.profileIdentifier,
                transferredBytes: receipt.bytes,
                transferredSHA256: receipt.sha256,
                agentCapabilities: description.capabilities.sorted()
            )
        }
        // Legacy persistent-agent enrollment is retained for existing
        // protocol-v1 guests. It has no private helper mode field, so it
        // performs approval only for the explicitly selected supervised
        // mode. New helper requests carry the mode and approve internally.
        if temporaryHelper == nil, enrollmentMode == .supervised,
           let identifier = transactionResult?.profileIdentifier {
            let approval = try await agent.perform(
                .approve(profileIdentifier: identifier, timeout: timeout)
            )
            try PommeMDMEnrollmentAgentResponse.approval(approval)
        }

        do {
            let cleaned = try await agent.perform(.cleanup(profilePath: destination))
            try PommeMDMEnrollmentAgentResponse.requireCleanup(cleaned)
        } catch { throw PommeMDMEnrollmentError.cleanupFailed }
        do {
            try await state.restoreBaseline(baseline)
            guard try await state.verifyBaseline(baseline) else {
                throw PommeMDMEnrollmentError.restorationFailed
            }
        } catch { throw PommeMDMEnrollmentError.restorationFailed }
        guard let transactionResult else {
            throw PommeMDMEnrollmentError.enrollmentFailed
        }
        return transactionResult
    }

    private func validateRequest() throws {
        guard timeout.isFinite, timeout >= 1, timeout <= 300 else {
            throw PommeMDMEnrollmentError.invalidRequest
        }
        let source = profileURL.standardizedFileURL
        guard source.isFileURL,
              source.path.hasPrefix("/"),
              !source.path.contains("\0") else {
            throw PommeMDMEnrollmentError.invalidProfile
        }
        var info = stat()
        guard lstat(source.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else {
            throw PommeMDMEnrollmentError.invalidProfile
        }
        if let guestPath {
            guard (try? MDMProfileStaging.destination(requestedPath: guestPath)) == guestPath else {
                throw PommeMDMEnrollmentError.invalidRequest
            }
        }
    }
}

// These pure projections are shared by focused MDM verification tests and do
// not select a guest transport or perform any guest-side operation.
extension PommeCore {
    static func mdmProfileIdentifierSelection(
        firstIdentifier: String,
        requestedFound: Bool,
        requested: String?
    ) -> (observed: String, matchesRequested: Bool) {
        let normalized = firstIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requested, !requested.isEmpty else {
            return (normalized, true)
        }
        if requestedFound {
            return (requested, true)
        }
        return (normalized, false)
    }

    static func mdmApprovalVerificationSucceeded(
        _ payload: [String: Any],
        expectedProfileIdentifier: String?
    ) -> Bool {
        guard payload["ok"] as? Bool == true,
              payload["mdmEnrolled"] as? Bool == true,
              payload["userApproved"] as? Bool == true else {
            return false
        }
        return expectedProfileIdentifier == nil
            || payload["profileIdentifierMatchesRequested"] as? Bool == true
    }
}
