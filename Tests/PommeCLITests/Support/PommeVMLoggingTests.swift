import Foundation
import Synchronization
import Testing

@Suite("VM-scoped logging")
struct PommeVMLoggingTests {
    @Test("provisioning failure text identifies the retained VM")
    func provisioningFailureNamesVM() {
        let error = PommeProvisioningError.phaseFailed(.installRecoveryAgent, vmName: "dev")

        #expect(error.localizedDescription ==
            "dev provisioning phase installRecoveryAgent failed; the VM and journal were retained.")
    }

    @Test("installer progress identifies the VM", arguments: [0.0, 0.5, 1.0])
    func installProgress(fraction: Double) async {
        let capture = PommeVMLogCapture()

        await PommeCore.withLogSink(capture.append) {
            PommeCore.logInstallProgress(fractionCompleted: fraction, vmName: "dev")
        }

        #expect(capture.values == ["dev install progress: \(Int(fraction * 100))%"])
    }

    @Test("concurrent VM logs retain their own names without leaking into global logs")
    func concurrentVMNames() async {
        let capture = PommeVMLogCapture()
        let names = ["dev", "qa", "batch-26.6.2"]

        await PommeCore.withLogSink(capture.append) {
            await withTaskGroup(of: Void.self) { group in
                for name in names {
                    group.addTask {
                        for index in 0..<16 {
                            PommeCore.log("milestone \(index)", vmName: name)
                            await Task.yield()
                        }
                    }
                }
            }
            PommeCore.log("Batch complete.")
        }

        let expected = Set(names.flatMap { name in
            (0..<16).map { "\(name) milestone \($0)" }
        } + ["Batch complete."])
        #expect(capture.values.count == expected.count)
        #expect(Set(capture.values) == expected)
        #expect(capture.values.last == "Batch complete.")
    }

    @Test("VM attribution preserves single-line log sanitization")
    func singleLineMessages() async {
        let capture = PommeVMLogCapture()

        await PommeCore.withLogSink(capture.append) {
            PommeCore.log("install progress: 0%\nextra", vmName: "dev\r\nname")
        }

        #expect(capture.values == ["dev name install progress: 0% extra"])
    }

    @Test("Recovery lock-wait diagnostics identify the VM")
    func recoveryWaitNamesVM() async {
        let capture = PommeVMLogCapture()

        await #expect(throws: PommeLiveRecoveryIntegration.Error.runtimeRejected) {
            try await PommeCore.withLogSink(capture.append) {
                try await PommeCore.waitForLiveRecoveryAuxiliaryStorageRelease(
                    at: URL(fileURLWithPath: "/tmp/pomme-log-test-not-opened"),
                    vmName: "qa",
                    maxRetries: 1,
                    retryDelayNanoseconds: 0,
                    hasConflict: { _ in true },
                    sleep: { _ in }
                )
            }
        }

        #expect(capture.values == [
            "qa Recovery bootstrap milestone: auxiliaryStorageReleaseWait 1/1."
        ])
    }
}

/// A synchronous log sink whose captured values are protected by one mutex.
final class PommeVMLogCapture: Sendable {
    private let messages = Mutex<[String]>([])

    func append(_ message: String) {
        messages.withLock { $0.append(message) }
    }

    var values: [String] { messages.withLock { $0 } }
}
