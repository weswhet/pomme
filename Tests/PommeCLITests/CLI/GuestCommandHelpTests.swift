import Foundation
import Testing

@Suite("Guest command help")
struct GuestCommandHelpTests {
    /// `vm` is a legal VM name, so a placeholder spelled `vm:/path` reads as a
    /// literal and sends the operator after a VM that does not exist.
    @Test("cp and cat spell the endpoint placeholder as NAME:/absolute/path")
    func endpointPlaceholder() {
        #expect(CopyCommand.helpMessage().contains("NAME:/absolute/path"))
        #expect(CatCommand.helpMessage().contains("NAME:/absolute/path"))
        #expect(!CopyCommand.helpMessage().contains("vm:/"))
        #expect(!CatCommand.helpMessage().contains("vm:/"))
    }

    @Test("cat without an endpoint shows the endpoint form with an example")
    func catEndpointError() throws {
        var command = try CatCommand.parse(["/tmp/x"])
        do {
            try command.run()
            Issue.record("A host path was accepted as a cat endpoint.")
        } catch {
            #expect(CatCommand.fullMessage(for: error).contains("NAME:/absolute/path"))
        }
    }
}
