import Foundation
import Testing

@Suite("Provisioned template manifests")
struct PommeProvisionedTemplateTests {
    private func manifest(owner: String?) -> PommeTemplateManifest {
        .init(
            name: "base",
            version: "26.6.2",
            build: "25G83",
            restoreImageDigest: String(repeating: "a", count: 64),
            restoreImagePath: "/images/UniversalMac.ipsw",
            diskSizeBytes: 40 * 1024 * 1024 * 1024,
            provisionedOwnerAccount: owner,
            provisionedSecurityDisabled: owner == nil ? nil : true
        )
    }

    @Test("An owner account marks the template provisioned and validates")
    func provisionedManifestValidates() throws {
        let provisioned = manifest(owner: "pomme")
        try provisioned.validate()
        #expect(provisioned.isProvisioned)
        #expect(provisioned.provisionedOwnerAccount == "pomme")
        #expect(provisioned.isSecurityDisabled)

        let installedOnly = manifest(owner: nil)
        try installedOnly.validate()
        #expect(!installedOnly.isProvisioned)
        #expect(!installedOnly.isSecurityDisabled)
    }

    @Test("An owner account that is not a safe local account name is rejected")
    func rejectsUnsafeOwnerAccount() {
        for unsafe in ["", "../../etc/passwd", "has space", String(repeating: "n", count: 65)] {
            #expect(throws: PommeTemplateError.invalidManifest) {
                try manifest(owner: unsafe).validate()
            }
        }
    }

    @Test("A manifest written before provisioned templates decodes as installed-only")
    func decodesLegacyManifest() throws {
        // The field is additive, so an older template on disk must keep
        // working and must not claim to carry an owner.
        let legacy = """
        {
          "schema": 1,
          "name": "base",
          "version": "26.6.2",
          "build": "25G83",
          "restoreImageDigest": "\(String(repeating: "a", count: 64))",
          "restoreImagePath": "/images/UniversalMac.ipsw",
          "diskSizeBytes": 42949672960,
          "createdAt": "2026-09-13T12:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PommeTemplateManifest.self, from: Data(legacy.utf8))
        try decoded.validate()
        #expect(decoded.provisionedOwnerAccount == nil)
        #expect(!decoded.isProvisioned)
        // A legacy template never claims the disabled-security posture.
        #expect(!decoded.isSecurityDisabled)
    }

    @Test("A provisioned manifest round-trips through the store encoding")
    func roundTripsThroughEncoding() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            PommeTemplateManifest.self, from: try encoder.encode(manifest(owner: "pomme")))
        #expect(decoded.provisionedOwnerAccount == "pomme")
        #expect(decoded.isProvisioned)
        #expect(decoded.isSecurityDisabled)
    }

    @Test("The provisioning VM name is derived from the template and is a valid VM name")
    func provisioningVMNameIsValid() throws {
        let derived = "base" + PommeProvisionedTemplate.provisioningSuffix
        #expect(derived == "base-provisioning")
        #expect(try validateVMName(derived) == derived)
    }
}
