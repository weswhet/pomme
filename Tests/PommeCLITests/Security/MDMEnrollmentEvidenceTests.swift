import Foundation
import Testing

@Suite("MDM enrollment evidence")
struct MDMEnrollmentEvidenceTests {
    private let identifier = "org.example.pomme.mdm"
    private let uuid = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
    private let serverURL = "https://10.200.2.165:9444/mdm"

    @Test("Mode is typed, Codable, argument-expressible, and supervised by default")
    func enrollmentModes() throws {
        #expect(MDMEnrollmentMode.allCases == [.supervised, .unapproved])
        #expect(MDMEnrollmentMode.defaultMode == .supervised)
        #expect(MDMEnrollmentMode.defaultValue == .supervised)
        #expect(MDMEnrollmentMode(argument: "supervised") == .supervised)
        #expect(MDMEnrollmentMode(argument: "unapproved") == .unapproved)
        #expect(MDMEnrollmentMode(argument: "SUPERVISED") == nil)

        let encoded = try JSONEncoder().encode(MDMEnrollmentMode.unapproved)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"unapproved\"")
        #expect(try JSONDecoder().decode(MDMEnrollmentMode.self, from: encoded) == .unapproved)
    }

    @Test("Source and installed device profile identities must match exactly")
    func exactIdentity() throws {
        let source = try mobileconfig()
        let installed = try profilesShow()
        let expected = try MDMEnrollmentEvidenceParser.parseProfileIdentity(fromMobileconfig: source)
        let observed = try MDMEnrollmentEvidenceParser.parseInstalledProfileIdentity(fromProfilesShow: installed)

        #expect(observed.matches(expected))
        #expect(expected.identifier == identifier)
        #expect(expected.uuid == uuid)
        #expect(expected.serverURL == serverURL)
        #expect(expected.digest.count == 64)
        #expect(expected.sha256 == expected.digest)

        let status = Data("Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\nMDM server: \(serverURL)\n".utf8)
        let device = Data("{ IsSupervised = 1; }\n".utf8)
        let evidence = try MDMEnrollmentEvidenceParser.parse(
            mobileconfig: source,
            profilesShow: installed,
            profilesStatus: status,
            queryDeviceInformation: device
        )
        #expect(evidence.mode == .supervised)
        #expect(evidence.observedMode == .supervised)
        #expect(evidence.isMDMEnrolled)
        #expect(evidence.isUserApproved)
        #expect(evidence.isSupervised)
    }

    @Test("The live unmarked status is enrolled but unapproved")
    func unapprovedStatus() throws {
        let status = Data("Enrolled via DEP: No\nMDM enrollment: Yes\nMDM server: \(serverURL)\n".utf8)
        let parsed = try MDMEnrollmentEvidenceParser.parseEnrollmentStatus(fromProfilesStatus: status)
        #expect(parsed.enrolled)
        #expect(!parsed.userApproved)
        #expect(parsed.serverURL == serverURL)
        #expect(parsed.enrolledViaDEP == false)

        let source = try mobileconfig()
        let evidence = try MDMEnrollmentEvidenceParser.parse(
            mobileconfig: source,
            profilesShow: try profilesShow(),
            profilesStatus: status,
            queryDeviceInformation: Data("{ IsSupervised = 0; }\n".utf8),
            mode: .unapproved
        )
        #expect(evidence.mode == .unapproved)
        #expect(evidence.observedMode == .unapproved)
        #expect(!evidence.isUserApproved)
        #expect(!evidence.isSupervised)
    }

    @Test("Parses the bounded mdmclient wrapper and rejects merged diagnostics")
    func mdmClientWrapper() throws {
        let wrapped = Data(
            """
            === CPF_GetInstalledProfiles === (<Device>)
            Number of <Device> profiles found: 1 (Filtered: 0)
            Daemon response: { QueryResponses = { IsSupervised = 0; }; }
            Agent response: (null)
            """.utf8
        )
        #expect(try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: wrapped).isSupervised == false)
        let supervised = Data("{ QueryResponses = { IsSupervised = 1; }; }\n".utf8)
        #expect(try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: supervised).isSupervised)
        let malformed = Data("{ QueryResponses = { IsSupervised = 2; }; }\n".utf8)
        #expect(throws: MDMEnrollmentEvidenceError.malformedEvidence) {
            try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: malformed)
        }

        let countZero = Data(
            """
            === CPF_GetInstalledProfiles === (<Device>)
            Number of <Device> profiles found: 0 (Filtered: 0)
            Daemon response: { IsSupervised = "0"; }
            Agent response: (null)
            """.utf8
        )
        #expect(try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: countZero).isSupervised == false)

        let countTwo = Data(
            """
            === CPF_GetInstalledProfiles === (<Device>)
            Number of <Device> profiles found: 2 (Filtered: 0)
            Daemon response: { IsSupervised = 1; }
            Agent response: (null)
            """.utf8
        )
        #expect(try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: countTwo).isSupervised)

        let wrongScope = Data(
            """
            === CPF_GetInstalledProfiles === (<User>)
            Number of <Device> profiles found: 1 (Filtered: 0)
            Daemon response: { IsSupervised = 0; }
            Agent response: (null)
            """.utf8
        )
        #expect(throws: MDMEnrollmentEvidenceError.malformedEvidence) {
            try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: wrongScope)
        }

        let mergedDiagnostic = Data(
            """
            === CPF_GetInstalledProfiles === (<Device>)
            Number of <Device> profiles found: 1 (Filtered: 0)
            Daemon response: { IsSupervised = 0; }
            Agent response: (null)
            [ERROR] Unable to target 'local user' via XPC when running as daemon
            """.utf8
        )
        #expect(throws: MDMEnrollmentEvidenceError.malformedEvidence) {
            try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: mergedDiagnostic)
        }
    }

    @Test("Missing and malformed evidence is rejected and verify fails closed")
    func missingAndMalformedEvidence() throws {
        let source = try mobileconfig()
        let installed = try profilesShow()
        let validStatus = Data("MDM enrollment: Yes\nMDM server: \(serverURL)\n".utf8)
        let validDevice = Data("{ IsSupervised = 0; }\n".utf8)

        #expect(throws: MDMEnrollmentEvidenceError.missingEvidence) {
            try MDMEnrollmentEvidenceParser.parseProfileIdentity(fromMobileconfig: Data())
        }
        #expect(throws: MDMEnrollmentEvidenceError.malformedEvidence) {
            try MDMEnrollmentEvidenceParser.parseInstalledProfileIdentity(fromProfilesShow: Data("<plist/>".utf8))
        }
        #expect(throws: MDMEnrollmentEvidenceError.malformedEvidence) {
            try MDMEnrollmentEvidenceParser.parseInstalledProfileIdentity(fromProfilesShow: Data("not plist".utf8))
        }
        #expect(throws: MDMEnrollmentEvidenceError.missingEvidence) {
            try MDMEnrollmentEvidenceParser.parseEnrollmentStatus(fromProfilesStatus: Data("MDM server: \(serverURL)\n".utf8))
        }
        #expect(throws: MDMEnrollmentEvidenceError.malformedEvidence) {
            try MDMEnrollmentEvidenceParser.parseEnrollmentStatus(fromProfilesStatus: Data("MDM enrollment: maybe\n".utf8))
        }
        #expect(throws: MDMEnrollmentEvidenceError.missingEvidence) {
            try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: Data("{ SerialNumber = abc; }\n".utf8))
        }
        #expect(throws: MDMEnrollmentEvidenceError.malformedEvidence) {
            try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: Data("[ERROR] Unable to target local user via XPC\n".utf8))
        }

        #expect(!MDMEnrollmentEvidenceParser.verify(
            mobileconfig: source,
            profilesShow: installed,
            profilesStatus: Data("MDM enrollment: Yes\n".utf8),
            queryDeviceInformation: validDevice,
            mode: .unapproved
        ))
        #expect(!MDMEnrollmentEvidenceParser.verify(
            mobileconfig: source,
            profilesShow: installed,
            profilesStatus: validStatus,
            queryDeviceInformation: Data(),
            mode: .unapproved
        ))
    }

    @Test("Conflicting profile, status, and supervision evidence is rejected")
    func conflictingEvidence() throws {
        let duplicateMDM = try plistXML([
            "_computerlevel": [[
                "ProfileType": "Configuration",
                "ProfileIdentifier": identifier,
                "ProfileUUID": uuid.uuidString,
                "ProfileItems": [
                    ["PayloadType": "com.apple.mdm", "PayloadContent": ["ServerURL": serverURL]],
                    ["PayloadType": "com.apple.mdm", "PayloadContent": ["ServerURL": serverURL]]
                ]
            ]]
        ])
        #expect(throws: MDMEnrollmentEvidenceError.conflictingEvidence) {
            try MDMEnrollmentEvidenceParser.parseInstalledProfileIdentity(fromProfilesShow: duplicateMDM)
        }

        let conflictingStatus = Data(
            "MDM enrollment: Yes (User Approved)\nUser Approved: No\nMDM server: \(serverURL)\n".utf8
        )
        #expect(throws: MDMEnrollmentEvidenceError.conflictingEvidence) {
            try MDMEnrollmentEvidenceParser.parseEnrollmentStatus(fromProfilesStatus: conflictingStatus)
        }

        let conflictingSupervision = try plistXML([
            "IsSupervised": true,
            "DeviceInformation": ["IsSupervised": false]
        ])
        #expect(throws: MDMEnrollmentEvidenceError.conflictingEvidence) {
            try MDMEnrollmentEvidenceParser.parseDeviceSupervision(fromMDMClient: conflictingSupervision)
        }

        let twoSourcePayloads = try plistXML([
            "PayloadIdentifier": identifier,
            "PayloadUUID": uuid.uuidString,
            "PayloadType": "Configuration",
            "PayloadContent": [
                ["PayloadType": "com.apple.mdm", "ServerURL": serverURL],
                ["PayloadType": "com.apple.mdm", "ServerURL": serverURL]
            ]
        ])
        #expect(throws: MDMEnrollmentEvidenceError.conflictingEvidence) {
            try MDMEnrollmentEvidenceParser.parseProfileIdentity(fromMobileconfig: twoSourcePayloads)
        }

        let credentialedURL = try plistXML([
            "PayloadIdentifier": identifier,
            "PayloadUUID": uuid.uuidString,
            "PayloadType": "Configuration",
            "PayloadContent": [[
                "PayloadType": "com.apple.mdm",
                "ServerURL": "https://user:secret@10.200.2.165:9444/mdm?token=secret"
            ]]
        ])
        #expect(throws: MDMEnrollmentEvidenceError.malformedEvidence) {
            try MDMEnrollmentEvidenceParser.parseProfileIdentity(fromMobileconfig: credentialedURL)
        }

    }

    @Test("Mode verification never downgrades supervised evidence or upgrades unapproved evidence")
    func noDowngrade() throws {
        let source = try mobileconfig()
        let installed = try profilesShow()
        let supervisedStatus = Data("MDM enrollment: Yes (User Approved)\nMDM server: \(serverURL)\n".utf8)
        let unapprovedStatus = Data("MDM enrollment: Yes\nMDM server: \(serverURL)\n".utf8)
        let supervisedDevice = Data("{ IsSupervised = 1; }\n".utf8)
        let unapprovedDevice = Data("{ IsSupervised = 0; }\n".utf8)

        #expect(MDMEnrollmentEvidenceParser.verify(
            mobileconfig: source,
            profilesShow: installed,
            profilesStatus: supervisedStatus,
            queryDeviceInformation: supervisedDevice,
            mode: .supervised
        ))
        #expect(!MDMEnrollmentEvidenceParser.verify(
            mobileconfig: source,
            profilesShow: installed,
            profilesStatus: unapprovedStatus,
            queryDeviceInformation: unapprovedDevice,
            mode: .supervised
        ))
        #expect(!MDMEnrollmentEvidenceParser.verify(
            mobileconfig: source,
            profilesShow: installed,
            profilesStatus: supervisedStatus,
            queryDeviceInformation: supervisedDevice,
            mode: .unapproved
        ))
    }

    private func mobileconfig() throws -> Data {
        try plistXML([
            "PayloadIdentifier": identifier,
            "PayloadUUID": uuid.uuidString,
            "PayloadType": "Configuration",
            "PayloadContent": [
                ["PayloadType": "com.apple.security.pkcs12", "PayloadUUID": "fedcba98-7654-3210-fedc-ba9876543210"],
                ["PayloadType": "com.apple.mdm", "PayloadIdentifier": "\(identifier).mdm", "PayloadUUID": "11111111-2222-3333-4444-555555555555", "ServerURL": serverURL]
            ]
        ])
    }

    private func profilesShow() throws -> Data {
        try plistXML([
            "_computerlevel": [[
                "ProfileIdentifier": identifier,
                "ProfileUUID": uuid.uuidString,
                "ProfileType": "Configuration",
                "ProfileItems": [
                    ["PayloadType": "com.apple.mdm", "PayloadIdentifier": "\(identifier).mdm", "PayloadUUID": "11111111-2222-3333-4444-555555555555", "PayloadContent": ["ServerURL": serverURL]]
                ]
            ]],
            "_userLevel": []
        ])
    }

    private func plistXML(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
}
