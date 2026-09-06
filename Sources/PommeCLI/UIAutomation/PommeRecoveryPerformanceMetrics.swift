import Foundation

enum PommeRecoveryPerformancePhase: String, Sendable {
    case navigation, bootstrap
}

/// Counts and monotonic durations only. Never retains image, OCR, or input data.
final class PommeRecoveryPerformanceMetrics: @unchecked Sendable {
    enum Event: String, CaseIterable, Sendable {
        case capture, hash, classification, ocr, input, wait
        case regionCacheHit, fullFrameFallback
    }

    private let lock = NSLock()
    private var counts: [Event: UInt64] = [:]
    private var nanoseconds: [Event: UInt64] = [:]

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func record(_ event: Event, since start: UInt64) {
        let end = Self.now()
        record(event, nanoseconds: end >= start ? end - start : 0)
    }

    func record(_ event: Event, seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max) / 1_000_000_000 else { return }
        record(event, nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func record(_ event: Event, nanoseconds duration: UInt64 = 0) {
        lock.withLock {
            counts[event, default: 0] += 1
            nanoseconds[event, default: 0] += duration
        }
    }

    func summary(phase: PommeRecoveryPerformancePhase) -> String {
        lock.withLock {
            let values = Event.allCases.map { event in
                "\(event.rawValue)Count=\(counts[event, default: 0]) \(event.rawValue)Ms=\(nanoseconds[event, default: 0] / 1_000_000)"
            }.joined(separator: " ")
            return "Recovery performance: phase=\(phase.rawValue) cumulative=true \(values)"
        }
    }
}
