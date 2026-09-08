import Foundation
import Testing

@Suite("MDM staging bootstrap path compatibility")
struct PommeMDMStagingHelperTests {
    private let path = "/private/var/db/pomme-mdm-bootstrap-12345678-1234-1234-1234-123456789abc.bin"

    @Test("Bootstrap transfer accepts only an exact lowercase UUID path")
    func bootstrapReceipt() throws {
        #expect(PommeMDMStagingHelper.isBootstrapPath(path))
        let receipt = try PommeMDMAuthenticatedFileTransferReceipt(
            destination: path, bytes: 10, sha256: String(repeating: "a", count: 64)
        )
        #expect(receipt.destination == path)
        for invalid in [
            path.replacingOccurrences(of: "/private/var", with: "/var"),
            path.replacingOccurrences(of: "/db/", with: "/db/../db/"),
            path.replacingOccurrences(of: "/db/", with: "/db//"),
            path.replacingOccurrences(of: "789abc", with: "789ABC"),
            path + "/child", path + ".extra", "/tmp/" + URL(fileURLWithPath: path).lastPathComponent,
        ] {
            #expect(!PommeMDMStagingHelper.isBootstrapPath(invalid))
            #expect(throws: PommeMDMEnrollmentError.self) {
                _ = try PommeMDMAuthenticatedFileTransferReceipt(
                    destination: invalid, bytes: 10, sha256: String(repeating: "a", count: 64)
                )
            }
        }
    }

    @Test("Sequoia codesign reports hashes after the runtime flags field")
    func signingDetails() {
        let prefix = "Identifier=com.github.weswhet.pomme.mdm-helper\nSignature=adhoc\nTeamIdentifier=not set\n"
        let flags = "CodeDirectory v=20500 size=2020 flags=0x10002(adhoc,runtime) hashes=57+2 location=embedded\n"
        #expect(PommeApplication.validMDMHelperSigningDetails(Data(), stderr: Data((prefix + flags).utf8)))
        #expect(!PommeApplication.validMDMHelperSigningDetails(Data(), stderr: Data((prefix + flags.replacingOccurrences(of: "adhoc,runtime", with: "adhoc")).utf8)))
    }

    @Test("Guest protocol paths preserve /private independently of host Foundation aliases")
    func lexicalGuestPaths() throws {
        let profile = "/private/var/db/pomme-mdm-enrollment/profile.mobileconfig"
        #expect(try MDMProfileStaging.destination(requestedPath: profile) == profile)
        #expect(GuestMDMEnrollment.isStagedProfilePath(profile))
        for invalid in [profile.replacingOccurrences(of: "/private/var", with: "/var"),
                        profile.replacingOccurrences(of: "/profile", with: "/../pomme-mdm-enrollment/profile"),
                        profile.replacingOccurrences(of: "/profile", with: "//profile")] {
            #expect(throws: (any Error).self) {
                _ = try MDMProfileStaging.destination(requestedPath: invalid)
            }
            #expect(!GuestMDMEnrollment.isStagedProfilePath(invalid))
        }
    }
}
