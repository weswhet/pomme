import Foundation
import Testing

@Suite("Pomme Recovery diagnostics")
struct PommeRecoveryDiagnosticsTests {
    @Test("Diagnostics redact paths, credentials, and raw errors")
    func redacted() throws {
        struct Sensitive: LocalizedError {
            var errorDescription: String? {
                "Password token secret at /private/var/db/pomme/private"
            }
        }
        let diagnostic = PommeRecoveryDiagnosticRedactor.make(
            error: Sensitive(),
            stage: .authentication
        )
        let payload = PommeRecoveryDiagnosticRedactor.payload(diagnostic)
        let serialized = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        #expect(!serialized.contains("Password"))
        #expect(!serialized.contains("private/var"))
        #expect(!serialized.contains("secret"))
        #expect(payload["code"] as? String == "authenticationRejected")
    }

    @Test("Owned Recovery sources contain no removed alternate-path vocabulary")
    func prohibitedStringsAbsent() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = repository.appendingPathComponent("Sources/PommeCLI/Security")
        let excluded = Set(["MDMEnrollment.swift", "MDMEnrollmentModels.swift"])
        let forbidden: [String] = ([
            [102, 97, 108, 108, 98, 97, 99, 107],
            [97, 112, 112, 108, 101, 113, 103, 97],
            [110, 97, 116, 105, 118, 101, 101, 120, 101, 99, 117, 116, 105, 111, 110],
            [116, 114, 97, 110, 115, 112, 111, 114, 116, 115, 101, 108, 101, 99, 116, 105, 111, 110],
            [99, 111, 109, 112, 97, 116, 105, 98, 105, 108, 105, 116, 121]
        ] as [[UInt8]]).map { String(decoding: $0, as: UTF8.self) }
        for file in try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" && !excluded.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            for term in forbidden { #expect(!text.contains(term), "\(file.lastPathComponent) contains \(term)") }
        }
    }
}
