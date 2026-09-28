import Foundation
import Testing

/// A P-256 root valid 2026-01-01 to 2036-01-01 that signed `leaf`, an
/// unrelated root, and a `mdm.example.test` server leaf valid 2026-06-01 to
/// 2027-05-01 with serverAuth and a DNS SAN.
enum MDMTrustFixtures {
    static let root = Data(base64Encoded: """
        MIIBnzCCAUWgAwIBAgIUamz1mqhn4cc20W2CfMe+N2fpfDkwCgYIKoZIzj0EAwIwHTEbMBkGA1UEAwwSUG9tbWUgVGVzdCBSb290\
        IENBMB4XDTI2MDEwMTAwMDAwMFoXDTM2MDEwMTAwMDAwMFowHTEbMBkGA1UEAwwSUG9tbWUgVGVzdCBSb290IENBMFkwEwYHKoZI\
        zj0CAQYIKoZIzj0DAQcDQgAEJPkFjZilAPfHdyoEVFB7MBOnuW8j9MXHxQ2pRG8qt+asU3mifTh6s+Oqg2T4c4CCz6EmryG1izWM\
        DamJYjqTuKNjMGEwHQYDVR0OBBYEFLTUXpZ2IyUzscsQqqGtBF7Qaoy8MB8GA1UdIwQYMBaAFLTUXpZ2IyUzscsQqqGtBF7Qaoy8\
        MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0gAMEUCIQDB1KjwS4i9wal+dK3sEmnrMBxTKxrI\
        xQcFwrfFD/UOZwIgf8Y2lYAKfKkVVzvqFljhqhOUnVhcFZtv9T/sqNGtYDo=
        """)!
    static let unrelatedRoot = Data(base64Encoded: """
        MIIBqTCCAU+gAwIBAgIUKWKFb1sDs/PuR/+Of75eldB4U1kwCgYIKoZIzj0EAwIwIjEgMB4GA1UEAwwXUG9tbWUgVW5yZWxhdGVk\
        IFJvb3QgQ0EwHhcNMjYwMTAxMDAwMDAwWhcNMzYwMTAxMDAwMDAwWjAiMSAwHgYDVQQDDBdQb21tZSBVbnJlbGF0ZWQgUm9vdCBD\
        QTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABImJ2NxYJN0V8YOWW5EjHXuA3VEPaw4qZ02wh8gd8T/fExYc1tR+vS+qNySOpPxp\
        6IGQHrLy+U/4hb59nKtntiujYzBhMB0GA1UdDgQWBBRI7fELtbbjL1oa40epXI4y/P7KaDAfBgNVHSMEGDAWgBRI7fELtbbjL1oa\
        40epXI4y/P7KaDAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQDAgNIADBFAiEA5c00mPpj3nOtlEaU\
        SnwjcnSDTyHWKUVBGh2Sh9NJjOACIGTjsGsjejGVuHgUzqvhpGWBI/b4zJi/IuEbi0VQIggR
        """)!
    static let leaf = Data(base64Encoded: """
        MIIBzjCCAXSgAwIBAgIUYCMLFohTOCFInFM/dGOL8T7j3V4wCgYIKoZIzj0EAwIwHTEbMBkGA1UEAwwSUG9tbWUgVGVzdCBSb290\
        IENBMB4XDTI2MDYwMTAwMDAwMFoXDTI3MDUwMTAwMDAwMFowGzEZMBcGA1UEAwwQbWRtLmV4YW1wbGUudGVzdDBZMBMGByqGSM49\
        AgEGCCqGSM49AwEHA0IABK/IQLmVEDUSLPNRrE6VfglQm6+zKYbzCZScO+IJjfcVZu4vHPdYhl8K8N62kQthSjSqs6/KGuqX4TsR\
        /uxYywijgZMwgZAwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwGwYDVR0RBBQwEoIQ\
        bWRtLmV4YW1wbGUudGVzdDAdBgNVHQ4EFgQUfpWkc3Gz0RUl1TF4elxEhoInHyswHwYDVR0jBBgwFoAUtNRelnYjJTOxyxCqoa0E\
        XtBqjLwwCgYIKoZIzj0EAwIDSAAwRQIgKdddhbxgCx/6l0Ub59uWLKtH+qZwcATH80flwcbUaqQCIQDBGSrr3C5uGgcs7dbbe7O8\
        AUrVEiet0/ryuv+DP7Ya9g==
        """)!
    /// Inside both the root and leaf validity periods.
    static let verifyDate = Date(timeIntervalSince1970: 1_790_000_000)
    static let serverURL = "https://mdm.example.test/mdm"

    static func pem(_ certificates: [Data]) -> Data {
        Data(certificates.map { der in
            "-----BEGIN CERTIFICATE-----\n"
                + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                + "\n-----END CERTIFICATE-----\n"
        }.joined().utf8)
    }

    static func mobileconfig(
        serverURL: String = serverURL, checkInURL: String? = nil,
        certificatePayloads: [(type: String, content: Data)] = [("com.apple.security.root", root)]
    ) throws -> Data {
        var mdm: [String: Any] = [
            "PayloadType": "com.apple.mdm", "PayloadIdentifier": "com.example.mdm.payload",
            "PayloadUUID": "22222222-3333-4444-5555-666666666666", "PayloadVersion": 1,
            "ServerURL": serverURL, "IdentityCertificateUUID": "33333333-4444-5555-6666-777777777777",
            "Topic": "com.apple.mgmt.test", "AccessRights": 8191,
        ]
        if let checkInURL { mdm["CheckInURL"] = checkInURL }
        var payloads: [[String: Any]] = [mdm, [
            "PayloadType": "com.apple.security.pkcs12", "PayloadUUID": "33333333-4444-5555-6666-777777777777",
            "PayloadContent": Data([0x30, 0x03, 0x02, 0x01, 0x03]),
        ]]
        for (index, payload) in certificatePayloads.enumerated() {
            payloads.append(["PayloadType": payload.type, "PayloadContent": payload.content,
                             "PayloadUUID": "44444444-5555-6666-7777-\(String(format: "%012d", index))"])
        }
        return try PropertyListSerialization.data(fromPropertyList: [
            "PayloadType": "Configuration", "PayloadIdentifier": "com.example.mdm",
            "PayloadUUID": "11111111-2222-3333-4444-555555555555", "PayloadVersion": 1,
            "PayloadContent": payloads,
        ], format: .xml, options: 0)
    }
}

@Suite("MDM server trust")
struct MDMServerTrustTests {
    @Test("Root, PKCS#1, and multi-certificate PEM payloads parse; PKCS#12 is ignored")
    func parsesCertificatePayloads() throws {
        let profile = try MDMTrustFixtures.mobileconfig(checkInURL: "https://checkin.example.test:8443/c",
            certificatePayloads: [
                ("com.apple.security.root", MDMTrustFixtures.root),
                ("com.apple.security.pkcs1", MDMTrustFixtures.leaf),
                ("com.apple.security.pem", MDMTrustFixtures.pem([MDMTrustFixtures.unrelatedRoot, MDMTrustFixtures.root])),
            ])

        let material = try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: profile)

        #expect(material.serverURL.absoluteString == MDMTrustFixtures.serverURL)
        #expect(material.certificates == [MDMTrustFixtures.root, MDMTrustFixtures.leaf,
                                          MDMTrustFixtures.unrelatedRoot, MDMTrustFixtures.root])
        #expect(material.endpoints.map { MDMServerEndpoint($0).key }
            == ["https://mdm.example.test:443", "https://checkin.example.test:8443"])
    }

    @Test("Trust parsing leaves the journaled profile identity unchanged")
    func identityIsUnchanged() throws {
        let profile = try MDMTrustFixtures.mobileconfig()
        let identity = try MDMEnrollmentEvidenceParser.parseProfileIdentity(fromMobileconfig: profile)
        _ = try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: profile)
        #expect(try MDMEnrollmentEvidenceParser.parseProfileIdentity(fromMobileconfig: profile) == identity)
        #expect(identity.serverURL == MDMTrustFixtures.serverURL)
    }

    @Test("A check-in URL on the server's endpoint is not probed twice")
    func sameEndpointCheckIn() throws {
        let profile = try MDMTrustFixtures.mobileconfig(checkInURL: "https://MDM.example.test/checkin")
        let material = try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: profile)
        #expect(material.endpoints.count == 1)
    }

    @Test("Malformed or oversized certificate payloads are rejected", arguments: [
        Data("not a certificate".utf8),
        Data("-----BEGIN CERTIFICATE-----\n@@@\n-----END CERTIFICATE-----\n".utf8),
        Data("-----BEGIN CERTIFICATE-----\nMIIB\n".utf8),
        Data(repeating: 0x30, count: MDMProfileTrustMaterial.maximumCertificateBytes + 1),
    ])
    func rejectsMalformedCertificates(_ content: Data) throws {
        let profile = try MDMTrustFixtures.mobileconfig(certificatePayloads: [("com.apple.security.root", content)])
        #expect(throws: MDMEnrollmentEvidenceError.self) {
            try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: profile)
        }
    }

    @Test("More than the certificate limit is rejected")
    func rejectsTooManyCertificates() throws {
        let many = MDMTrustFixtures.pem(Array(repeating: MDMTrustFixtures.root,
                                              count: MDMProfileTrustMaterial.maximumCertificates + 1))
        let profile = try MDMTrustFixtures.mobileconfig(certificatePayloads: [("com.apple.security.pem", many)])
        #expect(throws: MDMEnrollmentEvidenceError.self) {
            try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: profile)
        }
    }

    @Test("A profile root validates only its own server when system roots do not")
    func evaluatorDecisions() {
        let presented = MDMServerTrustObservation.presented([MDMTrustFixtures.leaf])
        func decision(_ profile: [Data], host: String = "mdm.example.test",
                      observation: MDMServerTrustObservation = presented) -> MDMServerTrustDecision {
            MDMServerTrustEvaluator.evaluate(observation, host: host, profileCertificates: profile,
                defaultAnchors: .systemRoots, verifyDate: MDMTrustFixtures.verifyDate)
        }
        #expect(decision([MDMTrustFixtures.root]) == .profileRootTrust)
        #expect(decision([MDMTrustFixtures.unrelatedRoot, MDMTrustFixtures.root]) == .profileRootTrust)
        #expect(decision([MDMTrustFixtures.unrelatedRoot]) == .untrusted)
        #expect(decision([]) == .untrusted)
        // A non-root profile certificate is never an anchor.
        #expect(decision([MDMTrustFixtures.leaf]) == .untrusted)
        #expect(decision([MDMTrustFixtures.root], host: "other.example.test") == .untrusted)
        #expect(decision([MDMTrustFixtures.root], observation: .unreachable) == .unreachable)
        #expect(decision([MDMTrustFixtures.root], observation: .presented([Data("junk".utf8)])) == .untrusted)
    }

    @Test("The preflight reports each endpoint and combines them most restrictively")
    func preflightCombinesEndpoints() async throws {
        let profile = try MDMTrustFixtures.mobileconfig(checkInURL: "https://checkin.example.test/c")
        let material = try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: profile)
        let probed = ProbeRecorder()
        let report = await MDMServerTrustPreflight.run(material, defaultAnchors: .systemRoots, probe: { url, _ in
            await probed.append(url.host ?? "")
            return url.host == "mdm.example.test" ? .presented([MDMTrustFixtures.leaf]) : .unreachable
        }, verifyDate: MDMTrustFixtures.verifyDate)

        #expect(await probed.values() == ["mdm.example.test", "checkin.example.test"])
        #expect(report.endpoints.map(\.decision) == [.profileRootTrust, .unreachable])
        #expect(report.decision == .unreachable)
        #expect(report.publicValue["result"] as? String == "unreachable")
    }

    @Test("Plain HTTP endpoints are not probed")
    func httpIsNotApplicable() async throws {
        let profile = try MDMTrustFixtures.mobileconfig(serverURL: "http://mdm.example.test/mdm")
        let material = try MDMEnrollmentEvidenceParser.parseTrustMaterial(fromMobileconfig: profile)
        let report = await MDMServerTrustPreflight.run(material, defaultAnchors: .systemRoots, probe: { _, _ in
            Issue.record("HTTP must not be probed")
            return .unreachable
        })
        #expect(report.decision == .notApplicable)
    }

    @Test("Any untrusted endpoint makes the report untrusted")
    func untrustedDominates() {
        let endpoint = MDMServerEndpoint(URL(string: "https://a.example.test")!)
        let report = MDMServerTrustReport(endpoints: [
            .init(endpoint: endpoint, decision: .publicTrust), .init(endpoint: endpoint, decision: .unreachable),
            .init(endpoint: endpoint, decision: .untrusted),
        ])
        #expect(report.decision == .untrusted)
        #expect(MDMServerTrustReport(endpoints: []).decision == .notApplicable)
    }
}

private actor ProbeRecorder {
    private var hosts: [String] = []
    func append(_ host: String) { hosts.append(host) }
    func values() -> [String] { hosts }
}
