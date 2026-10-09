import Foundation
import Testing

@Suite("Start with a running helper")
struct StartExistingRuntimeTests {
    @Test("A paused VM in the requested boot mode is resumed")
    func resumesPausedVM() throws {
        for mode in [BootMode.normal, .recovery] {
            #expect(try PommeCore.existingRuntimeNeedsResume(
                status: ["vmState": "paused", "bootMode": mode.rawValue],
                bootMode: mode,
                displayName: "dev"
            ))
        }
    }

    @Test("A running VM in the requested boot mode is reused as is")
    func reusesRunningVM() throws {
        #expect(try !PommeCore.existingRuntimeNeedsResume(
            status: ["vmState": "running", "bootMode": "normal"],
            bootMode: .normal,
            displayName: "dev"
        ))
    }

    @Test("A VM in the other boot mode is refused with its actual state")
    func refusesOtherBootMode() {
        for (vmState, word) in [("paused", "paused"), ("running", "running")] {
            #expect {
                _ = try PommeCore.existingRuntimeNeedsResume(
                    status: ["vmState": vmState, "bootMode": "recovery"],
                    bootMode: .normal,
                    displayName: "dev"
                )
            } throws: { error in
                "\(error)".contains("dev is already \(word) in recovery boot mode")
            }
        }
    }
}
