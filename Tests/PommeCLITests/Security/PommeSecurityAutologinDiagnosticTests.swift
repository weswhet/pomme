import Foundation
import Testing

@Suite("Security native SessionAgent diagnostic")
struct PommeSecurityAutologinDiagnosticTests {
  @Test("Classifies process-bound native SessionAgent records")
  func classifiesNativeFixture() throws {
    let processID: Int64 = 4242
    for message in [
      "ERROR: Unable to get the SessionAgent endpoint, result = 2",
      "ERROR: Unable to get the SessionAgent endpoint, endpoint is nil",
    ] {
      let data = try nativeFixture(processID: processID, eventMessage: message)
      #expect(
        PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
          data, expectedProcessID: processID
        ) == .sessionUnavailable
      )
    }
  }

  @Test("Accepts the native C function prefix but rejects arbitrary prefixes")
  func classifiesNativeFunctionPrefix() throws {
    let processID: Int64 = 4242
    let native = try nativeFixture(
      processID: processID,
      eventMessage:
        "getSessionAgentEndpoint:104: ERROR: Unable to get the SessionAgent endpoint, result = 2"
    )
    #expect(
      PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
        native, expectedProcessID: processID
      ) == .sessionUnavailable
    )

    let arbitrary = try nativeFixture(
      processID: processID,
      eventMessage:
        "untrusted text ERROR: Unable to get the SessionAgent endpoint, result = 2"
    )
    #expect(
      PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
        arbitrary, expectedProcessID: processID
        ) == nil
    )

    let zeroLine = try nativeFixture(
      processID: processID,
      eventMessage:
        "getSessionAgentEndpoint:0: ERROR: Unable to get the SessionAgent endpoint, result = 2"
    )
    #expect(
      PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
        zeroLine, expectedProcessID: processID
      ) == nil
    )
  }

  @Test("Requires the expected process ID and exact login subsystems")
  func rejectsForeignProcessAndSubsystem() throws {
    let expected: Int64 = 4242
    let foreignProcess = try nativeFixture(processID: expected + 1)
    #expect(
      PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
        foreignProcess, expectedProcessID: expected
      ) == nil
    )

    for subsystem in ["com.apple.login.extra", "com.apple.security"] {
      let foreignSubsystem = try nativeFixture(processID: expected, subsystem: subsystem)
      #expect(
        PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
          foreignSubsystem, expectedProcessID: expected
        ) == nil
      )
    }
  }

  @Test("Rejects noninteger process IDs and unrelated messages")
  func rejectsMalformedEvidence() throws {
    let expected: Int64 = 4242
    for value: Any in [true, 4242.5, "4242"] {
      let malformedID = try nativeFixture(processID: value)
      #expect(
        PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
          malformedID, expectedProcessID: expected
        ) == nil
      )
    }

    let unrelated = try nativeFixture(
      processID: expected,
      eventMessage: "ERROR: Unable to get the SessionAgent endpoint, result = 3"
    )
    #expect(
      PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
        unrelated, expectedProcessID: expected
      ) == nil
    )
    #expect(
      PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
        Data("not JSON".utf8), expectedProcessID: expected
      ) == nil
    )
  }

  @Test("Rejects diagnostics larger than the one megabyte bound")
  func rejectsOversizedEvidence() {
    let oversized = Data(repeating: 0x20, count: 1_048_577)
    #expect(
      PommeSecurityNormalAgent.classifyAutologinSessionDiagnostic(
        oversized, expectedProcessID: 4242
      ) == nil
    )
  }

  private func nativeFixture(
    processID: Any,
    subsystem: String = "com.apple.login.default",
    eventMessage: String = "ERROR: Unable to get the SessionAgent endpoint, result = 2"
  ) throws -> Data {
    let record: [String: Any] = [
      "activityIdentifier": Int64(7),
      "category": "default",
      "eventMessage": eventMessage,
      "eventType": "logEvent",
      "formatString": "%{public}s",
      "machTimestamp": Int64(7),
      "process": "sysadminctl",
      "processID": processID,
      "processImagePath": "/usr/sbin/sysadminctl",
      "senderImagePath": "/System/Library/PrivateFrameworks/SystemAdministration.framework/Versions/A/SystemAdministration",
      "subsystem": subsystem,
      "timestamp": "2026-09-05 16:00:00.000000-0700",
      "timezoneName": "PDT",
    ]
    return try JSONSerialization.data(withJSONObject: [record], options: [.sortedKeys])
  }
}
