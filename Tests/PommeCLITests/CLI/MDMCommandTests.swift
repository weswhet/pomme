import ArgumentParser
import Testing

@Suite("Direct MDM command")
struct MDMCommandTests {
    @Test func defaultsToSupervised() throws {
        let command = try MDMCommand.parse(["dev", "--profile", "enrollment.mobileconfig"])
        #expect(command.name == "dev")
        #expect(command.profile == "enrollment.mobileconfig")
        #expect(command.enrollmentMode == .supervised)
        #expect(!command.force)
    }

    @Test(arguments: ["supervised", "unapproved"])
    func explicitMode(_ mode: String) throws {
        let command = try MDMCommand.parse([
            "dev", "--profile", "enrollment.mobileconfig", "--enrollment-mode", mode,
            "--force", "--guest-path", "/private/var/db/pomme-mdm-enrollment/test.mobileconfig",
            "--timeout", "120", "--json"
        ])
        #expect(command.enrollmentMode.rawValue == mode)
        #expect(command.force)
        #expect(try command.timeout.value() == 120)
        #expect(command.guestPath?.hasSuffix("/test.mobileconfig") == true)
    }

    @Test(arguments: [
        ["dev"],
        ["dev", "--profile", "p", "--enrollment-mode", "automatic"],
        ["enroll", "dev", "--profile", "p"],
        ["approve", "dev", "--profile-identifier", "p"],
        ["dev", "--profile", "p", "--acknowledge-synthetic-approval"]
    ])
    func rejectsRemovedOrInvalidSyntax(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try MDMCommand.parse(arguments) }
    }
}
