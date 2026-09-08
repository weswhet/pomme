import Foundation
import Testing

@Suite("Guest MDM observation")
struct GuestMDMObservationTests {
    @Test("Structured profiles output returns the exact device profile identity")
    func parsesExactInstalledIdentity() throws {
        let identifier = "org.example.mdm"
        let uuid = "11111111-1111-1111-1111-111111111111"
        let serverURL = "https://mdm.example.test/server"
        var capturedTimeout: TimeInterval?
        var capturedLimit: Int?
        let output = try profilesShowOutput(
            identifier: identifier,
            uuid: uuid,
            serverURL: serverURL
        )
        let observation = GuestMDMObservation(profilesShowRunner: { timeout, limit in
            capturedTimeout = timeout
            capturedLimit = limit
            return output
        })

        let identity = try observation.installedProfileIdentity(timeout: 7)
        #expect(identity?.identifier == identifier)
        #expect(identity?.uuid == UUID(uuidString: uuid))
        #expect(identity?.serverURL == serverURL)
        #expect(capturedTimeout == 7)
        #expect(capturedLimit == GuestMDMObservation.defaultMaximumOutputBytes)
    }

    @Test("No device MDM profile is represented by nil")
    func noInstalledProfileIsNil() throws {
        let output = try PropertyListSerialization.data(
            fromPropertyList: ["_computerlevel": []],
            format: .xml,
            options: 0
        )
        let observation = GuestMDMObservation(profilesShowRunner: { _, _ in output })
        #expect(try observation.installedProfileIdentity(timeout: 1) == nil)
    }

    @Test("Observation validates timeout and injected output cap before parsing")
    func observationBoundsAreEnforced() {
        var invoked = false
        let observation = GuestMDMObservation(profilesShowRunner: { _, _ in
            invoked = true
            return Data([1, 2])
        })
        #expect(throws: GuestMDMObservationError.invalidTimeout) {
            try observation.installedProfileIdentity(timeout: 0.5)
        }
        #expect(!invoked)
        #expect(throws: GuestMDMObservationError.outputTooLarge) {
            try observation.installedProfileIdentity(timeout: 1, maximumOutputBytes: 1)
        }
    }

    @Test("Conflicting structured profiles evidence remains a parser failure")
    func conflictingProfilesAreRejected() throws {
        let profile: [String: Any] = [
            "ProfileType": "Configuration",
            "ProfileIdentifier": "org.example.mdm",
            "ProfileUUID": "11111111-1111-1111-1111-111111111111",
            "ProfileItems": [[
                "PayloadType": "com.apple.mdm",
                "PayloadContent": ["ServerURL": "https://mdm.example.test/server"]
            ]]
        ]
        let second = profile.merging(["ProfileIdentifier": "org.example.other"]) { _, new in new }
        let output = try PropertyListSerialization.data(
            fromPropertyList: ["_computerlevel": [profile, second]],
            format: .xml,
            options: 0
        )
        let observation = GuestMDMObservation(profilesShowRunner: { _, _ in output })
        #expect(throws: MDMEnrollmentEvidenceError.conflictingEvidence) {
            try observation.installedProfileIdentity(timeout: 1)
        }
    }

    private func profilesShowOutput(
        identifier: String,
        uuid: String,
        serverURL: String
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "_computerlevel": [[
                    "ProfileType": "Configuration",
                    "ProfileIdentifier": identifier,
                    "ProfileUUID": uuid,
                    "ProfileItems": [[
                        "PayloadType": "com.apple.mdm",
                        "PayloadContent": ["ServerURL": serverURL]
                    ]]
                ]]
            ],
            format: .xml,
            options: 0
        )
    }
}
