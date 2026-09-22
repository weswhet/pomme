import Foundation
import Synchronization
import Testing

struct PommeSecurityDesktopCleanupTests {
  private static let digest = String(repeating: "a", count: 64)
  private static let job = UUID()
  private static var payload: JSONValue {
    .object(["jobID": .string(job.uuidString.lowercased()),
             PommeSecurityDesktopCleanup.digestMarker: .string(digest)])
  }

  @Test("Cleanup receipts survive the actual control response normalization", arguments: [false, true])
  func controlNormalization(unavailable: Bool) async throws {
    let response = await PommeSecurityDesktopCleanup.perform(operation: "process.status", payload: Self.payload) {
      if unavailable { throw RunnerError.guestAgentConnecting }
      return Session(mode: "valid")
    }
    let normalized = try JSONValue(any: PommeCore.normalizedControlObject(response))
    #expect(PommeSecurityDesktopCleanup.completion(normalized, jobID: Self.job, digest: Self.digest) == !unavailable)
    var malformed = try #require(normalized.objectValue)
    malformed["ok"] = .bool(false)
    #expect(PommeSecurityDesktopCleanup.completion(.object(malformed), jobID: Self.job, digest: Self.digest) == nil)
    malformed["ok"] = .bool(true)
    malformed["hostExitCode"] = .bool(false)
    #expect(PommeSecurityDesktopCleanup.completion(.object(malformed), jobID: Self.job, digest: Self.digest) == nil)
    malformed["hostExitCode"] = .integer(0)
    malformed["extra"] = .bool(true)
    #expect(PommeSecurityDesktopCleanup.completion(.object(malformed), jobID: Self.job, digest: Self.digest) == nil)
  }

  @Test("Concrete coordinator pin rejects replacement during describe or status", arguments: ["none", "agent.describe", "process.status"])
  func coordinatorPinIntegration(replaceDuring: String) async throws {
    let transport = Transport()
    let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.digest })
    defer { coordinator.teardown() }
    let replacement = Connection()
    let original = Connection(replaceDuring: replaceDuring) {
      coordinator.teardown()
      try coordinator.attachNormal()
      transport.connect(replacement)
      _ = try await Self.awaitPin(coordinator)
    }
    try coordinator.attachNormal()
    transport.connect(original)
    _ = try await Self.awaitPin(coordinator)
    let response = await PommeSecurityDesktopCleanup.perform(operation: "process.status", payload: Self.payload) {
      try coordinator.captureAuthenticatedSession(as: .normal)
    }
    let expected = replaceDuring == "none" ? "verified-status" : "temporarily-unavailable"
    #expect(response.objectValue?["state"] == .string(expected))
    #expect(original.operations.withLock { $0 } == (replaceDuring == "agent.describe"
      ? ["authenticate", "agent.describe"] : ["authenticate", "agent.describe", "process.status"]))
    // A newly authenticated session is never used to finish an old pin's request.
    #expect(replacement.operations.withLock { $0 } == (replaceDuring == "none" ? [] : ["authenticate"]))
    if replaceDuring != "none" {
      let next = await PommeSecurityDesktopCleanup.perform(operation: "process.status", payload: Self.payload) {
        try coordinator.captureAuthenticatedSession(as: .normal)
      }
      #expect(PommeSecurityDesktopCleanup.completion(next, jobID: Self.job, digest: Self.digest) == true)
      #expect(replacement.operations.withLock { $0 } == ["authenticate", "agent.describe", "process.status"])
    }
  }

  private static func awaitPin(_ coordinator: PommeAgentVSOCKCoordinator) async throws -> PommeAuthenticatedAgentSession {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      if let pin = try? coordinator.captureAuthenticatedSession(as: .normal) { return pin }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw RunnerError.guestAgentUnavailable
  }

  private final class Transport: PommeAgentVSOCKTransport, Sendable {
    let accept = Mutex<(@Sendable (any PommeAgentVSOCKConnection) -> Void)?>(nil)
    func install(port: UInt32, accept: @escaping @Sendable (any PommeAgentVSOCKConnection) -> Void) throws {
      #expect(port == PommeAgentPort.persistentNormal)
      self.accept.withLock { $0 = accept }
    }
    func remove(port: UInt32) { accept.withLock { $0 = nil } }
    func connect(_ connection: Connection) { accept.withLock { $0 }?(connection) }
  }

  private final class Connection: PommeAgentVSOCKConnection, Sendable {
    let operations = Mutex<[String]>([])
    let replaceDuring: String
    let replace: @Sendable () async throws -> Void
    init(replaceDuring: String = "none", replace: @escaping @Sendable () async throws -> Void = {}) {
      self.replaceDuring = replaceDuring; self.replace = replace
    }
    func close() {}
    func exchange(_ request: Data, timeout: TimeInterval) async throws -> Data {
      let envelope = try PommeAgentProtocol.decode(Data(request.dropLast()))
      let operation = envelope.operation
      operations.withLock { $0.append(operation) }
      if operation == replaceDuring { try await replace() }
      if operation == "authenticate" {
        let challenge = try #require(envelope.payload.objectValue?["challenge"]?.stringValue)
        let proof = try PommeAgentAuthentication.proof(token: PommeSecurityDesktopCleanupTests.digest, challenge: challenge)
        return try PommeAgentProtocol.encode(.response(to: envelope, result: .object(["proof": .string(proof)])))
      }
      #expect(timeout == Constants.agentRoundTripTimeout)
      let session = Session(mode: "valid")
      if operation == "agent.describe" {
        let description = try await session.request(operation: operation, payload: envelope.payload)
        return try PommeAgentProtocol.encode(.response(to: envelope, result: description))
      }
      let result = try await session.requestCorrelated(operation: operation, payload: envelope.payload)
      let exit = try PommeAgentJobStreamFrame(jobID: PommeSecurityDesktopCleanupTests.job,
                                            frame: .init(requestID: envelope.requestID, stream: .exit))
      return try PommeAgentProtocol.encode(exit.envelope())
        + PommeAgentProtocol.encode(.response(to: envelope, result: result.result))
    }
  }

  @Test("Adapter validates one captured session before stripping the host marker", arguments: [
    "valid", "role", "protocol", "version", "digest", "capability", "malformedCapability", "wrongJob"
  ])
  func identityBeforeStatus(mode: String) async throws {
    let session = Session(mode: mode)
    let captures = Mutex(0)
    let response = await PommeSecurityDesktopCleanup.perform(operation: "process.status", payload: Self.payload) {
      captures.withLock { $0 += 1 }; return session
    }
    #expect(captures.withLock { $0 } == 1)
    #expect(session.events.withLock { $0 } == ((mode == "valid" || mode == "wrongJob") ? ["describe", "status"] : ["describe"]))
    #expect(response.objectValue?["state"] == .string(mode == "valid" ? "verified-status" : "rejected"))
    if mode == "valid" {
      #expect(PommeSecurityDesktopCleanup.completion(response, jobID: Self.job, digest: Self.digest) == true)
    }
  }

  @Test("Malformed reserved requests cannot capture or forward", arguments: ["operation", "digest", "uppercase", "job", "extra", "null"])
  func malformedRequest(mode: String) async throws {
    var payload = try #require(Self.payload.objectValue)
    switch mode {
    case "digest": payload[PommeSecurityDesktopCleanup.digestMarker] = .string("bad")
    case "uppercase": payload[PommeSecurityDesktopCleanup.digestMarker] = .string(Self.digest.uppercased())
    case "job": payload["jobID"] = .string("bad")
    case "extra": payload["extra"] = .bool(true)
    case "null": payload[PommeSecurityDesktopCleanup.digestMarker] = .null
    default: break
    }
    let response = await PommeSecurityDesktopCleanup.perform(
      operation: mode == "operation" ? "process.start" : "process.status", payload: .object(payload)
    ) { Issue.record("Rejected request must not capture"); return Session(mode: "valid") }
    #expect(response.objectValue?["state"] == .string("rejected"))
    #expect(PommeSecurityDesktopCleanup.handles(.init(operation: "process.start", payload: .object(payload))))
    #expect(PommeSecurityDesktopCleanup.handles(.init(operation: "process.status", payload: .object(["jobID": .string(Self.job.uuidString)]))) == false)
  }

  @Test("Adapter classifies only closed reconnect failures", arguments: [
    "unavailable", "connecting", "disconnected", "replaced", "timeout", "protocol", "guest", "missing", "unknown", "cancelled"
  ], ["capture", "describe", "status"])
  func closedFailures(kind: String, boundary: String) async {
    let error: any Error & Sendable
    switch kind {
    case "unavailable": error = RunnerError.guestAgentUnavailable
    case "connecting": error = RunnerError.guestAgentConnecting
    case "disconnected": error = RunnerError.guestAgentDisconnected
    case "replaced": error = PommeAgentVSOCKError.sessionReplaced
    case "timeout": error = RunnerError.guestAgentTimedOut("private")
    case "protocol": error = PommeAgentProtocol.Error.invalidResponse
    case "guest": error = PommeAgentSessionError(code: "operation-failed", message: "private")
    case "missing": error = PommeAgentSessionError(code: "not-found", message: "private")
    case "cancelled": error = CancellationError()
    default: error = POSIXError(.EIO)
    }
    let session = Session(mode: "valid", failure: error, failureBoundary: boundary)
    let response = await PommeSecurityDesktopCleanup.perform(operation: "process.status", payload: Self.payload) {
      if boundary == "capture" { throw error }; return session
    }
    let transient = ["unavailable", "connecting", "disconnected", "replaced"].contains(kind)
    #expect(response == .object(["ok": .bool(true), "hostExitCode": .integer(0), "desktopCleanupVersion": .integer(1),
                               "state": .string(transient ? "temporarily-unavailable" : "rejected")]))
    let expected = boundary == "capture" ? [] : boundary == "describe" ? ["describe"] : ["describe", "status"]
    #expect(session.events.withLock { $0 } == expected)
  }

  private final class Session: PommeDesktopCleanupSession, Sendable {
    let mode: String
    let failure: (any Error & Sendable)?
    let failureBoundary: String
    let events = Mutex<[String]>([])
    init(mode: String, failure: (any Error & Sendable)? = nil, failureBoundary: String = "") {
      self.mode = mode; self.failure = failure; self.failureBoundary = failureBoundary
    }
    func request(operation: String, payload: JSONValue) async throws -> JSONValue {
      events.withLock { $0.append("describe") }
      #expect(operation == "agent.describe"); #expect(payload == .object([:]))
      if failureBoundary == "describe", let failure { throw failure }
      var identity: [String: JSONValue] = [
        "role": .string("persistent"), "protocol": .string(PommeAgentProtocol.name),
        "version": .integer(Int64(PommeAgentProtocol.version)), "executableSHA256": .string(PommeSecurityDesktopCleanupTests.digest),
        "capabilities": .array([.string("process.status")])
      ]
      switch mode {
      case "role": identity["role"] = .string("recovery")
      case "protocol": identity["protocol"] = .string("other")
      case "version": identity["version"] = .bool(true)
      case "digest": identity["executableSHA256"] = .string(String(repeating: "b", count: 64))
      case "capability": identity["capabilities"] = .array([])
      case "malformedCapability": identity["capabilities"] = .array([.string("process.status"), .integer(1)])
      default: break
      }
      return .object(identity)
    }
    func requestCorrelated(operation: String, payload: JSONValue) async throws -> PommeAgentCorrelatedResult {
      events.withLock { $0.append("status") }
      #expect(operation == "process.status")
      #expect(payload == .object(["jobID": .string(PommeSecurityDesktopCleanupTests.job.uuidString.lowercased())]))
      if failureBoundary == "status", let failure { throw failure }
      let id = mode == "wrongJob" ? UUID() : PommeSecurityDesktopCleanupTests.job
      let requestID = UUID()
      return .init(requestID: requestID, result: .object(["jobID": .string(id.uuidString), "exited": .bool(false)]),
                   streamFrames: [try .init(jobID: id, frame: .init(requestID: requestID, stream: .exit))])
    }
  }
}
