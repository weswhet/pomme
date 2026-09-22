import Darwin
import Foundation
import Synchronization
import Testing

/// Real daemon descriptor reads block between requests, so these two registry
/// cases are serialized. No VM, host credential, or production file is used.
@Suite(.serialized)
struct PommeSecurityDesktopCleanupIntegrationTests {
  private static let digest = String(repeating: "a", count: 64)

  @Test("Malformed relay input is reported after teardown and repeated finish is safe")
  func malformedRelayFinish() async throws {
    let agent = try PommeAgent(role: .persistent, executableSHA256: Self.digest)
    let relay = try Relay(agent: agent, dropSignalResponse: false)
    relay.start()
    do { try relay.sendMalformedFrame() }
    catch { try? await relay.finish(); throw error }
    // Synchronize on actual decode failure, not a near-deadline sleep.
    _ = await relay.waitForLoop()
    await #expect(throws: Relay.Failure.invalidFrame) { try await relay.finish() }
    await #expect(throws: Relay.Failure.invalidFrame) { try await relay.finish() }
    #expect(relay.closed.withLock { $0 })
    #expect(relay.operations.withLock { $0 }.isEmpty)
  }

  @Test("Real lost signal response reconnects through coordinator and cleanup adapter", arguments: [false, true])
  func lostSignalResponse(newRegistry: Bool) async throws {
    let agent = try PommeAgent(role: .persistent, executableSHA256: Self.digest)
    let transport = Transport()
    let coordinator = PommeAgentVSOCKCoordinator(transport: transport, secretProvider: { _ in Self.digest })
    let first = try Relay(agent: agent, dropSignalResponse: true)
    var second: Relay?
    var jobID: UUID?
    do {
      try coordinator.attachNormal()
      first.start()
      transport.connect(first)
      let pin = try await Self.awaitPin(coordinator)
      let started = try await pin.request(operation: "process.start", payload: .object([
        "path": .string("/bin/sleep"), "arguments": .array([.string("10")])
      ]))
      let text = try #require(started.objectValue?["jobID"]?.stringValue)
      let id = try #require(UUID(uuidString: text))
      jobID = id
      do {
        _ = try await pin.request(operation: "process.signal", payload: .object([
          "jobID": .string(text), "signal": .integer(Int64(SIGTERM))
        ]))
        Issue.record("The real wire must time out waiting for the withheld response")
      } catch RunnerError.guestAgentTimedOut(let operation) {
        #expect(operation == "Pomme agent exchange")
      }
      // This receipt is set only after the relay receives the actual successful
      // daemon response. Thus timeout cannot pass by merely failing to deliver.
      try #require(first.withheld.withLock { $0 })
      #expect(first.closed.withLock { $0 })
      #expect(throws: RunnerError.self) { try coordinator.captureAuthenticatedSession(as: .normal) }
      try await first.finish()
      #expect(first.operations.withLock { $0 } == ["authenticate", "process.start", "process.signal"])

      let nextAgent = try newRegistry ? PommeAgent(role: .persistent, executableSHA256: Self.digest) : agent
      let next = try Relay(agent: nextAgent, dropSignalResponse: false)
      second = next
      next.start()
      transport.connect(next)
      _ = try await Self.awaitPin(coordinator)
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      var completion: Bool?
      repeat {
        let receipt = await PommeSecurityDesktopCleanup.perform(operation: "process.status", payload: .object([
          "jobID": .string(id.uuidString.lowercased()),
          PommeSecurityDesktopCleanup.digestMarker: .string(Self.digest)
        ])) { try coordinator.captureAuthenticatedSession(as: .normal) }
        let normalized = try JSONValue(any: PommeCore.normalizedControlObject(receipt))
        completion = PommeSecurityDesktopCleanup.completion(normalized, jobID: id, digest: Self.digest)
        if newRegistry {
          #expect(receipt.objectValue?["state"] == .string("rejected"))
          #expect(next.notFound.withLock { $0 })
          break
        }
        if completion != false { break }
        await Task.yield()
      } while ContinuousClock.now < deadline
      #expect(completion == (newRegistry ? nil : true))
      let operations = next.operations.withLock { $0 }
      #expect(operations.first == "authenticate")
      #expect(operations.dropFirst().isEmpty == false)
      #expect(operations.dropFirst().allSatisfy { $0 == "agent.describe" || $0 == "process.status" })
      #expect(next.forwardedPayloads.withLock { $0 }.allSatisfy {
        $0 == .object(["jobID": .string(id.uuidString.lowercased())])
      })
      coordinator.teardown()
      try await next.finish()
    } catch {
      coordinator.teardown()
      // Teardown failures must not skip the other relay or child cleanup.
      do { try await first.finish() }
      catch { Issue.record("Relay A teardown failed: \(error)") }
      if let second {
        do { try await second.finish() }
        catch { Issue.record("Relay B teardown failed: \(error)") }
      }
      if let jobID { await Self.cleanChild(agent, jobID: jobID, force: true) }
      throw error
    }
    // Also reap/drain the original registry in the fresh-registry negative.
    if let jobID { await Self.cleanChild(agent, jobID: jobID, force: false) }
  }

  private static func cleanChild(_ agent: PommeAgent, jobID: UUID, force: Bool) async {
    if force {
      _ = try? await agent.perform(.request(operation: "process.signal", payload: .object([
        "jobID": .string(jobID.uuidString.lowercased()), "signal": .integer(Int64(SIGKILL))
      ])))
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var reaped = false
    repeat {
      let frames = try? await agent.streamEvents(jobID: jobID, requestID: UUID())
      reaped = frames?.contains(where: { $0.stream == .exit }) == true
      if reaped { break }
      await Task.yield()
    } while ContinuousClock.now < deadline
    #expect(reaped, "Bounded child must be reaped even after test failure")
  }

  private static func awaitPin(_ coordinator: PommeAgentVSOCKCoordinator) async throws -> PommeAuthenticatedAgentSession {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    repeat {
      if let pin = try? coordinator.captureAuthenticatedSession(as: .normal) { return pin }
      await Task.yield()
    } while ContinuousClock.now < deadline
    throw RunnerError.guestAgentUnavailable
  }

  private final class Transport: PommeAgentVSOCKTransport, Sendable {
    let accept = Mutex<(@Sendable (any PommeAgentVSOCKConnection) -> Void)?>(nil)
    func install(port: UInt32, accept: @escaping @Sendable (any PommeAgentVSOCKConnection) -> Void) throws {
      #expect(port == PommeAgentPort.persistentNormal)
      self.accept.withLock { $0 = accept }
    }
    func remove(port: UInt32) { accept.withLock { $0 = nil } }
    func connect(_ connection: Relay) { accept.withLock { $0 }?(connection) }
  }

  /// Two socketpairs put a transparent test relay between the real host wire
  /// and real daemon. Only A's successful signal response is discarded.
  /// start() is called once by the owning test before publishing the connection.
  /// Mutable cross-thread observations/completion are mutex-protected. finish()
  /// is shared/idempotent; descriptors close only after both workers finish and
  /// the owning test has completed its host exchanges.
  private final class Relay: PommeAgentVSOCKConnection, @unchecked Sendable {
    enum Failure: Error, Equatable { case invalidFrame, invalidAcknowledgement }
    private struct Completion {
      var result: Result<Void, any Error>?
      var waiters: [CheckedContinuation<Result<Void, any Error>, Never>] = []
    }
    private let completion = Mutex(Completion())
    private let finishing = Mutex<Task<Void, any Error>?>(nil)
    let operations = Mutex<[String]>([])
    let forwardedPayloads = Mutex<[JSONValue]>([])
    let withheld = Mutex(false)
    let notFound = Mutex(false)
    let closed = Mutex(false)
    private let host: Int32
    private let relay: Int32
    private let guestClient: Int32
    private let guestServer: Int32
    private let agent: PommeAgent
    private let connection: PommeAgentConnection
    private let dropSignalResponse: Bool
    private var daemonTask: Task<Void, Never>?
    private var relayThread: Thread?

    init(agent: PommeAgent, dropSignalResponse: Bool) throws {
      let connection = try PommeAgentConnection(token: PommeSecurityDesktopCleanupIntegrationTests.digest, lifetime: .persistent)
      var a: [Int32] = [-1, -1]
      var b: [Int32] = [-1, -1]
      guard socketpair(AF_UNIX, SOCK_STREAM, 0, &a) == 0 else { throw POSIXError(.EIO) }
      guard socketpair(AF_UNIX, SOCK_STREAM, 0, &b) == 0 else {
        _ = Darwin.close(a[0]); _ = Darwin.close(a[1]); throw POSIXError(.EIO)
      }
      host = a[0]; relay = a[1]; guestClient = b[0]; guestServer = b[1]
      self.agent = agent; self.connection = connection; self.dropSignalResponse = dropSignalResponse
      for fd in a + b {
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
      }
    }

    func start() {
      daemonTask = Task.detached { [self] in
        await PommeAgentDaemon.serve(descriptor: guestServer, connection: connection, agent: agent, allowedOperation: nil)
      }
      let thread = Thread { [self] in
        let outcome: Result<Void, any Error>
        do {
          while let data = try readLine() {
            let request: PommeAgentProtocol.Envelope
            do { request = try PommeAgentProtocol.decode(data) }
            catch { throw Failure.invalidFrame }
            operations.withLock { $0.append(request.operation) }
            if request.operation == "process.status" { forwardedPayloads.withLock { $0.append(request.payload) } }
            let response = try PommeAgentVSOCKWire(fileDescriptor: guestClient).exchange(
              try PommeAgentProtocol.encode(request), timeout: 2)
            let frames = try response.split(separator: 0x0A).map { try PommeAgentProtocol.decode(Data($0)) }
            if frames.contains(where: { $0.error?.code == "not-found" }) { notFound.withLock { $0 = true } }
            if dropSignalResponse && request.operation == "process.signal" {
              guard let ack = frames.last,
                ack.kind == .response && ack.ok == true && ack.requestID == request.requestID
              else { throw Failure.invalidAcknowledgement }
              withheld.withLock { $0 = true }
              continue
            }
            try writeAll(response)
          }
          outcome = .success(())
        } catch {
          if error is Failure || closed.withLock({ $0 }) == false {
            outcome = .failure(error)
          } else {
            outcome = .success(())
          }
        }
        let waiters = completion.withLock { state in
          state.result = outcome
          let waiters = state.waiters
          state.waiters.removeAll()
          return waiters
        }
        // No descriptor access occurs after publishing completion.
        for waiter in waiters { waiter.resume(returning: outcome) }
      }
      relayThread = thread
      thread.start()
    }

    func exchange(_ request: Data, timeout: TimeInterval) async throws -> Data {
      let envelope = try PommeAgentProtocol.decode(Data(request.dropLast()))
      // Test-only short deadline; still the production wire's poll/deadline
      // path, never a synthetic thrown timeout. Other exchanges keep 5 seconds.
      let budget = dropSignalResponse && envelope.operation == "process.signal" ? 1 : timeout
      return try await Task.detached { [host] in
        try PommeAgentVSOCKWire(fileDescriptor: host).exchange(request, timeout: budget)
      }.value
    }

    func close() {
      closed.withLock { value in
        guard !value else { return }
        value = true
        _ = shutdown(host, SHUT_RDWR)
      }
    }

    func waitForLoop() async -> Result<Void, any Error> {
      await withCheckedContinuation { continuation in
        let ready: Result<Void, any Error>? = completion.withLock { state in
          if let result = state.result { return result }
          state.waiters.append(continuation)
          return nil
        }
        if let ready { continuation.resume(returning: ready) }
      }
    }

    func finish() async throws {
      let task = finishing.withLock { task in
        if let task { return task }
        let created = Task { [self] in
          close()
          for fd in [relay, guestClient, guestServer] { _ = shutdown(fd, SHUT_RDWR) }
          let outcome = await waitForLoop()
          await daemonTask?.value
          for fd in [host, relay, guestClient, guestServer] { _ = Darwin.close(fd) }
          try outcome.get()
        }
        task = created
        return created
      }
      try await task.value
    }

    func sendMalformedFrame() throws {
      var newline: UInt8 = 0x0A
      guard send(host, &newline, 1, 0) == 1 else { throw POSIXError(.EIO) }
    }

    private func readLine() throws -> Data? {
      var line = Data()
      while line.count <= PommeAgentProtocol.maximumFrameBytes {
        var byte: UInt8 = 0
        let count = recv(relay, &byte, 1, 0)
        if count == 0 { return nil }
        if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
        if byte == 0x0A { return line }
        line.append(byte)
      }
      throw PommeAgentProtocol.Error.malformedFrame
    }

    private func writeAll(_ data: Data) throws {
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = send(relay, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
          if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
          guard count > 0 else { throw POSIXError(.EIO) }
          offset += count
        }
      }
    }
  }
}
