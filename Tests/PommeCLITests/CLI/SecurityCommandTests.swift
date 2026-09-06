import ArgumentParser
import Testing

@Suite("Security command confirmation")
struct SecurityCommandTests {
  @Test func forceIsAcceptedOnlyForMutations() throws {
    #expect(try SIPEnableCommand.parse(["fresh", "--force"]).force)
    #expect(try SIPDisableCommand.parse(["fresh", "--force"]).force)
    #expect(try AMFIEnableCommand.parse(["fresh", "--force"]).force)
    #expect(try AMFIDisableCommand.parse(["fresh", "--force"]).force)
    #expect(throws: (any Error).self) { try SIPStatusCommand.parse(["fresh", "--force"]) }
    #expect(throws: (any Error).self) { try AMFIStatusCommand.parse(["fresh", "--force"]) }
  }

  @Test func mutationDefaultsToConfirmation() throws {
    #expect(try !SIPDisableCommand.parse(["fresh"]).force)
    #expect(try !AMFIDisableCommand.parse(["fresh"]).force)
  }
}
