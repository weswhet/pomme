import Foundation
import Testing

@Suite("Security normal-agent response decoding")
struct PommeSecurityNormalAgentTests {
  @Test("Normal AMFI support requires the opt-in version, pinned digest, and closed capabilities")
  func validatesNormalAMFICapabilityReceipt() {
    let digest = String(repeating: "a", count: 64)
    let base: [String: Any] = [
      "role": "persistent",
      "protocol": PommeAgentProtocol.name,
      "version": Int64(PommeAgentProtocol.version),
      "executableSHA256": digest,
      "capabilities": Array(PommeAgent.normalAMFIOperations),
      "normalAMFIWorkflowVersion": Int64(PommeAgent.normalAMFIWorkflowVersion),
    ]

    #expect(PommeSecurityNormalAgent.supportsNormalAMFIWorkflow(
      base, expectedExecutableDigest: digest))

    var oldPinned = base
    oldPinned.removeValue(forKey: "normalAMFIWorkflowVersion")
    #expect(!PommeSecurityNormalAgent.supportsNormalAMFIWorkflow(
      oldPinned, expectedExecutableDigest: digest))

    var wrongDigest = base
    wrongDigest["executableSHA256"] = String(repeating: "b", count: 64)
    #expect(!PommeSecurityNormalAgent.supportsNormalAMFIWorkflow(
      wrongDigest, expectedExecutableDigest: digest))

    var missingOperation = base
    missingOperation["capabilities"] = ["amfi.normal.disable", "amfi.normal.enable"]
    #expect(!PommeSecurityNormalAgent.supportsNormalAMFIWorkflow(
      missingOperation, expectedExecutableDigest: digest))

    var coercedVersion = base
    coercedVersion["normalAMFIWorkflowVersion"] = "1"
    #expect(!PommeSecurityNormalAgent.supportsNormalAMFIWorkflow(
      coercedVersion, expectedExecutableDigest: digest))

    var malformedCapabilities = base
    malformedCapabilities["capabilities"] = ["amfi.normal.disable", true]
    #expect(!PommeSecurityNormalAgent.supportsNormalAMFIWorkflow(
      malformedCapabilities, expectedExecutableDigest: digest))
  }

  @Test("Normal AMFI operation vocabulary is exactly four credential-free stages")
  func normalAMFIOperationVocabularyIsClosed() {
    #expect(PommeSecurityNormalAgent.normalAMFIOperations == Set([
      "amfi.normal.disable",
      "amfi.normal.enable",
      "amfi.normal.verifyDisabled",
      "amfi.normal.verifyEnabled",
    ]))
    #expect(!PommeSecurityNormalAgent.normalAMFIOperations.contains("amfi.disable"))
    #expect(!PommeSecurityNormalAgent.normalAMFIOperations.contains("process.start"))
  }

  @Test("Decodes an Int64 exit code and stream frames")
  func decodesIntegerExitAndFrames() throws {
    let response = response(
      exitCode: Int64(0),
      stdout: Data("evidence\n".utf8),
      stderr: Data("warning\n".utf8))

    let result = try PommeSecurityNormalAgent.decodeCompletedCommand(response)

    #expect(result.exitCode == 0)
    #expect(result.signal == nil)
    #expect(result.exited)
    #expect(result.stdout == Data("evidence\n".utf8))
    #expect(result.stderr == Data("warning\n".utf8))
  }

  @Test("Accepts a legitimate nonzero completed command with no output")
  func acceptsNonzeroEmptyResult() throws {
    let result = try PommeSecurityNormalAgent.decodeCompletedCommand(
      response(exitCode: Int64(1), topLevelOK: false))

    #expect(result.exitCode == 1)
    #expect(result.signal == nil)
    #expect(result.exited)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.isEmpty)
  }

  @Test("Rejects malformed exit statuses and incomplete output")
  func rejectsMalformedCompletion() {
    let invalidResponses: [[String: Any]] = [
      response(exitCode: true),
      response(exitCode: "0"),
      response(exitCode: 1.5),
      response(exitCode: Int64(-1)),
      response(exitCode: Int64(256)),
      response(exitCode: nil),
      response(exitCode: Int64(0), exited: false),
      response(exitCode: Int64(0), outputComplete: false),
      response(exitCode: Int64(0), stdoutTruncated: true),
      response(exitCode: Int64(0), stderrTruncated: true),
    ]

    for invalidResponse in invalidResponses {
      #expect(throws: PommeSecurityWorkflowError.agentUnverified) {
        try PommeSecurityNormalAgent.decodeCompletedCommand(invalidResponse)
      }
    }
  }

  @Test("Maps rejected normal-agent responses to closed stage and reason codes")
  func mapsClosedResponseDiagnostics() {
    let cases: [(
      response: [String: Any],
      stage: PommeSecurityNormalAgentProofStage,
      reason: PommeSecurityNormalAgentFailureReason
    )] = [
      (
        response(exitCode: nil, exited: false, outputComplete: false, timedOut: true),
        .console,
        .timedOut
      ),
      (
        response(exitCode: Int64(0), stdoutTruncated: true),
        .aqua,
        .outputTruncated
      ),
      (
        response(exitCode: Int64(0), outputComplete: false),
        .console,
        .incomplete
      ),
      (
        response(exitCode: true),
        .processList,
        .invalidEnvelope
      ),
    ]

    for item in cases {
      let diagnostic = PommeSecurityNormalAgent.diagnostic(
        for: item.response, stage: item.stage)
      guard let diagnostic else {
        Issue.record("Expected a closed diagnostic for \(item.reason.rawValue).")
        continue
      }
      #expect(diagnostic.stage == item.stage)
      #expect(diagnostic.reason == item.reason)
      #expect(diagnostic.code == "normal-agent-\(item.stage.rawValue)-\(item.reason.rawValue)")
    }

    var malformedFrames = response(exitCode: Int64(0))
    malformedFrames["streamFrames"] = [
      ["stream": "stdout", "dataBase64": "not-base64"],
    ]
    let malformedDiagnostic = PommeSecurityNormalAgent.diagnostic(
      for: malformedFrames, stage: .processList)
    guard let malformedDiagnostic else {
      Issue.record("Expected a malformed-envelope diagnostic.")
      return
    }
    #expect(malformedDiagnostic.reason == .invalidEnvelope)

    #expect(
      PommeSecurityNormalAgent.diagnostic(
        for: response(exitCode: Int64(0)), stage: .console) == nil
    )
  }

  @Test("Transport diagnostics are closed and never include response material")
  func transportDiagnosticIsRedacted() throws {
    let diagnostic = PommeSecurityNormalAgent.transportDiagnostic(stage: .processList)
    #expect(diagnostic == .init(stage: .processList, reason: .transport))
    #expect(diagnostic.code == "normal-agent-ps-transport")
    #expect(!(diagnostic.errorDescription ?? "").contains("password"))

    let helperFailure: [String: Any] = [
      "ok": false,
      "error": "password=do-not-log /private/secret",
      "hostExitCode": 1,
    ]
    let helperDiagnostic = PommeSecurityNormalAgent.diagnostic(
      for: helperFailure, stage: .aqua)
    guard let helperDiagnostic else {
      Issue.record("Expected a transport diagnostic for a helper failure.")
      return
    }
    #expect(helperDiagnostic.stage == .aqua)
    #expect(helperDiagnostic.reason == .transport)
    #expect(!(helperDiagnostic.errorDescription ?? "").contains("do-not-log"))

    let response = response(
      exitCode: Int64(0), outputComplete: false,
      stdout: Data("password=do-not-log /private/secret".utf8))
    let responseDiagnostic = try #require(PommeSecurityNormalAgent.diagnostic(
      for: response, stage: .console))
    let responseDescription = responseDiagnostic.errorDescription ?? ""
    #expect(responseDiagnostic.code == "normal-agent-console-incomplete")
    #expect(!responseDescription.contains("do-not-log"))
    #expect(!responseDescription.contains("/private/secret"))
  }

  @Test("Rejects malformed or non-output stream frames")
  func rejectsMalformedFrames() {
    var malformed = response(exitCode: Int64(0))
    malformed["streamFrames"] = [["stream": "stdout", "dataBase64": "not-base64"]]
    #expect(throws: PommeSecurityWorkflowError.agentUnverified) {
      try PommeSecurityNormalAgent.decodeCompletedCommand(malformed)
    }

    var nonOutput = response(exitCode: Int64(0))
    nonOutput["streamFrames"] = [["stream": "exit"]]
    #expect(throws: PommeSecurityWorkflowError.agentUnverified) {
      try PommeSecurityNormalAgent.decodeCompletedCommand(nonOutput)
    }
  }

  @Test("Accepts one owner Dock process and unrelated commands with spaces")
  func acceptsNativeDesktopProcessFixture() {
    let output = desktopProcessList([
      "    0 /sbin/launchd",
      "  501 relative process name with spaces",
      "  501 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
      "  248 /System/Library/CoreServices/Setup Assistant.app/Contents/MacOS/Other",
    ])

    #expect(PommeSecurityNormalAgent.parseDesktopProcessList(output, expectedUID: 501))
  }

  @Test("Blocks Setup Assistant for any UID")
  func setupAssistantBlocksDesktopProof() {
    let setupAssistant = "/System/Library/CoreServices/Setup Assistant.app/Contents/MacOS/Setup Assistant"
    for uid in ["0", "248", "501", "502"] {
      let output = desktopProcessList([
        "  501 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
        "  \(uid) \(setupAssistant)",
      ])
      #expect(!PommeSecurityNormalAgent.parseDesktopProcessList(output, expectedUID: 501))
    }
  }

  @Test("Requires the exact owner Dock process once")
  func requiresExactOwnerDock() {
    let dock = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    let invalidFixtures = [
      desktopProcessList(["  501 /System/Library/CoreServices/Dock.app/Contents/MacOS/DockHelper"]),
      desktopProcessList(["  502 \(dock)"]),
      desktopProcessList(["  501 \(dock)", "  501 \(dock)"]),
      Data(),
    ]

    for output in invalidFixtures {
      #expect(!PommeSecurityNormalAgent.parseDesktopProcessList(output, expectedUID: 501))
    }
  }

  @Test("Rejects malformed, invalid UTF-8, and oversized native output")
  func rejectsMalformedDesktopProcessOutput() {
    let dock = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    let malformedFixtures = [
      desktopProcessList(["not-a-uid \(dock)"]),
      desktopProcessList(["-1 \(dock)"]),
      desktopProcessList(["4294967296 \(dock)"]),
      desktopProcessList(["000501 \(dock)"]),
      desktopProcessList(["501"]),
    ]

    for output in malformedFixtures {
      #expect(!PommeSecurityNormalAgent.parseDesktopProcessList(output, expectedUID: 501))
    }

    #expect(!PommeSecurityNormalAgent.parseDesktopProcessList(Data([0xFF, 0xFE]), expectedUID: 501))
    #expect(!PommeSecurityNormalAgent.parseDesktopProcessList(
      Data(repeating: 0x20, count: 1_048_577), expectedUID: 501))
  }

  @Test("Uses a bounded Aqua proof command and rejects UID zero")
  func aquaSessionProofRequestIsBounded() {
    guard let request = PommeSecurityNormalAgent.aquaSessionProofRequest(uniqueID: 501) else {
      Issue.record("Expected a proof request for a nonzero UID.")
      return
    }
    #expect(request.path == "/bin/sh")
    #expect(request.arguments == [
      "-c", "exec /bin/launchctl print \"gui/$1\" >/dev/null",
      "pomme-aqua-proof", "501",
    ])
    #expect(request.timeout == 15)
    #expect(request.inputData == nil)
    #expect(request.environment.isEmpty)
    #expect(PommeSecurityNormalAgent.aquaSessionProofRequest(uniqueID: 0) == nil)
  }

  @Test("Requires an empty, completed Aqua proof result")
  func aquaSessionProofResultMustBeComplete() {
    let success = commandResult()
    #expect(PommeSecurityNormalAgent.isCompletedAquaSessionProof(success))

    let invalidResults = [
      commandResult(exitCode: 1),
      commandResult(exitCode: nil, signal: 15),
      commandResult(exitCode: nil, timedOut: true, exited: false),
      commandResult(exited: false),
      commandResult(stdout: Data("unexpected".utf8)),
      commandResult(stderr: Data("launchctl error".utf8)),
      commandResult(stdoutTruncated: true),
      commandResult(stderrTruncated: true),
      commandResult(detached: true),
    ]
    for result in invalidResults {
      #expect(!PommeSecurityNormalAgent.isCompletedAquaSessionProof(result))
    }
  }

  @Test("Boot identity parsing is strict and canonical")
  func parsesBootIdentityStrictly() {
    let identity = "01234567-89ab-cdef-0123-456789abcdef"
    #expect(PommeSecurityNormalAgent.parseBootIdentity(Data((identity + "\n").utf8)) == identity)
    #expect(PommeSecurityNormalAgent.parseBootIdentity(
      Data((identity.uppercased() + "\n").utf8)) == identity)
    #expect(PommeSecurityNormalAgent.parseBootIdentity(Data("not-a-boot-id\n".utf8)) == nil)
    #expect(PommeSecurityNormalAgent.parseBootIdentity(Data("password=secret\n".utf8)) == nil)
    #expect(PommeSecurityNormalAgent.parseBootIdentity(Data(repeating: 0x20, count: 4_097)) == nil)
    #expect(PommeSecurityNormalAgent.parseBootIdentity(Data([0xFF, 0xFE])) == nil)
  }

  @Test("Native reboot request is fixed, detached, and credential-free")
  func nativeRebootRequestIsClosed() throws {
    let request = try #require(PommeSecurityNormalAgent.nativeRebootRequest(timeout: 30))
    #expect(request.path == "/sbin/reboot")
    #expect(request.arguments.isEmpty)
    #expect(request.timeout == 15)
    #expect(request.inputData == nil)
    #expect(!request.attachStdin)
    #expect(!request.pty)
    #expect(request.environment.isEmpty)
    #expect(request.user == nil)
    #expect(request.uid == nil)
    #expect(request.guestStdinPath == nil)
    let payload = try request.validatedControlPayload(detached: true)
    let processPayload = try #require(payload["payload"] as? [String: Any])
    #expect(processPayload.keys.sorted() == ["arguments", "detached", "path", "timeout"])
    #expect(processPayload["detached"] as? Bool == true)
    #expect(processPayload["path"] as? String == "/sbin/reboot")
    #expect(PommeSecurityNormalAgent.nativeRebootRequest(timeout: 0) == nil)
    #expect(PommeSecurityNormalAgent.nativeRebootRequest(timeout: .infinity) == nil)

    let jobID = UUID().uuidString.lowercased()
    let accepted: [String: Any] = [
      "ok": true,
      "result": [
        "jobID": jobID,
        "pid": Int64(42),
        "detached": true,
        "exited": false,
      ],
    ]
    #expect(PommeSecurityNormalAgent.isVerifiedDetachedRebootStart(accepted))

    var wrongPath = accepted
    wrongPath["result"] = [
      "jobID": jobID,
      "pid": Int64(42),
      "detached": false,
      "exited": false,
    ]
    #expect(!PommeSecurityNormalAgent.isVerifiedDetachedRebootStart(wrongPath))
  }

  @Test("Native reboot proves stopped state, restarts normally, and requires a new boot identity")
  func rebootAndAuthenticateSuccess() async throws {
    let trace = RebootTrace(identities: [
      "01234567-89ab-cdef-0123-456789abcdef",
      "fedcba98-7654-3210-fedc-ba9876543210",
    ])
    let agent = makeRebootAgent(trace: trace)

    try await agent.rebootAndAuthenticate(timeout: 5)

    #expect(trace.events == [.authenticate, .capture, .schedule, .observe, .observe, .observe, .start, .authenticate, .capture])
    #expect(trace.starts == 1)
    #expect(trace.stops == 0)
    #expect(trace.startTimeouts.count == 1)
    #expect(trace.startTimeouts[0] > 0)
  }

  @Test("Native reboot also accepts an in-place normal runtime with a changed boot identity")
  func rebootAndAuthenticateInPlaceSuccess() async throws {
    let trace = RebootTrace(identities: [
      "01234567-89ab-cdef-0123-456789abcdef",
      "fedcba98-7654-3210-fedc-ba9876543210",
    ])
    trace.inPlace = true
    let agent = makeRebootAgent(trace: trace)

    try await agent.rebootAndAuthenticate(timeout: 5)

    #expect(trace.events == [.authenticate, .capture, .schedule, .observe, .authenticate, .capture])
    #expect(trace.starts == 0)
    #expect(trace.stops == 0)
  }

  @Test("Native reboot rejects an old boot identity after the bounded restart window")
  func rebootAndAuthenticateRejectsOldIdentity() async throws {
    let oldIdentity = "01234567-89ab-cdef-0123-456789abcdef"
    let trace = RebootTrace(identities: [oldIdentity])
    let agent = makeRebootAgent(trace: trace)

    await #expect(throws: PommeSecurityNormalAgentError.rebootBootIdentityUnchanged) {
      try await agent.rebootAndAuthenticate(timeout: 1)
    }
    #expect(trace.starts == 1)
    #expect(trace.stops == 0)
  }

  @Test("Native reboot request failure does not start or stop the VM")
  func rebootAndAuthenticateRejectsRequestFailure() async throws {
    let trace = RebootTrace(identities: [
      "01234567-89ab-cdef-0123-456789abcdef",
    ])
    trace.scheduleError = true
    let agent = makeRebootAgent(trace: trace)

    await #expect(throws: PommeSecurityNormalAgentError.rebootRequestFailed) {
      try await agent.rebootAndAuthenticate(timeout: 5)
    }
    #expect(trace.starts == 0)
    #expect(trace.stops == 0)
  }

  @Test("Native reboot refuses a session whose pinned role or digest cannot authenticate")
  func rebootAndAuthenticateRejectsWrongPinOrRole() async throws {
    let trace = RebootTrace(identities: [
      "01234567-89ab-cdef-0123-456789abcdef",
    ])
    trace.authenticationError = true
    let agent = makeRebootAgent(trace: trace)

    await #expect(throws: PommeSecurityNormalAgentError.rebootAgentUnverified) {
      try await agent.rebootAndAuthenticate(timeout: 5)
    }
    #expect(trace.events == [.authenticate])
    #expect(trace.starts == 0)
  }

  @Test("Native reboot fails closed when run-state observation stays unavailable")
  func rebootAndAuthenticateRejectsUnavailableStatus() async throws {
    let trace = RebootTrace(identities: [
      "01234567-89ab-cdef-0123-456789abcdef",
    ])
    trace.observationError = true
    let agent = makeRebootAgent(trace: trace)

    await #expect(throws: PommeSecurityNormalAgentError.rebootDidNotStop) {
      try await agent.rebootAndAuthenticate(timeout: 1)
    }
    #expect(trace.starts == 0)
    #expect(trace.stops == 0)
  }

  private func makeRebootAgent(trace: RebootTrace) -> PommeSecurityNormalAgent {
    let hooks = PommeSecurityNormalAgentRebootHooks(
      authenticate: { _ in
        trace.events.append(.authenticate)
        if trace.authenticationError { throw PommeSecurityWorkflowError.agentUnverified }
      },
      captureBootIdentity: { _ in
        trace.events.append(.capture)
        return trace.nextIdentity()
      },
      scheduleReboot: { _ in
        trace.events.append(.schedule)
        if trace.scheduleError { throw PommeSecurityWorkflowError.agentUnverified }
        if !trace.inPlace { trace.state = .stopped }
      },
      observeRunState: {
        trace.events.append(.observe)
        if trace.observationError { throw PommeSecurityWorkflowError.agentUnverified }
        return trace.state
      },
      startNormal: { timeout in
        trace.events.append(.start)
        trace.startTimeouts.append(timeout)
        guard trace.state == .stopped else { throw PommeSecurityWorkflowError.agentUnverified }
        trace.starts += 1
        trace.state = .running(.normal)
      },
      now: { trace.now },
      sleep: { interval in trace.now = trace.now.addingTimeInterval(max(interval, 0.25)) }
    )
    return .init(
      reference: .init(name: "test", bundle: .init(rootURL: URL(fileURLWithPath: "/tmp/pomme-test"))),
      expectedExecutableDigest: String(repeating: "a", count: 64),
      rebootHooks: hooks
    )
  }

  private enum RebootEvent: Equatable {
    case authenticate
    case capture
    case schedule
    case observe
    case start
  }

  private final class RebootTrace: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 0)
    var state: VMRunStateSnapshot = .running(.normal)
    var identities: [String]
    var identityIndex = 0
    var events: [RebootEvent] = []
    var starts = 0
    var stops = 0
    var startTimeouts: [TimeInterval] = []
    var inPlace = false
    var observationError = false
    var scheduleError = false
    var authenticationError = false

    init(identities: [String]) { self.identities = identities }

    func nextIdentity() -> String {
      let index = min(identityIndex, identities.count - 1)
      identityIndex += 1
      return identities[index]
    }
  }

  private func desktopProcessList(_ lines: [String]) -> Data {
    Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  private func commandResult(
    exitCode: Int? = 0,
    signal: Int? = nil,
    stdout: Data = Data(),
    stderr: Data = Data(),
    stdoutTruncated: Bool = false,
    stderrTruncated: Bool = false,
    timedOut: Bool = false,
    exited: Bool = true,
    detached: Bool = false
  ) -> GuestCommandResult {
    .init(
      exitCode: exitCode,
      signal: signal,
      stdout: stdout,
      stderr: stderr,
      stdoutTruncated: stdoutTruncated,
      stderrTruncated: stderrTruncated,
      timedOut: timedOut,
      detached: detached,
      exited: exited
    )
  }

  private func response(
    exitCode: Any?,
    topLevelOK: Bool = true,
    exited: Bool = true,
    outputComplete: Bool = true,
    stdoutTruncated: Bool = false,
    stderrTruncated: Bool = false,
    stdout: Data = Data(),
    stderr: Data = Data(),
    timedOut: Bool = false,
    cancelled: Bool = false
  ) -> [String: Any] {
    var terminal: [String: Any] = [
      "exited": exited,
      "outputComplete": outputComplete,
      "stdoutTruncated": stdoutTruncated,
      "stderrTruncated": stderrTruncated,
      "timedOut": timedOut,
      "cancelled": cancelled,
    ]
    if let exitCode { terminal["exitCode"] = exitCode }

    var frames: [[String: Any]] = []
    if !stdout.isEmpty {
      frames.append(["stream": "stdout", "dataBase64": stdout.base64EncodedString()])
    }
    if !stderr.isEmpty {
      frames.append(["stream": "stderr", "dataBase64": stderr.base64EncodedString()])
    }
    return [
      // A nonzero guest exit is represented by an inner `ok: false` in the
      // foreground result while the control response itself remains success.
      "ok": topLevelOK,
      "result": terminal,
      "streamFrames": frames,
      "foreground": true,
    ]
  }
}
