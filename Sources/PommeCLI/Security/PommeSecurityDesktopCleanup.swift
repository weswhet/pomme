import Foundation

/// The concrete pin enforces coordinator identity before and after both calls.
/// Injecting this narrow surface lets tests exercise the complete adapter.
protocol PommeDesktopCleanupSession: Sendable {
  func request(operation: String, payload: JSONValue) async throws -> JSONValue
  func requestCorrelated(operation: String, payload: JSONValue) async throws -> PommeAgentCorrelatedResult
}

extension PommeAuthenticatedAgentSession: PommeDesktopCleanupSession {}

enum PommeSecurityDesktopCleanup {
  static let digestMarker = "_pommeExpectedDesktopCleanupExecutableSHA256"
  private enum Rejection: Error { case invalidRequest, identity, status }

  /// Presence reserves the request even when the operation or marker is bad.
  /// Malformed security requests must never fall through to ordinary forwarding.
  static func handles(_ request: PommeAgentPerformRequest) -> Bool {
    request.payload?.objectValue?[digestMarker] != nil
  }

  static func perform(
    operation: String, payload: JSONValue?,
    capture: () throws -> any PommeDesktopCleanupSession
  ) async -> JSONValue {
    do {
      guard operation == "process.status", let object = payload?.objectValue,
        Set(object.keys) == [digestMarker, "jobID"],
        let digest = object[digestMarker]?.stringValue,
        PommeProvisioningDigest.isSHA256(digest), digest == digest.lowercased(),
        let job = object["jobID"]?.stringValue, let jobID = UUID(uuidString: job),
        jobID.uuidString.lowercased() == job
      else { throw Rejection.invalidRequest }
      let session = try capture()
      let description = try await session.request(operation: "agent.describe", payload: .object([:]))
      guard let identity = description.objectValue,
        identity["role"] == .string("persistent"),
        identity["protocol"] == .string(PommeAgentProtocol.name),
        identity["version"] == .integer(Int64(PommeAgentProtocol.version)),
        identity["executableSHA256"] == .string(digest),
        case .array(let capabilities)? = identity["capabilities"],
        capabilities.allSatisfy({ $0.stringValue != nil }),
        capabilities.contains(.string("process.status"))
      else { throw Rejection.identity }
      let status = try await session.requestCorrelated(
        operation: "process.status", payload: .object(["jobID": .string(job)]))
      let response = JSONValue.object([
        "ok": .bool(true), "result": status.result,
        "streamFrames": .array(try status.streamFrames.map { try JSONValue(any: PommeCore.agentStreamPayload($0)) })
      ])
      // Same-job shape validation is required here and again by the caller.
      // exited=false with a subsequently emitted exit frame remains valid.
      guard PommeSecurityNormalAgent.desktopCleanupStatus(response, jobID: jobID) != nil else {
        throw Rejection.status
      }
      return .object([
        "ok": .bool(true), "hostExitCode": .integer(0),
        "desktopCleanupVersion": .integer(1), "state": .string("verified-status"),
        "jobID": .string(job), "executableSHA256": .string(digest), "status": response
      ])
    } catch {
      return .object([
        "ok": .bool(true), "hostExitCode": .integer(0),
        "desktopCleanupVersion": .integer(1),
        "state": .string(isTemporarilyUnavailable(error) ? "temporarily-unavailable" : "rejected")
      ])
    }
  }

  private static func isTemporarilyUnavailable(_ error: Error) -> Bool {
    if let error = error as? RunnerError {
      switch error {
      case .guestAgentUnavailable, .guestAgentConnecting, .guestAgentDisconnected: return true
      default: return false
      }
    }
    return (error as? PommeAgentVSOCKError) == .sessionReplaced
  }

  /// nil rejects old helpers, guest envelopes and unknown host receipts.
  /// false authorizes only another status poll, never another desktop probe.
  static func completion(_ response: JSONValue, jobID: UUID, digest: String) -> Bool? {
    guard let object = response.objectValue, object["desktopCleanupVersion"] == .integer(1),
      object["ok"] == .bool(true), object["hostExitCode"] == .integer(0)
    else { return nil }
    switch object["state"] {
    case .string("temporarily-unavailable"):
      return Set(object.keys) == ["ok", "hostExitCode", "desktopCleanupVersion", "state"] ? false : nil
    case .string("verified-status"):
      guard Set(object.keys) == ["ok", "hostExitCode", "desktopCleanupVersion", "state", "jobID", "executableSHA256", "status"],
        object["jobID"] == .string(jobID.uuidString.lowercased()),
        object["executableSHA256"] == .string(digest), let status = object["status"]
      else { return nil }
      return PommeSecurityNormalAgent.desktopCleanupStatus(status, jobID: jobID)
    default: return nil
    }
  }
}
