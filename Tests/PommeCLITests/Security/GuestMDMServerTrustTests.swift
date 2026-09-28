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

    @Test("Archives carry the MDM payload, plus certificate payloads first when included, never PKCS#12")
    func archivePayloadSelection() throws {
        let profile = try MDMTrustFixtures.mobileconfig(certificatePayloads: [
            ("com.apple.security.root", MDMTrustFixtures.root),
            ("com.apple.security.pem", MDMTrustFixtures.pem([MDMTrustFixtures.root])),
            ("com.apple.security.pkcs1", MDMTrustFixtures.leaf),
        ])
        let root = try #require(PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any])
        let payloads = try #require(root["PayloadContent"] as? [[String: Any]])

        let omitted = GuestMDMEnrollment.archivePayloads(from: payloads, certificates: .omitted)
        #expect(omitted.map { $0["PayloadType"] as? String } == ["com.apple.mdm"])

        let included = GuestMDMEnrollment.archivePayloads(from: payloads, certificates: .included)
        #expect(included.map { $0["PayloadType"] as? String } == [
            "com.apple.security.root", "com.apple.security.pem", "com.apple.security.pkcs1", "com.apple.mdm",
        ])
        #expect(!included.contains { $0["PayloadType"] as? String == "com.apple.security.pkcs12" })
    }

    @Test("New trust stages are closed diagnostics that precede identity import")
    func stagesPrecedeImport() {
        for stage in [GuestMDMDiagnostics.Stage.serverTrustProbe, .serverTrustEvaluation, .certificatePayloadSelection] {
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
