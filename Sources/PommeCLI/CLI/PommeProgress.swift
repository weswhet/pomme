import ArgumentParser
import Darwin
import Dispatch
import Foundation

enum CLIProgressMode: String, CaseIterable, ExpressibleByArgument {
    case auto, plain, off
}

enum PommeProgressContext {
    @TaskLocal static var sink: PommeProgressSink?
    @TaskLocal static var debugEnabled = false
}

struct PommeProgressSink: Sendable {
    fileprivate let receive: @Sendable (PommeProgressEvent) -> Void

    func register(vm: String) { receive(.register(vm)) }
    func step(vm: String?, _ label: String) { receive(.step(vm, label, nil, nil, nil)) }
    func measured(vm: String?, _ label: String, fraction: Double?, completedBytes: Int64? = nil, totalBytes: Int64? = nil) {
        receive(.step(vm, label, fraction, completedBytes, totalBytes))
    }
    func warning(_ message: String) { receive(.warning(message)) }
    func complete(vm: String?) { receive(.complete(vm)) }
    func suspend() { receive(.suspend) }
    func pause() { receive(.pause) }
    func resume() { receive(.resume) }
    func diagnostic(_ message: String) { receive(.diagnostic(message)) }
}

fileprivate enum PommeProgressEvent: Sendable {
    case register(String)
    case step(String?, String, Double?, Int64?, Int64?)
    case warning(String), diagnostic(String), complete(String?), suspend, pause, resume
}

// Runs without Swift locks, allocation, or session access. Preserve the default
// signal exit behavior after removing the transient terminal line.
private func clearPommeProgressOnSignal(_ number: Int32) {
    let clear: StaticString = "\r\u{001B}[2K"
    _ = Darwin.write(STDERR_FILENO, clear.utf8Start, clear.utf8CodeUnitCount)
    Darwin.signal(number, SIG_DFL)
    Darwin.raise(number)
}

/// Owns presentation only; existing workflow signal handlers take precedence.
final class PommeProgressSession: @unchecked Sendable {
    private struct ByteSample {
        var time: TimeInterval
        var bytes: Int64
    }

    private struct Status {
        var vm: String?
        var label: String
        var fraction: Double?
        var bytes: Int64?
        var total: Int64?
        var complete = false
        var pending = false
        var lastPlainLabel: String?
        var lastPlainTime: TimeInterval = -.infinity
        var lastPlainPercent: Int?
        var samples: [ByteSample] = []
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let write: @Sendable (String) -> Void
    private let terminalWidth: @Sendable () -> Int
    private let startedAt: TimeInterval
    private let animated: Bool
    private let enabled: Bool
    private let debug: Bool
    private let unicode: Bool
    private let color: Bool
    private let signalCleanup: Bool
    private var statuses: [Status] = []
    private var timer: DispatchSourceTimer?
    private var visible = false
    private var stopped = false
    private var paused = false
    private var finished = false
    private var cleanupSignals: [(number: Int32, action: sigaction)] = []

    init(
        mode: CLIProgressMode,
        structuredOutput: Bool,
        debug: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        write: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
        terminalWidth: @escaping @Sendable () -> Int = PommeProgressSession.currentTerminalWidth,
        isTerminal: Bool = isatty(STDERR_FILENO) == 1,
        startTimer: Bool = true,
        signalCleanup: Bool = true
    ) {
        self.clock = clock
        self.write = write
        self.terminalWidth = terminalWidth
        startedAt = clock()
        self.debug = debug
        self.signalCleanup = signalCleanup
        enabled = mode != .off && (!structuredOutput || mode == .plain)
        animated = enabled && mode == .auto && !debug && isTerminal && environment["TERM"] != "dumb"
        let locale = environment["LC_ALL"] ?? environment["LC_CTYPE"] ?? environment["LANG"] ?? ""
        unicode = locale.lowercased().contains("utf") || locale.isEmpty
        color = animated && environment["NO_COLOR"] == nil
        if animated && startTimer {
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            source.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    var sink: PommeProgressSink {
        PommeProgressSink { [weak self] event in self?.receive(event) }
    }

    private func receive(_ event: PommeProgressEvent) {
        lock.withLock {
            switch event {
            case .register(let vm):
                guard enabled, !finished, !stopped, !statuses.contains(where: { $0.vm == vm }) else { return }
                statuses.append(Status(vm: vm, label: "Queued", pending: true))
            case .warning(let message):
                clearLine()
                write(Self.sanitize(message) + "\n")
            case .diagnostic(let message):
                guard debug else { return }
                clearLine()
                write(Self.sanitize(message) + "\n")
            case .suspend:
                stop()
            case .pause:
                guard !finished, !stopped else { return }
                paused = true
                clearLine()
                removeSignalCleanup()
            case .resume:
                guard paused, !finished, !stopped else { return }
                paused = false
                if enabled && !animated {
                    for index in statuses.indices where !statuses[index].complete && !statuses[index].pending { emitPlain(index: index) }
                }
            case .complete(let vm):
                guard !finished, !stopped else { return }
                if let index = statuses.firstIndex(where: { $0.vm == vm }) { statuses[index].complete = true }
                if statuses.allSatisfy(\.complete) { clearLine() }
            case .step(let vm, let label, let fraction, let bytes, let total):
                guard enabled, !finished, !stopped else { return }
                let index: Int
                if let existing = statuses.firstIndex(where: { $0.vm == vm }) {
                    index = existing
                } else {
                    statuses.append(Status(vm: vm, label: label))
                    index = statuses.count - 1
                }
                let cleanLabel = Self.sanitize(label)
                let validBytes = bytes.map { max(0, $0) }
                let validTotal = total.flatMap { $0 > 0 ? $0 : nil }
                let now = clock()
                if statuses[index].label != cleanLabel || statuses[index].total != validTotal
                    || validBytes == nil || (validBytes ?? 0) < (statuses[index].bytes ?? 0)
                    || now < (statuses[index].samples.last?.time ?? now) {
                    statuses[index].samples.removeAll()
                }
                if let validBytes, now.isFinite {
                    let sample = ByteSample(time: now, bytes: validBytes)
                    // Bound memory even when download callbacks arrive for every chunk.
                    if statuses[index].samples.count > 1,
                       now - statuses[index].samples[statuses[index].samples.count - 2].time < 0.1 {
                        statuses[index].samples[statuses[index].samples.count - 1] = sample
                    } else {
                        statuses[index].samples.append(sample)
                    }
                    while statuses[index].samples.count > 2 && statuses[index].samples[1].time <= now - 5 {
                        statuses[index].samples.removeFirst()
                    }
                }
                statuses[index].label = cleanLabel
                statuses[index].fraction = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
                statuses[index].bytes = validBytes
                statuses[index].total = validTotal
                if statuses[index].fraction == 1 {
                    statuses[index].samples.removeAll()
                } else if let validBytes, let validTotal, validBytes >= validTotal {
                    statuses[index].samples.removeAll()
                }
                statuses[index].complete = false
                statuses[index].pending = false
                if !animated && !paused { emitPlain(index: index) }
            }
        }
    }

    private func emitPlain(index: Int) {
        let now = clock()
        let status = statuses[index]
        let percent = status.fraction.map(Self.percentage)
        let changed = status.lastPlainLabel != status.label
        let measuredUpdate = (percent != status.lastPlainPercent && percent == 100)
            || (now - status.lastPlainTime >= 5 && (percent != status.lastPlainPercent || (!status.samples.isEmpty && status.bytes != nil)))
        guard changed || measuredUpdate else { return }
        write(description(status, barWidth: 0, counters: true) + " \(separator) \(Int(max(0, now - startedAt)))s\n")
        statuses[index].lastPlainLabel = status.label
        statuses[index].lastPlainTime = now
        statuses[index].lastPlainPercent = percent
    }

    /// Also used by deterministic tests; normal rendering is driven independently by the timer.
    func tick() {
        lock.withLock {
            let elapsed = max(0, clock() - startedAt)
            guard animated, !paused, !stopped, !finished, elapsed >= 0.2 else { return }
            let active = statuses.filter { !$0.complete && !$0.pending }
            guard !active.isEmpty else { clearLine(); return }
            let width = max(1, terminalWidth() - 1)
            let frame = unicode ? Self.rectangleFrames[Int(elapsed * 10) % Self.rectangleFrames.count] : [".   ", " .  ", "  . ", "   ."][Int(elapsed * 10) % 4]
            let count = statuses.count > 1 ? " \(statuses.filter(\.complete).count)/\(statuses.count)" : ""
            let suffix = " \(separator) \(Int(elapsed))s\(count)"
            var selected = active
            var barWidth = 10
            var counters = true
            var throughput = true
            let available = width - Self.displayWidth(frame + " " + suffix)
            func content() -> String { selected.map { description($0, barWidth: barWidth, counters: counters, throughput: throughput) }.joined(separator: " | ") }
            func reduceDetails() -> String {
                var text = content()
                while barWidth > (width >= 30 ? 2 : 0) && Self.displayWidth(text) > available {
                    barWidth -= 1
                    text = content()
                }
                if Self.displayWidth(text) > available { counters = false; text = content() }
                return text
            }
            var text = reduceDetails()
            if active.count > 1 && Self.displayWidth(text) > available {
                selected = [active[Int(elapsed / 2) % active.count]]
                barWidth = 10
                counters = true
                throughput = true
                text = reduceDetails()
            }
            if Self.displayWidth(text) > available, available > 0 {
                if width < 60 {
                    throughput = false
                }
                // Preserve measured percentages before spending the remaining cells
                // on a long VM name or step label.
                if selected.reduce(0, { $0 + Self.displayWidth(measurement($1, barWidth: barWidth, counters: counters, throughput: throughput)) }) >= available {
                    barWidth = 0
                }
                let tails = selected.map { measurement($0, barWidth: barWidth, counters: counters, throughput: throughput) }
                let tailWidth = tails.reduce(0) { $0 + Self.displayWidth($1) }
                let labelBudget = max(0, available - tailWidth - (selected.count - 1) * 3)
                text = selected.enumerated().map { index, status in
                    let budget = labelBudget / selected.count + (index < labelBudget % selected.count ? 1 : 0)
                    return fittedLabel(status, width: budget) + tails[index]
                }.joined(separator: " | ")
            }
            let line: String
            if available > 0 {
                line = frame + " " + Self.truncate(text, width: available, unicode: unicode) + suffix
            } else {
                line = Self.truncate(frame + suffix, width: width, unicode: unicode)
            }
            installSignalCleanup()
            write("\r\u{001B}[2K" + line)
            visible = true
        }
    }

    private var separator: String { unicode ? "·" : "-" }

    private func label(_ status: Status) -> String {
        (status.vm.map { Self.sanitize($0) + " \(separator) " } ?? "") + status.label
    }

    private func fittedLabel(_ status: Status, width: Int) -> String {
        guard Self.displayWidth(label(status)) > width else { return label(status) }
        let stepWidth = Self.displayWidth(status.label)
        if stepWidth <= width {
            let vmBudget = width - stepWidth - Self.displayWidth(" \(separator) ")
            if let vm = status.vm, vmBudget >= 4 {
                return Self.truncate(Self.sanitize(vm), width: vmBudget, unicode: unicode) + " \(separator) " + status.label
            }
            return status.label
        }
        // The resolved restore version is at the end of the download label.
        // Retain that last word when shortening an action in a narrow terminal.
        if let lastWord = status.label.split(separator: " ").last {
            let tail = " " + lastWord
            let tailWidth = Self.displayWidth(tail)
            if tailWidth + 4 <= width {
                return Self.truncate(status.label, width: width - tailWidth, unicode: unicode) + tail
            }
        }
        return Self.truncate(status.label, width: width, unicode: unicode)
    }

    private func description(_ status: Status, barWidth: Int, counters: Bool, throughput: Bool = true) -> String {
        label(status) + measurement(status, barWidth: barWidth, counters: counters, throughput: throughput)
    }

    private func measurement(_ status: Status, barWidth: Int, counters: Bool, throughput: Bool = true) -> String {
        var text = ""
        if let fraction = status.fraction {
            if barWidth > 0 {
                let filled = Int(fraction * Double(barWidth))
                let bar = String(repeating: unicode ? "█" : "#", count: filled) + String(repeating: unicode ? "░" : "-", count: barWidth - filled)
                text += " " + (color ? "\u{001B}[36m" + bar + "\u{001B}[0m" : bar)
            }
            text += " \(Self.percentage(fraction))%"
        }
        if counters, let bytes = status.bytes {
            text += " \(Self.byteCount(bytes))"
            if let total = status.total { text += "/\(Self.byteCount(total))" }
        }
        if throughput, let rate = transferRate(status, now: clock()) {
            text += " \(Self.byteRate(rate))/s"
            if rate > 0, let total = status.total, let bytes = status.bytes, total > bytes {
                let seconds = ceil(Double(total - bytes) / rate)
                if seconds.isFinite && seconds < Double(Int.max) {
                    let duration = Int(seconds)
                    text += duration < 60 ? " ETA \(duration)s" : " ETA \(duration / 60)m \(String(format: "%02d", duration % 60))s"
                }
            }
        }
        return text
    }

    /// Use a recent byte window, interpolating its start and treating time since
    /// the last callback as a stall. The first counter is a resume baseline.
    private func transferRate(_ status: Status, now: TimeInterval) -> Double? {
        guard let first = status.samples.first, let last = status.samples.last,
              status.samples.count > 1, now.isFinite, now >= last.time else { return nil }
        let start = max(first.time, now - 5)
        guard now - start >= 1 else { return nil }
        var baseline = Double(last.bytes)
        if start <= first.time {
            baseline = Double(first.bytes)
        } else {
            for pair in zip(status.samples, status.samples.dropFirst()) where pair.0.time <= start && pair.1.time >= start {
                let duration = pair.1.time - pair.0.time
                if duration > 0 {
                    baseline = Double(pair.0.bytes) + Double(pair.1.bytes - pair.0.bytes) * (start - pair.0.time) / duration
                }
                break
            }
        }
        let rate = max(0, (Double(last.bytes) - baseline) / (now - start))
        return rate.isFinite ? rate : nil
    }

    private static func percentage(_ fraction: Double) -> Int {
        // Multiplication can put exact decimal percentages one ULP below their
        // integer (0.58 * 100, for example). Correct only that rounding error,
        // and reserve 100% for an explicitly complete measurement.
        min(fraction < 1 ? 99 : 100, Int((fraction * 100).nextUp))
    }

    private static func byteRate(_ value: Double) -> String {
        if value < 1_024 { return String(format: "%.0f B", value) }
        let units = ["KiB", "MiB", "GiB", "TiB"]
        var count = value / 1_024
        var index = 0
        while count >= 1_024 && index < units.count - 1 { count /= 1_024; index += 1 }
        return String(format: "%.1f %@", count, units[index])
    }

    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            stop()
        }
    }

    private func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        clearLine()
        removeSignalCleanup()
    }

    private func clearLine() {
        if visible { write("\r\u{001B}[2K"); visible = false }
    }

    private func installSignalCleanup() {
        guard signalCleanup, cleanupSignals.isEmpty else { return }
        for number in [SIGINT, SIGTERM] {
            var action = sigaction()
            guard sigaction(number, nil, &action) == 0,
                  Self.handlerAddress(action.__sigaction_u.__sa_handler) == Self.handlerAddress(SIG_DFL) else { continue }
            Darwin.signal(number, clearPommeProgressOnSignal)
            cleanupSignals.append((number, action))
        }
    }

    private func removeSignalCleanup() {
        for saved in cleanupSignals {
            var action = sigaction()
            if sigaction(saved.number, nil, &action) == 0,
               Self.handlerAddress(action.__sigaction_u.__sa_handler) == Self.handlerAddress(clearPommeProgressOnSignal) {
                var original = saved.action
                sigaction(saved.number, &original, nil)
            }
        }
        cleanupSignals.removeAll()
    }

    private static func handlerAddress(_ handler: (@convention(c) (Int32) -> Void)?) -> UInt {
        unsafeBitCast(handler, to: UInt.self)
    }

    deinit { finish() }

    static func currentTerminalWidth() -> Int {
        var size = winsize()
        return ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
    }

    static func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0) && ![0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value) })
    }

    private static func withoutANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    static func displayWidth(_ text: String) -> Int {
        withoutANSI(text).reduce(0) { result, character in
            let scalars = character.unicodeScalars
            // wcwidth follows the process locale. Fall back when it rejects Unicode
            // in the C locale, without changing global locale state.
            let widths = scalars.map { scalar -> Int in
                let native = Int(wcwidth(wchar_t(scalar.value)))
                if native >= 0 { return native }
                if CharacterSet.nonBaseCharacters.contains(scalar) || scalar.value == 0x200D { return 0 }
                let value = scalar.value
                if (0x1100...0x115F).contains(value) || (0x2329...0x232A).contains(value)
                    || (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7A3).contains(value)
                    || (0xF900...0xFAFF).contains(value) || (0xFE10...0xFE19).contains(value)
                    || (0xFE30...0xFE6F).contains(value) || (0xFF01...0xFF60).contains(value)
                    || (0xFFE0...0xFFE6).contains(value) || (0x1F000...0x1FAFF).contains(value)
                    || (0x20000...0x3FFFD).contains(value) { return 2 }
                return 1
            }
            if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) { return result + 2 }
            return result + (scalars.contains(where: { $0.value == 0x200D }) ? (widths.max() ?? 0) : widths.reduce(0, +))
        }
    }

    static func truncate(_ text: String, width: Int, unicode: Bool) -> String {
        guard width > 0 else { return "" }
        guard displayWidth(text) > width else { return text }
        let marker = unicode ? "…" : "."
        var result = ""
        for character in withoutANSI(text) {
            let next = result + String(character)
            if displayWidth(next) > width - 1 { break }
            result = next
        }
        return result + marker
    }

    private static func byteCount(_ value: Int64) -> String {
        if value < 1_024 { return "\(value) B" }
        let units = ["KiB", "MiB", "GiB", "TiB"]
        var count = Double(value) / 1_024
        var index = 0
        while count >= 1_024 && index < units.count - 1 { count /= 1_024; index += 1 }
        return String(format: "%.1f %@", count, units[index])
    }

    /// The perimeter of an 8-by-4-dot rectangle drawn in four Braille cells,
    /// clockwise from the top-left corner.
    static let rectanglePerimeter: [(x: Int, y: Int)] =
        (0..<8).map { ($0, 0) } + [(7, 1), (7, 2)] + (0..<8).reversed().map { ($0, 3) } + [(0, 2), (0, 1)]

    /// The rectangle outline with a three-dot gap that steps clockwise one
    /// dot per frame, so the outline appears to spin.
    static let rectangleFrames: [String] = {
        let bits = [[0, 1, 2, 6], [3, 4, 5, 7]]
        let perimeter = rectanglePerimeter
        return perimeter.indices.map { start in
            let gap = Set((0..<3).map { (start + $0) % perimeter.count })
            var cells = [UInt32](repeating: 0, count: 4)
            for (index, point) in perimeter.enumerated() where !gap.contains(index) {
                cells[point.x / 2] |= 1 << bits[point.x % 2][point.y]
            }
            return String(String.UnicodeScalarView(cells.map { UnicodeScalar(0x2800 + $0)! }))
        }
    }()
}
