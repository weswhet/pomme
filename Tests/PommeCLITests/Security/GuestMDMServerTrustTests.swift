import Foundation
import Testing

@Suite("Guest MDM server trust")
struct GuestMDMServerTrustTests {
    @Test("Certificates are included only when the profile's roots alone validate the server", arguments: [
        (MDMServerTrustDecision.publicTrust, GuestMDMCertificateInclusion.omitted),
        (.notApplicable, .omitted),
        (.profileRootTrust, .included),
    ])
    func inclusionFollowsDecision(decision: MDMServerTrustDecision, expected: GuestMDMCertificateInclusion) throws {
        let profile = try MDMTrustFixtures.mobileconfig()
        let received = MaterialRecorder()
        let enrollment = GuestMDMEnrollment(serverTrust: { material in
            received.set(material)
            return report(decision)
        })
        let collector = GuestMDMDiagnostics.Collector()
        let inclusion = try GuestMDMDiagnostics.$current.withValue(collector) {
            try enrollment.certificateInclusion(profileData: profile)
        }
        #expect(inclusion == expected)
        #expect(received.value?.serverURL.absoluteString == MDMTrustFixtures.serverURL)
        #expect(received.value?.certificates == [MDMTrustFixtures.root])
        #expect(collector.failureStage == "certificatePayloadSelection")
        #expect(!collector.identityImportAttempted)
    }

    @Test("An untrusted or unreachable server stops before import as a retryable failure",
          arguments: [MDMServerTrustDecision.untrusted, .unreachable])
    func failureIsRetryable(decision: MDMServerTrustDecision) throws {
        let profile = try MDMTrustFixtures.mobileconfig()
        let enrollment = GuestMDMEnrollment(serverTrust: { _ in report(decision) })
        let collector = GuestMDMDiagnostics.Collector()
        GuestMDMDiagnostics.$current.withValue(collector) {
            #expect(throws: GuestInternalError.self) {
                _ = try enrollment.certificateInclusion(profileData: profile)
            }
        }
        #expect(collector.failureStage == "serverTrustEvaluation")
        #expect(!collector.identityImportAttempted)
        let envelope: JSONValue = .object([
            "completed": .bool(false), "errorCode": .string("enrollment-failed"),
            "diagnostics": collector.value, "failureStage": .string("serverTrustEvaluation"),
            "identityImportAttempted": .bool(false),
        ])
        do {
            _ = try PommeMDMTemporaryHelperResult.decode(envelope, detailedFailure: true)
            Issue.record("Expected a completed helper failure")
        } catch let failure as PommeMDMHelperFailure {
            #expect(failure.failureStage == .serverTrustEvaluation)
            #expect(failure.beforeIdentityImport)
        }
    }

    @Test("A malformed certificate payload is rejected before any trust probe")
    func malformedProfileIsRejected() throws {
        let profile = try MDMTrustFixtures.mobileconfig(
            certificatePayloads: [("com.apple.security.root", Data("junk".utf8))])
        let enrollment = GuestMDMEnrollment(serverTrust: { _ in
            Issue.record("A malformed profile must not be probed")
            return report(.publicTrust)
        })
        #expect(throws: GuestInternalError.self) {
            _ = try enrollment.certificateInclusion(profileData: profile)
        }
    }

    @Test("The trust profile carries only certificate payloads under a deterministic Pomme identity")
    func trustProfileDictionary() throws {
        let profile = try MDMTrustFixtures.mobileconfig(certificatePayloads: [
            ("com.apple.security.root", MDMTrustFixtures.root),
            ("com.apple.security.pem", MDMTrustFixtures.pem([MDMTrustFixtures.root])),
            ("com.apple.security.pkcs1", MDMTrustFixtures.leaf),
        ])
        let source = try #require(PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any])
        let trust = try #require(GuestMDMEnrollment.trustProfileDictionary(from: source))
        let payloads = try #require(trust["PayloadContent"] as? [[String: Any]])
        #expect(payloads.map { $0["PayloadType"] as? String } == [
            "com.apple.security.root", "com.apple.security.pem", "com.apple.security.pkcs1",
        ])
        #expect(trust["PayloadType"] as? String == "Configuration")
        #expect(trust["PayloadIdentifier"] as? String
            == GuestMDMEnrollment.trustProfilePrefix + "11111111-2222-3333-4444-555555555555")
        let uuid = try #require((trust["PayloadUUID"] as? String).flatMap(UUID.init(uuidString:)))
        #expect(uuid != UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        // Deterministic, so a retry replaces the same profile.
        #expect(GuestMDMEnrollment.trustProfileDictionary(from: source)?["PayloadUUID"] as? String
            == trust["PayloadUUID"] as? String)
        #expect(PropertyListSerialization.propertyList(trust, isValidFor: .xml))
    }

    @Test("A profile without certificate payloads has no trust profile")
    func noCertificatesNoTrustProfile() throws {
        let profile = try MDMTrustFixtures.mobileconfig(certificatePayloads: [])
        let source = try #require(PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any])
        #expect(GuestMDMEnrollment.trustProfileDictionary(from: source) == nil)
    }

    @Test("New trust stages are closed diagnostics that precede identity import")
    func stagesPrecedeImport() {
        for stage in [GuestMDMDiagnostics.Stage.serverTrustProbe, .serverTrustEvaluation, .certificatePayloadSelection,
                      .trustProfileInstall, .trustProfileVerification] {
            #expect(stage.precedesIdentityImport)
        }
    }
}

private func report(_ decision: MDMServerTrustDecision) -> MDMServerTrustReport {
    .init(endpoints: [.init(endpoint: MDMServerEndpoint(URL(string: MDMTrustFixtures.serverURL)!), decision: decision)])
}

private final class MaterialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var material: MDMProfileTrustMaterial?
    var value: MDMProfileTrustMaterial? { lock.withLock { material } }
    func set(_ value: MDMProfileTrustMaterial) { lock.withLock { material = value } }
}
