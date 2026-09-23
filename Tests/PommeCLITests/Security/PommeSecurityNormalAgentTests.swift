import Foundation
import Testing
import Synchronization

@Suite("Security normal-agent response decoding")
struct PommeSecurityNormalAgentTests {
  @Test("Outer desktop transport logs closed failure kinds", arguments: ["deadline", "rejected", "noHelper", "protocol"])
  func desktopOuterTransportDiagnostic(kind: String) async throws {
    let messages = Mutex<[String]>([])
    let calls = Mutex(0)
    let agent = PommeSecurityNormalAgent(
      reference: .init(name: "private-name", bundle: .init(rootURL: URL(fileURLWithPath: "/tmp/private-path"))),
      expectedExecutableDigest: String(repeating: "a", count: 64),
      desktopProofHooks: .init(execute: { _, timeout in
        calls.withLock { $0 += 1 }
        #expect(timeout == 30)
        switch kind {
        case "deadline": throw POSIXError(.ETIMEDOUT)
        case "rejected": throw RunnerError.controlCommandFailed("private-secret")
        case "noHelper": throw RunnerError.noRunningVM(URL(fileURLWithPath: "/tmp/private-path"))
        default: throw RunnerError.invalidControlResponse("private-secret")
        }
      }, status: { _, _ in Issue.record("No cleanup for transport failure"); return .null })
    )
    await PommeCore.withLogSink({ line in messages.withLock { $0.append(line) } }) {
      do {
        try await agent.verifyConsoleLogin(username: "owner", uniqueID: 501)
        Issue.record("Expected unchanged transport error")
      } catch let error as POSIXError {
        #expect(kind == "deadline")
        #expect(error.code == .ETIMEDOUT)
      } catch let error as RunnerError {
        switch error {
        case .controlCommandFailed(let text): #expect(kind == "rejected"); #expect(text == "private-secret")
        case .noRunningVM: #expect(kind == "noHelper")
        case .invalidControlResponse(let text): #expect(kind == "protocol"); #expect(text == "private-secret")
        default: Issue.record("Unexpected RunnerError case")
        }
      } catch { Issue.record("Unexpected error type") }
    }
    let lines = messages.withLock { $0.filter { $0.contains("[DEBUG-desktop-transport-20260923]") } }
    let line = try #require(lines.first)
    #expect(lines.count == 1)
    #expect(line.contains("side=host boundary=control stage=console"))
    let expected = ["deadline": "posixDeadline", "rejected": "controlCommandFailed", "noHelper": "noHelper", "protocol": "controlProtocol"]
    #expect(line.contains("errorKind=\(try #require(expected[kind]))"))
    #expect(line.contains("budgetMs=30000"))
    #expect(line.contains("elapsedMs="))
    #expect(line.contains("private") == false)
    #expect(calls.withLock { $0 } == 1)
  }

  @Test("Outer desktop transport preserves original failures without cleanup", arguments: ["deadline", "rejected", "noHelper", "protocol"])
  func desktopOuterTransportPreservesError(kind: String) async throws {
    let calls = Mutex(0)
    let agent = PommeSecurityNormalAgent(
      reference: .init(name: "private-name", bundle: .init(rootURL: URL(fileURLWithPath: "/tmp/private-path"))),
      expectedExecutableDigest: String(repeating: "a", count: 64),
      desktopProofHooks: .init(execute: { _, timeout in
        calls.withLock { $0 += 1 }
        #expect(timeout == 30)
        switch kind {
        case "deadline": throw POSIXError(.ETIMEDOUT)
        case "rejected": throw RunnerError.controlCommandFailed("private-secret")
        case "noHelper": throw RunnerError.noRunningVM(URL(fileURLWithPath: "/tmp/private-path"))
        default: throw RunnerError.invalidControlResponse("private-secret")
        }
      }, status: { _, _ in Issue.record("No cleanup for transport failure"); return .null })
    )
    do {
      try await agent.verifyConsoleLogin(username: "owner", uniqueID: 501)
      Issue.record("Expected unchanged transport error")
    } catch let error as POSIXError {
      #expect(kind == "deadline")
      #expect(error.code == .ETIMEDOUT)
    } catch let error as RunnerError {
      switch error {
      case .controlCommandFailed(let text): #expect(kind == "rejected"); #expect(text == "private-secret")
      case .noRunningVM: #expect(kind == "noHelper")
      case .invalidControlResponse(let text): #expect(kind == "protocol"); #expect(text == "private-secret")
      default: Issue.record("Unexpected RunnerError case")
      }
    } catch { Issue.record("Unexpected error type") }
    #expect(calls.withLock { $0 } == 1)
  }

  @Test("Each fixed desktop probe retries only after verified cleanup", arguments: PommeSecurityNormalAgentProofStage.allCases, ["verified", "resetStable", "unknown", "wrongJob", "malformedExit", "cancelled", "deadline", "cleanupDeadline", "transport", "repeatedTimeout"])
  func allDesktopStagesRetry(stage: PommeSecurityNormalAgentProofStage, mode: String) async throws {
    let trace = DesktopTrace(mode: mode, timeoutStage: stage)
    let agent = PommeSecurityNormalAgent(
      reference: .init(name: "test", bundle: .init(rootURL: URL(fileURLWithPath: "/tmp/pomme-test"))),
      expectedExecutableDigest: String(repeating: "a", count: 64),
      desktopProofHooks: .init(
        execute: { try trace.execute($0, transportTimeout: $1) },
        status: { try JSONValue(any: PommeCore.normalizedControlObject(trace.status($0, timeout: $1))) },
        now: { trace.now }, sleep: { trace.now = trace.now.advanced(by: .seconds($0)) }
      )
    )
    if mode == "verified" || mode == "resetStable" {
      try await agent.verifyConsoleLogin(username: "owner", uniqueID: 501)
      #expect(trace.consoleCalls >= 6)
      #expect(trace.statusCalls == 1)
      let stageIndices = trace.events.indices.filter { trace.events[$0] == stage }
      let failureOrdinal = mode == "resetStable" ? 3 : 0
      try #require(stageIndices.indices.contains(failureOrdinal))
      let failureIndex = stageIndices[failureOrdinal]
      try #require(trace.events.indices.contains(failureIndex + 1))
      #expect(trace.events[failureIndex + 1] == .console)
      let cleanedAt = try #require(trace.cleanedAt)
      #expect(cleanedAt.duration(to: trace.now) >= .seconds(5))
    } else {
      await #expect(throws: PommeSecurityNormalAgentDiagnostic(stage: stage, reason: .timedOut)) {
        try await agent.verifyConsoleLogin(username: "owner", uniqueID: 501)
      }
      if mode == "repeatedTimeout" {
        #expect(trace.consoleCalls > 1 && trace.consoleCalls <= 7)
        #expect(trace.origin.duration(to: trace.now) < .seconds(120))
      } else { #expect(trace.consoleCalls == 1) }
      if mode == "cancelled" || mode == "deadline" { #expect(trace.statusCalls == 0) }
    }
  }

  @Test("Desktop loop retries Aqua only after same-job cleanup proof", arguments: [
    "verified", "staleStatus", "signalExit", "receipt", "resetStable", "unknown", "exitedOnly",
    "wrongJob", "wrongResultJob", "malformedExit", "invalidSignal", "missingJob",
    "cancelled", "deadline", "cleanupDeadline", "transport", "repeatedTimeout", "lateDesktop", "reconnected",
    "oldHelper", "wrongDigest", "rejected", "malformedHost", "unavailableDeadline", "unavailableOuterDeadline", "cleanupCancelled"
  ])
  func aquaReadinessCleanupRetry(mode: String) async throws {
    let trace = DesktopTrace(mode: mode)
    let agent = PommeSecurityNormalAgent(
      reference: .init(name: "test", bundle: .init(rootURL: URL(fileURLWithPath: "/tmp/pomme-test"))),
      expectedExecutableDigest: String(repeating: "a", count: 64),
      desktopProofHooks: .init(
        execute: { try trace.execute($0, transportTimeout: $1) },
        status: { try JSONValue(any: PommeCore.normalizedControlObject(trace.status($0, timeout: $1))) },
        now: { trace.now }, sleep: { trace.now = trace.now.advanced(by: .seconds($0)) }
      )
    )
    if ["verified", "staleStatus", "signalExit", "receipt", "resetStable", "reconnected"].contains(mode) {
      try await agent.verifyConsoleLogin(username: "owner", uniqueID: 501)
      #expect(trace.aquaCalls >= 6)
      #expect(trace.consoleCalls == trace.aquaCalls)
      #expect(trace.desktopCalls == trace.aquaCalls - 1)
      #expect(trace.statusCalls == (mode == "receipt" ? 0 : mode == "reconnected" ? 2 : 1))
      let cleanedAt = try #require(trace.cleanedAt)
      #expect(cleanedAt.duration(to: trace.now) >= .seconds(5))
      #expect(trace.origin.duration(to: trace.now) < .seconds(120))
    } else {
      if mode == "cleanupCancelled" {
        await #expect(throws: CancellationError.self) {
          try await agent.verifyConsoleLogin(username: "owner", uniqueID: 501)
        }
      } else if mode == "lateDesktop" {
        await #expect(throws: PommeSecurityWorkflowError.ownerLoginUnverified) {
          try await agent.verifyConsoleLogin(username: "owner", uniqueID: 501)
        }
      } else {
        await #expect(throws: PommeSecurityNormalAgentDiagnostic(stage: .aqua, reason: .timedOut)) {
          try await agent.verifyConsoleLogin(username: "owner", uniqueID: 501)
        }
      }
      if mode == "repeatedTimeout" {
        #expect(trace.aquaCalls > 1 && trace.aquaCalls <= 7)
        #expect(trace.origin.duration(to: trace.now) < .seconds(120))
      } else { #expect(trace.aquaCalls == (mode == "lateDesktop" ? 2 : 1)) }
      #expect(trace.desktopCalls == (mode == "lateDesktop" ? 1 : 0))
      if ["cancelled", "deadline", "missingJob"].contains(mode) { #expect(trace.statusCalls == 0) }
    }
  }

  @Test("Actual task cancellation stops desktop cleanup and prevents a new probe", arguments: PommeSecurityNormalAgentProofStage.allCases)
  func aquaReadinessTaskCancellation(stage: PommeSecurityNormalAgentProofStage) async throws {
    let trace = DesktopTrace(mode: "taskCancelled", timeoutStage: stage)
    let agent = PommeSecurityNormalAgent(
      reference: .init(name: "test", bundle: .init(rootURL: URL(fileURLWithPath: "/tmp/pomme-test"))),
      expectedExecutableDigest: String(repeating: "a", count: 64),
      desktopProofHooks: .init(
        execute: { try trace.execute($0, transportTimeout: $1) },
        status: { try JSONValue(any: PommeCore.normalizedControlObject(trace.status($0, timeout: $1))) },
        now: { trace.now }, sleep: { trace.now = trace.now.advanced(by: .seconds($0)) }
      )
    )
    let task = Task { try await agent.verifyConsoleLogin(username: "owner", uniqueID: 501) }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(trace.aquaCalls == (stage == .console ? 0 : 1))
    #expect(trace.statusCalls == 0)
    #expect(trace.desktopCalls == (stage == .processList ? 1 : 0))
  }

  private final class DesktopTrace: @unchecked Sendable {
    let mode: String
    let timeoutStage: PommeSecurityNormalAgentProofStage
    let origin = ContinuousClock.now
    var now: ContinuousClock.Instant
    let jobID = UUID()
    var aquaCalls = 0
    var consoleCalls = 0
    var desktopCalls = 0
    var statusCalls = 0
    var cleanedAt: ContinuousClock.Instant?
    var events: [PommeSecurityNormalAgentProofStage] = []
    init(mode: String, timeoutStage: PommeSecurityNormalAgentProofStage = .aqua) {
      self.mode = mode; self.timeoutStage = timeoutStage; now = origin
    }

    func execute(_ request: GuestCommandRequest, transportTimeout: TimeInterval) throws -> JSONValue {
      #expect(request.timeout <= 15)
      #expect(transportTimeout <= 120)
      now = now.advanced(by: .milliseconds(100))
      var output = ""
      if request.path == "/usr/bin/stat" {
        events.append(.console)
        consoleCalls += 1; output = "owner:501\n"
        if timeoutStage == .console && shouldTimeout(call: consoleCalls) {
          if mode == "taskCancelled" { withUnsafeCurrentTask { $0?.cancel() } }
          return timedOutResponse()
        }
      }
      else if request.path == "/bin/ps" {
        events.append(.processList)
        desktopCalls += 1; output = "501 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock\n"
        if timeoutStage == .processList && shouldTimeout(call: desktopCalls) {
          if mode == "taskCancelled" { withUnsafeCurrentTask { $0?.cancel() } }
          return timedOutResponse()
        }
        if mode == "lateDesktop" { now = now.advanced(by: .seconds(121)) }
      }
      else {
        events.append(.aqua)
        aquaCalls += 1
        if mode == "taskCancelled" && timeoutStage == .aqua { withUnsafeCurrentTask { $0?.cancel() } }
        if timeoutStage == .aqua && shouldTimeout(call: aquaCalls) {
          return timedOutResponse()
        }
      }
      return .object(["ok": .bool(true), "result": .object([
        "exited": .bool(true), "outputComplete": .bool(true), "exitCode": .integer(0),
        "stdoutTruncated": .bool(false), "stderrTruncated": .bool(false)
      ]), "streamFrames": .array(output.isEmpty ? [] : [.object([
        "stream": .string("stdout"), "dataBase64": .string(Data(output.utf8).base64EncodedString())
      ])])])
    }

    private func shouldTimeout(call: Int) -> Bool {
      call == (mode == "resetStable" ? 4 : 1) || mode == "repeatedTimeout"
    }

    private func timedOutResponse() -> JSONValue {
      now = now.advanced(by: .seconds(mode == "deadline" ? 121 : 15))
      var terminal: [String: JSONValue] = [
        "jobID": .string(jobID.uuidString), "timedOut": .bool(true),
        "cancelled": .bool(mode == "cancelled"), "exited": .bool(false),
        "outputComplete": .bool(false), "terminationRequested": .bool(true)
      ]
      if mode == "missingJob" { terminal.removeValue(forKey: "jobID") }
      if mode == "receipt" {
        terminal[PommeForegroundExecution.desktopCleanupReceiptKey] = .object([
          "jobID": .string(jobID.uuidString), "reapedAndDrained": .bool(true)
        ])
        cleanedAt = now
      }
      return .object(["ok": .bool(false), "result": .object(terminal), "streamFrames": .array([])])
    }

    func status(_ id: UUID, timeout: TimeInterval) throws -> JSONValue {
      #expect(id == jobID)
      #expect(timeout > 0 && timeout <= 3)
      statusCalls += 1
      now = now.advanced(by: .milliseconds(250))
      if mode == "cleanupCancelled" { throw CancellationError() }
      if mode == "rejected" { return .object(["desktopCleanupVersion": .integer(1), "state": .string("rejected")]) }
      if mode == "malformedHost" { return .object(["desktopCleanupVersion": .bool(true), "state": .string("temporarily-unavailable")]) }
      if mode == "unavailableOuterDeadline" { now = origin.advanced(by: .seconds(120)) }
      if mode == "unavailableDeadline" || mode == "unavailableOuterDeadline" {
        return .object(["desktopCleanupVersion": .integer(1), "state": .string("temporarily-unavailable")])
      }
      if mode == "reconnected" && statusCalls == 1 {
        return .object(["desktopCleanupVersion": .integer(1), "state": .string("temporarily-unavailable")])
      }
      if mode == "cleanupDeadline" { now = now.advanced(by: .seconds(3)) }
      if mode == "transport" { throw PommeSecurityWorkflowError.agentUnverified }
      let frameID = mode == "wrongJob" ? UUID() : jobID
      var terminal: [String: JSONValue] = [
        "jobID": .string((mode == "wrongResultJob" ? UUID() : jobID).uuidString),
        "exited": .bool(mode != "unknown" && mode != "staleStatus"), "exitCode": .integer(0)
      ]
      if mode == "staleStatus" { terminal.removeValue(forKey: "exitCode") }
      var frame: [String: JSONValue] = [
        "jobID": .string(frameID.uuidString), "requestID": .string(UUID().uuidString), "stream": .string("exit")
      ]
      if mode == "signalExit" { frame["signal"] = .integer(15) }
      if mode == "invalidSignal" { frame["signal"] = .integer(128) }
      if mode == "malformedExit" { frame["dataBase64"] = .string("bad") }
      cleanedAt = now
      let rawStatus = JSONValue.object(["ok": .bool(true), "result": .object(terminal),
                                       "streamFrames": .array(["unknown", "exitedOnly"].contains(mode) ? [] : [.object(frame)])])
      if mode == "oldHelper" { return rawStatus }
      return .object([
        "desktopCleanupVersion": .integer(1), "state": .string("verified-status"),
        "jobID": .string(jobID.uuidString.lowercased()), "executableSHA256": .string(String(repeating: mode == "wrongDigest" ? "b" : "a", count: 64)),
        "status": rawStatus
      ])
    }
  }


  @Test("Desktop deadline diagnostics distinguish unmatched and unchecked proofs")
  func desktopDeadlineDiagnostic() {
    #expect(PommeSecurityDesktopProofObservation(
      consoleMatches: false, aquaMatches: nil, desktopMatches: nil
    ).timeoutDiagnostic == "Normal desktop proof deadline expired: console=not-matched aqua=not-checked desktop=not-checked.")
    #expect(PommeSecurityDesktopProofObservation(
      consoleMatches: true, aquaMatches: false, desktopMatches: true
    ).timeoutDiagnostic == "Normal desktop proof deadline expired: console=matched aqua=not-matched desktop=matched.")
    #expect(PommeSecurityDesktopProofObservation(
      consoleMatches: true, aquaMatches: true, desktopMatches: false
    ).timeoutDiagnostic == "Normal desktop proof deadline expired: console=matched aqua=matched desktop=not-matched.")
    // All predicates may match without satisfying the required stability interval.
    #expect(PommeSecurityDesktopProofObservation(
      consoleMatches: true, aquaMatches: true, desktopMatches: true
    ).timeoutDiagnostic == "Normal desktop proof deadline expired: console=matched aqua=matched desktop=matched.")
  }

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

  @Test("Normal-boot SIP read accepts only the two exact native status reports")
  func parsesExactSIPStatus() {
    #expect(PommeSecurityNormalAgent.parseSIPDisabled(
      "System Integrity Protection status: enabled.\n") == false)
    #expect(PommeSecurityNormalAgent.parseSIPDisabled(
      "System Integrity Protection status: disabled.\n") == true)
    #expect(PommeSecurityNormalAgent.parseSIPDisabled(
      "System Integrity Protection status: disabled.") == true)
    #expect(PommeSecurityNormalAgent.parseSIPDisabled("") == nil)
    #expect(PommeSecurityNormalAgent.parseSIPDisabled(
      "System Integrity Protection status: enabled (Custom Configuration).\n") == nil)
    #expect(PommeSecurityNormalAgent.parseSIPDisabled(
      "System Integrity Protection status: unknown (Custom Configuration).\n\nConfiguration:\n") == nil)
    #expect(PommeSecurityNormalAgent.parseSIPDisabled(
      "System Integrity Protection status: disabled.\nextra\n") == nil)
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

  @Test("A timed-out Aqua proof propagates its closed diagnostic without raw output")
  func timedOutAquaProofPreservesTypedDiagnostic() {
    let secret = "password=do-not-log /private/secret"
    let result = PommeSecurityNormalAgent.decodeProofResponse(
      response(
        exitCode: nil,
        exited: false,
        outputComplete: false,
        stdout: Data(secret.utf8),
        stderr: Data(secret.utf8),
        timedOut: true
      ),
      stage: .aqua
    )

    guard case .failure(let diagnostic) = result else {
      Issue.record("Expected the timed-out Aqua response to fail with a diagnostic.")
      return
    }
    #expect(diagnostic.stage == .aqua)
    #expect(diagnostic.reason == .timedOut)
    #expect(diagnostic.code == "normal-agent-aqua-timedOut")
    let description = diagnostic.errorDescription ?? ""
    #expect(description == "Normal agent verification failed (normal-agent-aqua-timedOut).")
    #expect(!description.contains("pinned"))
    #expect(!description.contains(secret))
  }

  @Test("Timeout state summary keeps running and output-pending states closed")
  func timeoutStateSummaryClassifiesKnownBooleans() {
    let running = response(
      exitCode: nil,
      exited: false,
      outputComplete: false,
      timedOut: true)
    #expect(PommeSecurityNormalAgent.timeoutStateSummary(
      for: running, stage: .aqua
    ) == "Normal desktop proof timeout state: stage=aqua, exited=false, outputComplete=false, terminationRequested=unknown.")

    var runningResult = running
    var runningTerminal = runningResult["result"] as! [String: Any]
    runningTerminal["terminationRequested"] = true
    runningResult["result"] = runningTerminal

    #expect(PommeSecurityNormalAgent.timeoutStateSummary(
      for: runningResult, stage: .aqua
    ) == "Normal desktop proof timeout state: stage=aqua, exited=false, outputComplete=false, terminationRequested=true.")

    var exited = response(
      exitCode: nil,
      exited: true,
      outputComplete: false,
      timedOut: true)
    var exitedTerminal = exited["result"] as! [String: Any]
    exitedTerminal["terminationRequested"] = false
    exited["result"] = exitedTerminal

    #expect(PommeSecurityNormalAgent.timeoutStateSummary(
      for: exited, stage: .processList
    ) == "Normal desktop proof timeout state: stage=ps, exited=true, outputComplete=false, terminationRequested=false.")
  }

  @Test("Timeout state summary marks malformed fields unknown and excludes raw response data")
  func timeoutStateSummaryRejectsMalformedFieldsAndSecrets() {
    let secret = "password=do-not-log /private/secret"
    var malformed = response(
      exitCode: nil,
      exited: false,
      outputComplete: false,
      stdout: Data(secret.utf8),
      stderr: Data(secret.utf8),
      timedOut: true)
    var terminal = malformed["result"] as! [String: Any]
    terminal["exited"] = 1
    terminal["outputComplete"] = "false"
    terminal["terminationRequested"] = 0.5
    terminal["jobID"] = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    terminal["pid"] = Int64(501)
    malformed["result"] = terminal

    let summary = PommeSecurityNormalAgent.timeoutStateSummary(
      for: malformed, stage: .console)
    #expect(summary == "Normal desktop proof timeout state: stage=console, exited=unknown, outputComplete=unknown, terminationRequested=unknown.")
    #expect(!summary.contains(secret))
    #expect(!summary.contains("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    #expect(!summary.contains("501"))
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

  @Test("Exact desktop helper failures carry only an allowlisted transport cause", arguments: [
    "startTimeout", "statusTimeout", "signalTimeout", "disconnected",
    "protocol", "foregroundDeadline", "agentRejected", "other",
  ])
  func desktopTransportCauseIsClosed(mode: String) throws {
    let error: Error
    let expected: PommeSecurityDesktopTransportCause
    switch mode {
    case "startTimeout":
      error = RunnerError.guestAgentTimedOut("process.start"); expected = .agentStartTimeout
    case "statusTimeout":
      error = RunnerError.guestAgentTimedOut("process.status"); expected = .agentStatusTimeout
    case "signalTimeout":
      error = RunnerError.guestAgentTimedOut("process.signal"); expected = .agentSignalTimeout
    case "disconnected":
      error = RunnerError.guestAgentDisconnected; expected = .agentDisconnected
    case "protocol":
      error = PommeAgentProtocol.Error.invalidResponse; expected = .agentProtocol
    case "foregroundDeadline":
      error = PommeForegroundExecution.Error.deadlineReached; expected = .foregroundDeadline
    case "agentRejected":
      error = RunnerError.guestAgentError("private-synthetic-sentinel"); expected = .agentRejected
    default:
      error = CocoaError(.fileReadUnknown); expected = .other
    }
    let payload = JSONValue.object([
      "path": .string("/bin/ps"),
      "arguments": .array([.string("-axo"), .string("uid=,comm=")]),
    ])
    let failure = try #require(PommeCore.desktopTransportFailureObject(error, payload: payload))
    #expect(failure["ok"] as? Bool == false)
    #expect(failure["hostExitCode"] as? Int == 1)
    #expect(PommeSecurityNormalAgent.transportCause(in: failure) == expected)
    #expect(PommeSecurityNormalAgent.diagnostic(for: failure, stage: .processList)?.code == "normal-agent-ps-transport")
    #expect(!expected.rawValue.contains("private-synthetic-sentinel"))

    var untrusted = failure
    untrusted["desktopTransportCause"] = "private-synthetic-sentinel"
    #expect(PommeSecurityNormalAgent.transportCause(in: untrusted) == nil)
    #expect(PommeCore.desktopTransportFailureObject(error, payload: .object([
      "path": .string("/bin/ls"), "arguments": .array([]),
    ])) == nil)
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
