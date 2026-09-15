import Foundation
import Testing

@Suite("Identifier validation")
struct IdentifierValidationTests {
    @Test("Rejections name the kind of identifier", arguments: [
        (PommeIdentifierKind.vm, "Invalid VM name bad/name."),
        (PommeIdentifierKind.snapshot, "Invalid snapshot name bad/name."),
        (PommeIdentifierKind.template, "Invalid template name bad/name."),
        (PommeIdentifierKind.configDerived, "Invalid config-derived VM name bad/name."),
    ])
    func rejectionsNameTheKind(kind: PommeIdentifierKind, expectedPrefix: String) {
        do {
            _ = try validateIdentifier("bad/name", kind: kind)
            Issue.record("bad/name was accepted as a \(kind.rawValue).")
        } catch {
            #expect(error.localizedDescription.hasPrefix(expectedPrefix))
            #expect(error.localizedDescription.contains("Use 1-64 ASCII letters"))
        }
    }

    @Test("The VM name wrapper keeps its wording and accepts managed names")
    func vmNameWrapper() throws {
        #expect(try validateVMName("dev-1.0_a") == "dev-1.0_a")
        do {
            _ = try validateVMName("-leading")
            Issue.record("A leading hyphen was accepted.")
        } catch {
            #expect(error.localizedDescription.hasPrefix("Invalid VM name -leading."))
        }
    }
}
