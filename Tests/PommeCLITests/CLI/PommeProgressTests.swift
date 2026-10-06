import Foundation
import Testing

@Suite("Command progress")
struct PommeProgressTests {
    @Test("Animation waits and replaces steps independently")
    func animation() {
        let harness = ProgressHarness()
        let session = harness.session()
        session.sink.step(vm: "dev", "Preparing")
        session.tick()
        #expect(harness.output.isEmpty)
        harness.time = 0.21
        session.tick()
        #expect(harness.output.contains("dev · Preparing"))
        harness.clear()
        session.sink.step(vm: "dev", "Launching Terminal")
        harness.time = 0.4
        session.tick()
        #expect(harness.output.contains("Launching Terminal"))
        #expect(!harness.output.contains("Preparing"))
        session.finish()
        #expect(harness.output.hasSuffix("\r\u{001B}[2K"))
        harness.clear()
        session.tick()
        session.finish()
        #expect(harness.output.isEmpty)
    }

    @Test("Plain steps deduplicate and measured progress throttles")
    func plain() {
        let harness = ProgressHarness()
        let session = harness.session(mode: .plain)
        session.sink.step(vm: "dev", "Preparing")
        session.sink.step(vm: "dev", "Preparing")
        session.sink.measured(vm: "dev", "Installing", fraction: 0.1)
        session.sink.measured(vm: "dev", "Installing", fraction: 0.2)
        harness.time = 6
        session.sink.measured(vm: "dev", "Installing", fraction: 0.3)
        session.sink.measured(vm: "dev", "Installing", fraction: 1)
        #expect(harness.output.split(separator: "\n").count == 4)
        #expect(!harness.output.contains("20%"))
        #expect(harness.output.contains("100%"))
        #expect(!harness.output.contains("\u{001B}"))
    }

    @Test("Structured auto and off suppress progress but preserve warnings")
    func modes() {
        for mode in [CLIProgressMode.auto, .off] {
            let harness = ProgressHarness()
            let session = harness.session(mode: mode, structured: true)
            session.sink.step(vm: nil, "Hidden")
            session.sink.warning("Action needed")
            #expect(harness.output == "Action needed\n")
        }
        let harness = ProgressHarness()
        let session = harness.session(mode: .plain, structured: true)
        session.sink.step(vm: nil, "Visible")
        #expect(harness.output == "Visible · 0s\n")
    }

    @Test("Debug, dumb terminals, and redirected output use plain progress")
    func fallback() {
        for variant in 0..<3 {
            let harness = ProgressHarness()
            let session = harness.session(debug: variant == 0, environment: variant == 1 ? ["TERM": "dumb"] : ["LANG": "en_US.UTF-8"], isTerminal: variant != 2)
            session.sink.step(vm: nil, "Preparing")
            session.sink.diagnostic("Detail")
            #expect(harness.output == (variant == 0 ? "Preparing · 0s\nDetail\n" : "Preparing · 0s\n"))
        }
    }

    @Test("Parallel status rotates and retains completion count")
    func parallel() {
        let harness = ProgressHarness()
        let session = harness.session(width: 48)
        session.sink.step(vm: "first", "Preparing first guest")
        session.sink.step(vm: "second", "Preparing second guest")
        harness.time = 0.3
        session.tick()
        #expect(harness.output.contains("first"))
        #expect(harness.output.contains("0/2"))
        harness.clear()
        harness.time = 2.3
        session.tick()
        #expect(harness.output.contains("second"))
        session.sink.complete(vm: "first")
        harness.clear()
        session.tick()
        #expect(harness.output.contains("1/2"))
    }

    @Test("Registered queued VMs count toward total without displacing active work")
    func pendingMembers() {
        let harness = ProgressHarness()
        let session = harness.session(width: 100)
        for vm in ["one", "two", "three"] { session.sink.register(vm: vm) }
        harness.time = 1
        session.tick()
        #expect(harness.output.isEmpty)
        session.sink.step(vm: "one", "Installing")
        session.sink.step(vm: "two", "Installing")
        session.tick()
        #expect(harness.output.contains("one"))
        #expect(harness.output.contains("two"))
        #expect(harness.output.contains("0/3"))
        #expect(!harness.output.contains("three"))
        #expect(!harness.output.contains("Queued"))
    }

    @Test("Handoff permanently clears progress while retaining warnings")
    func handoff() {
        let harness = ProgressHarness()
        let session = harness.session()
        session.sink.step(vm: nil, "Preparing")
        harness.time = 1
        session.tick()
        session.sink.suspend()
        harness.clear()
        session.sink.step(vm: nil, "Hidden")
        session.tick()
        session.sink.warning("Warning")
        #expect(harness.output == "Warning\n")
    }

    @Test("Prompt pause clears progress and resumes the latest step")
    func promptPause() {
        for mode in [CLIProgressMode.auto, .plain] {
            let harness = ProgressHarness()
            let session = harness.session(mode: mode)
            session.sink.step(vm: "dev", "Preparing")
            harness.time = 1
            session.tick()
            session.sink.pause()
            if mode == .auto { #expect(harness.output.hasSuffix("\r\u{001B}[2K")) }
            harness.clear()
            session.sink.step(vm: "dev", "Waiting for confirmation")
            session.sink.step(vm: "dev", "Deleting VM")
            session.tick()
            #expect(harness.output.isEmpty)
            session.sink.resume()
            session.tick()
            #expect(harness.output.contains("Deleting VM"))
            #expect(!harness.output.contains("Waiting for confirmation"))
            harness.clear()
            session.sink.pause()
            session.sink.suspend()
            harness.clear()
            session.sink.resume()
            session.tick()
            #expect(harness.output.isEmpty)
        }
    }

    @Test("Narrow lines, control sanitization, Unicode widths, and color opt-out")
    func width() {
        for width in [1, 8, 20, 48, 100] {
            let harness = ProgressHarness()
            let session = harness.session(width: width, environment: ["LANG": "en_US.UTF-8", "NO_COLOR": ""])
            session.sink.measured(vm: "vm\n\u{001B}", "Downloading 界 image", fraction: 0.5, completedBytes: 1_024, totalBytes: 2_048)
            harness.time = 1
            session.tick()
            let line = harness.output.replacingOccurrences(of: "\r\u{001B}[2K", with: "")
            #expect(PommeProgressSession.displayWidth(line) <= max(1, width - 1))
            #expect(!line.contains("\n"))
            #expect(!line.contains("\u{001B}"))
        }
        #expect(PommeProgressSession.sanitize("a\u{0085}b\u{202E}c") == "abc")
        #expect(PommeProgressSession.displayWidth("界") == 2)
    }

    @Test("Long measured labels preserve percentages and setup clears them")
    func measuredLabelBudget() {
        for width in [40, 60] {
            let harness = ProgressHarness()
            let session = harness.session(width: width)
            session.sink.measured(vm: "development", "Installing macOS with a very long description", fraction: 1)
            harness.time = 1
            session.tick()
            #expect(harness.output.contains("100%"))
            #expect(harness.output.contains("██"))
            #expect(harness.output.contains("1s"))
            harness.clear()
            session.sink.step(vm: "development", "Preparing owner account")
            session.tick()
            #expect(!harness.output.contains("%"))
        }
    }

    @Test("Parallel measured statuses shrink details before rotating")
    func parallelMeasured() {
        let harness = ProgressHarness()
        let session = harness.session(width: 68)
        session.sink.measured(vm: "one", "Installing", fraction: 0.5, completedBytes: 1_024, totalBytes: 2_048)
        session.sink.measured(vm: "two", "Installing", fraction: 0.5, completedBytes: 1_024, totalBytes: 2_048)
        harness.time = 1
        session.tick()
        #expect(harness.output.contains("one"))
        #expect(harness.output.contains("two"))
    }

    @Test("Download rate excludes resumed bytes and shows version and ETA at 80 columns")
    func downloadRate() {
        let harness = ProgressHarness()
        let session = harness.session(width: 80)
        let mib: Int64 = 1_048_576
        session.sink.measured(vm: "dev", "Downloading IPSW 27.0", fraction: 0.5, completedBytes: 500 * mib, totalBytes: 1_000 * mib)
        harness.time = 0.3
        session.tick()
        #expect(!harness.output.contains("/s"))
        harness.clear()
        harness.time = 1
        session.sink.measured(vm: "dev", "Downloading IPSW 27.0", fraction: 0.58, completedBytes: 580 * mib, totalBytes: 1_000 * mib)
        session.tick()
        #expect(harness.output.contains("27.0"))
        #expect(harness.output.contains("80.0 MiB/s"))
        #expect(harness.output.contains("ETA 6s"))
        #expect(harness.output.contains("58%"))
        let line = harness.output.replacingOccurrences(of: "\r\u{001B}[2K", with: "")
        #expect(PommeProgressSession.displayWidth(line) < 80)
    }

    @Test("Long VM names yield space to the resolved version, rate, and ETA")
    func downloadLongVM() {
        let harness = ProgressHarness()
        let session = harness.session(width: 80)
        let vm = "pomme-agent-long-development-download-name"
        session.sink.measured(vm: vm, "Downloading IPSW 27.0", fraction: 0, completedBytes: 0, totalBytes: 100_000_000)
        harness.time = 1
        session.sink.measured(vm: vm, "Downloading IPSW 27.0", fraction: 0.1, completedBytes: 10_000_000, totalBytes: 100_000_000)
        session.tick()
        #expect(harness.output.contains("27.0"))
        #expect(harness.output.contains("9.5 MiB/s"))
        #expect(harness.output.contains("ETA 9s"))
        #expect(harness.output.contains("10%"))
        #expect(!harness.output.contains(vm))
        #expect(!harness.output.contains("95.4 MiB"))
    }

    @Test("Percentage formatting corrects floating-point error without early completion")
    func percentagePrecision() {
        for mode in [CLIProgressMode.auto, .plain] {
            for (fraction, expected) in [(0.58, 58), (0.29, 29), (0.9999999999999999, 99), (1.0, 100)] {
                let harness = ProgressHarness()
                let session = harness.session(mode: mode)
                session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: fraction)
                harness.time = 1
                session.tick()
                #expect(harness.output.contains("\(expected)%"))
            }
        }
    }

    @Test("Download rate follows a recent window and decays to zero during stalls")
    func downloadStall() {
        let harness = ProgressHarness()
        let session = harness.session(width: 120)
        let mib: Int64 = 1_048_576
        session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: 0, completedBytes: 0, totalBytes: 10_000 * mib)
        for second in 1...6 {
            harness.time = Double(second)
            let bytes = Int64(second == 1 ? 100 : 100 + (second - 1) * 20) * mib
            session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: Double(bytes) / Double(10_000 * mib), completedBytes: bytes, totalBytes: 10_000 * mib)
        }
        session.tick()
        #expect(harness.output.contains("20.0 MiB/s"))
        harness.clear()
        harness.time = 11
        session.tick()
        #expect(harness.output.contains("0 B/s"))
        #expect(!harness.output.contains("ETA"))
    }

    @Test("Restart, completion, and new steps discard transfer estimates")
    func downloadReset() {
        let harness = ProgressHarness()
        let session = harness.session(width: 120)
        let mib: Int64 = 1_048_576
        session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: 0.5, completedBytes: 500 * mib, totalBytes: 1_000 * mib)
        harness.time = 1
        session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: 0.6, completedBytes: 600 * mib, totalBytes: 1_000 * mib)
        session.tick()
        #expect(harness.output.contains("100.0 MiB/s"))
        harness.clear()
        harness.time = 2
        session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: 0, completedBytes: 0, totalBytes: 1_000 * mib)
        session.tick()
        #expect(!harness.output.contains("/s"))
        harness.clear()
        harness.time = 3
        session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: 0.04, completedBytes: 40 * mib, totalBytes: 1_000 * mib)
        session.tick()
        #expect(harness.output.contains("40.0 MiB/s"))
        harness.clear()
        session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: 1, completedBytes: 1_000 * mib, totalBytes: 1_000 * mib)
        session.tick()
        #expect(!harness.output.contains("/s"))
        #expect(!harness.output.contains("ETA"))
        harness.clear()
        session.sink.step(vm: nil, "Verifying IPSW 27.0")
        session.tick()
        #expect(!harness.output.contains("%"))
        #expect(!harness.output.contains("/s"))
    }

    @Test("Plain download updates are periodic even within the same percentage")
    func plainDownloadRate() {
        let harness = ProgressHarness()
        let session = harness.session(mode: .plain, environment: ["LANG": "C"])
        session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: 0, completedBytes: 0, totalBytes: 1_000_000)
        for second in 1...10 {
            harness.time = Double(second)
            session.sink.measured(vm: nil, "Downloading IPSW 27.0", fraction: 0, completedBytes: Int64(second * 100), totalBytes: 1_000_000)
        }
        #expect(harness.output.split(separator: "\n").count == 3)
        #expect(harness.output.contains("100 B/s"))
        #expect(harness.output.contains("ETA"))
        #expect(harness.output.unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test("Narrow download lines shed counters before rate and never wrap")
    func downloadWidth() {
        for width in [20, 40, 60, 80, 120] {
            let harness = ProgressHarness()
            let session = harness.session(width: width, environment: ["LANG": "en_US.UTF-8", "NO_COLOR": ""])
            session.sink.measured(vm: "dev", "Downloading IPSW 27.0", fraction: 0, completedBytes: 0, totalBytes: 100_000_000)
            harness.time = 1
            session.sink.measured(vm: "dev", "Downloading IPSW 27.0", fraction: 0.1, completedBytes: 10_000_000, totalBytes: 100_000_000)
            session.tick()
            let line = harness.output.replacingOccurrences(of: "\r\u{001B}[2K", with: "")
            #expect(PommeProgressSession.displayWidth(line) < width)
            if width == 80 {
                #expect(line.contains("27.0"))
                #expect(line.contains("9.5 MiB/s"))
                #expect(line.contains("ETA 9s"))
            }
        }
    }

    @Test("Rectangle frames keep four cells and spin a gap around the outline")
    func rectangle() {
        let frames = PommeProgressSession.rectangleFrames
        let perimeter = PommeProgressSession.rectanglePerimeter.map { "\($0.x),\($0.y)" }
        #expect(perimeter.count == 20 && Set(perimeter).count == 20)
        #expect(frames.count == perimeter.count && Set(frames).count == frames.count)

        // Decodes a frame into the "x,y" dots it lights.
        func dots(_ frame: String) -> Set<String> {
            let bits = [[0, 1, 2, 6], [3, 4, 5, 7]]
            let cells = frame.unicodeScalars.map { $0.value - 0x2800 }
            var lit: Set<String> = []
            for x in 0..<8 {
                for y in 0..<4 where cells[x / 2] & (1 << bits[x % 2][y]) != 0 {
                    lit.insert("\(x),\(y)")
                }
            }
            return lit
        }

        for (index, frame) in frames.enumerated() {
            #expect(frame.unicodeScalars.count == 4)
            #expect(frame.unicodeScalars.allSatisfy { (0x2800...0x28FF).contains($0.value) })
            #expect(PommeProgressSession.displayWidth(frame) == 4)
            let hidden = (0..<3).map { perimeter[(index + $0) % perimeter.count] }
            #expect(dots(frame) == Set(perimeter).subtracting(hidden), "frame \(index)")
        }
    }

    @Test("Non-Unicode terminals use ASCII and invalid measurements stay finite")
    func ascii() {
        let harness = ProgressHarness()
        let session = harness.session(environment: ["LANG": "C"])
        session.sink.measured(vm: "dev", "Installing", fraction: .nan)
        harness.time = 1
        session.tick()
        #expect(harness.output.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(!harness.output.contains("%"))
    }
}

private final class ProgressHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTime: TimeInterval = 0
    private var storedOutput = ""
    var time: TimeInterval {
        get { lock.withLock { storedTime } }
        set { lock.withLock { storedTime = newValue } }
    }
    var output: String { lock.withLock { storedOutput } }
    func clear() { lock.withLock { storedOutput = "" } }
    func session(mode: CLIProgressMode = .auto, structured: Bool = false, debug: Bool = false, width: Int = 100, environment: [String: String] = ["LANG": "en_US.UTF-8"], isTerminal: Bool = true) -> PommeProgressSession {
        PommeProgressSession(mode: mode, structuredOutput: structured, debug: debug, environment: environment, clock: { self.time }, write: { text in self.lock.withLock { self.storedOutput += text } }, terminalWidth: { width }, isTerminal: isTerminal, startTimer: false, signalCleanup: false)
    }
}
