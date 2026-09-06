import Foundation
import Testing

struct PommeRecoveryPerformanceMetricsTests {
  @Test("performance summaries contain cumulative counts and milliseconds only")
  func cumulativeSummary() {
    let metrics = PommeRecoveryPerformanceMetrics()
    metrics.record(.ocr, seconds: 0.25)
    metrics.record(.ocr, seconds: 0.125)
    metrics.record(.regionCacheHit)
    let summary = metrics.summary(phase: .navigation)
    #expect(summary.contains("phase=navigation cumulative=true"))
    #expect(summary.contains("ocrCount=2 ocrMs=375"))
    #expect(summary.contains("regionCacheHitCount=1 regionCacheHitMs=0"))
    #expect(metrics.summary(phase: .bootstrap).contains("ocrCount=2 ocrMs=375"))
  }

  @Test("invalid elapsed durations cannot pollute performance counters")
  func invalidDuration() {
    let metrics = PommeRecoveryPerformanceMetrics()
    for value in [Double.nan, .infinity, -1, Double.greatestFiniteMagnitude] {
      metrics.record(.ocr, seconds: value)
    }
    #expect(metrics.summary(phase: .navigation).contains("ocrCount=0 ocrMs=0"))
  }
}
