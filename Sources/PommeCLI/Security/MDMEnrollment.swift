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
        guard agent.connected,
              agent.authenticated,
              agent.role == MDMEnrollmentAgentDescription.normalRole,
              agent.protocolName == MDMEnrollmentAgentDescription.protocolName,
              agent.protocolVersion == MDMEnrollmentAgentDescription.protocolVersion,
              isAttestedDigest(agent.executableDigest) else {
            throw RunnerError.hostCommandFailed(
                "MDM enrollment requires an authenticated, attested persistent PommeAgent using protocol v1."
            )
        }
        if let expectedExecutableDigest {
            guard isAttestedDigest(expectedExecutableDigest),
                  agent.executableDigest == expectedExecutableDigest.lowercased() else {
                throw RunnerError.hostCommandFailed(
                    "MDM enrollment requires the expected signed PommeAgent executable."
                )
            }
        }

        let missing = MDMEnrollmentAgentDescription.requiredCapabilities
            .subtracting(agent.capabilities)
            .sorted()
        guard missing.isEmpty else {
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

        // Once a baseline exists, a staging cleanup is attempted even if the
        // prepare operation itself fails: the guest may have created the
        // directory before its response was lost.
        var operationError: PommeMDMEnrollmentError?
        var transactionResult: PommeMDMEnrollmentTransactionResult?
        do {
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
                do {
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
                } catch let error as PommeMDMEnrollmentError {
                    throw error
                } catch {
                    throw PommeMDMEnrollmentError.enrollmentFailed
                }
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
        } catch let error as PommeMDMEnrollmentError {
            operationError = error
        } catch {
            operationError = .stagingPreparationFailed
        }

        // Cleanup and restoration are intentionally independent.  A cleanup
        // failure must not prevent restoration, and a restoration failure is
        // always the highest-precedence error because the VM's security/run
        // state is then unknown.
        var cleanupError = false
        if operationError != .helperProcessTerminationUnproven {
            do {
                let cleaned = try await agent.perform(.cleanup(profilePath: destination))
                try PommeMDMEnrollmentAgentResponse.requireCleanup(cleaned)
            } catch {
                cleanupError = true
            }
        }

        var restorationError = false
        do { try await state.restoreBaseline(baseline) }
        catch { restorationError = true }
        do {
            guard try await state.verifyBaseline(baseline) else {
                throw PommeMDMEnrollmentError.restorationFailed
            }
        } catch { restorationError = true }

        if restorationError { throw PommeMDMEnrollmentError.restorationFailed }
        if cleanupError { throw PommeMDMEnrollmentError.cleanupFailed }
        if let operationError { throw operationError }
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
