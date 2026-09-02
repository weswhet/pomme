import Foundation
import Testing

@Suite("Recovery agent progress renderer")
struct RecoveryAgentProgressRendererTests {
    @Test("Interactive progress animates and restores the cursor")
    func interactiveCursorLifecycle() {
        let output = LockedProgressOutput()
        let renderer = RecoveryAgentProgressRenderer(
            vmName: "recovery-vm",
            debug: false,
            helperLogPath: "/tmp/helper.log",
            interactive: true,
            write: output.append
        )
        renderer.update(stage: .waitingForRecovery)
        renderer.update(stage: .openingTerminal)
        renderer.finish()

        #expect(output.value.contains("\u{001B}[?25l"))
        #expect(output.value.contains("recovery-vm openingTerminal"))
        #expect(output.value.contains("\u{001B}[?25h"))
    }

    @Test("Noninteractive progress emits one line per transition")
    func noninteractiveTransitions() {
        let output = LockedProgressOutput()
        let renderer = RecoveryAgentProgressRenderer(
            vmName: "vm\nunsafe",
            debug: false,
            helperLogPath: "/tmp/helper.log",
            interactive: false,
            write: output.append
        )
        renderer.update(stage: .transferring)
        renderer.update(stage: .transferring)
        renderer.update(stage: .connecting)
        renderer.finish()

        let lines = output.value.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(!output.value.contains("vm\nunsafe"))
        #expect(output.value.contains("stage=transferring"))
        #expect(output.value.contains("stage=connecting"))
    }
}

private final class LockedProgressOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String { lock.withLock { stored } }
    func append(_ text: String) { lock.withLock { stored += text } }
}
