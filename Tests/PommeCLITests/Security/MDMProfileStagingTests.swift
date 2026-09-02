import Foundation
import Testing

@Suite("MDM profile staging")
struct MDMProfileStagingTests {
    @Test("Default profile destinations stay below the fixed root-owned staging directory")
    func defaultDestination() throws {
        let destination = try MDMProfileStaging.destination(requestedPath: nil)
        #expect(URL(fileURLWithPath: destination).deletingLastPathComponent().path == MDMProfileStaging.guestDirectory)
        #expect(destination.hasSuffix(".mobileconfig"))
    }

    @Test("Requested guest paths must be direct staging-directory children")
    func requestedDestinationRestrictions() throws {
        let accepted = try MDMProfileStaging.destination(
            requestedPath: "\(MDMProfileStaging.guestDirectory)/requested.mobileconfig"
        )
        #expect(accepted == "\(MDMProfileStaging.guestDirectory)/requested.mobileconfig")

        #expect(throws: Error.self) {
            try MDMProfileStaging.destination(requestedPath: "/tmp/profile.mobileconfig")
        }
        #expect(throws: Error.self) {
            try MDMProfileStaging.destination(
                requestedPath: "\(MDMProfileStaging.guestDirectory)/nested/profile.mobileconfig"
            )
        }
        #expect(throws: Error.self) {
            try MDMProfileStaging.destination(
                requestedPath: "\(MDMProfileStaging.guestDirectory)/../profile.mobileconfig"
            )
        }
    }

    @Test("Live enrollment verifies PommeAgent before authenticated profile operations")
    func agentGatePrecedesAuthenticatedOperations() throws {
        let source = try applicationSource()
        let preflight = try #require(source.range(of: "expectedProvisionedAgentDigest("))
        let transaction = try #require(source.range(of: "let transaction = PommeMDMEnrollmentTransaction("))
        let transfer = try #require(source.range(of: "private static func transferMDMProfile("))

        #expect(preflight.lowerBound < transaction.lowerBound)
        #expect(transaction.lowerBound < transfer.lowerBound)
        #expect(source.contains("operation: \"agent.describe\""))
        #expect(source.contains("operation: \"file.open\""))
        #expect(source.contains("operation: \"file.write\""))
        #expect(source.contains("operation: \"file.commit\""))
        #expect(source.contains("try await transaction.execute()"))
        #expect(!source.contains("\"operation\": \"file.remove\""))
    }

    @Test("Enrollment errors redact credentials and private details")
    func errorsAreRedacted() {
        let error = SensitiveFailure()
        #expect(MDMEnrollmentRedaction.errorMessage(error) == "MDM enrollment failed; sensitive details were redacted.")
    }

    private func applicationSource() throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent("Sources/PommeCLI/Operations/PommeApplication.swift"),
            encoding: .utf8
        )
    }

    private struct SensitiveFailure: LocalizedError {
        var errorDescription: String? { "Password rejected for /private/var/db/pomme-mdm-enrollment." }
    }
}
