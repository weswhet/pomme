import Foundation
import Testing

@Suite("Pomme AMFI stage coordinator")
struct PommeSecurityAMFIStagesTests {
  @Test("AMFI disable runs the Recovery policy stage before normal boot arguments")
  func disableRunsPolicyThenNormalBootArguments() async throws {
    let trace = StageTrace()
    let credentials = try testCredentials()
    let stages = PommeSecurityAMFIStages(
      operation: .amfiDisable,
      changePolicy: { supplied in
        await trace.recordPolicy(supplied)
        return verifiedStage("policy")
      },
      changeBootArguments: {
        await trace.recordBootArguments()
        return finalStage(disabled: true)
      })

    let result = try await stages.mutate(credentials: credentials)

    #expect(result == finalStage(disabled: true))
    #expect(await trace.events == [.policy, .bootArguments])
    #expect(await trace.policyCredentials == [credentials])
  }

  @Test("AMFI enable runs normal boot arguments before the Recovery policy stage")
  func enableRunsNormalBootArgumentsThenPolicy() async throws {
    let trace = StageTrace()
    let credentials = try testCredentials()
    let stages = PommeSecurityAMFIStages(
      operation: .amfiEnable,
      changePolicy: { supplied in
        await trace.recordPolicy(supplied)
        return finalStage(disabled: false)
      },
      changeBootArguments: {
        await trace.recordBootArguments()
        return verifiedStage("normalBootArguments")
      })

    let result = try await stages.mutate(credentials: credentials)

    #expect(result == finalStage(disabled: false))
    #expect(await trace.events == [.bootArguments, .policy])
    #expect(await trace.policyCredentials == [credentials])
  }

  @Test("An unverified first disable stage prevents the normal boot stage")
  func unverifiedDisablePolicyPreventsBootArguments() async throws {
    let trace = StageTrace()
    let credentials = try testCredentials()
    let stages = PommeSecurityAMFIStages(
      operation: .amfiDisable,
      changePolicy: { supplied in
        await trace.recordPolicy(supplied)
        return .object(["verified": .bool(false)])
      },
      changeBootArguments: {
        await trace.recordBootArguments()
        return finalStage(disabled: true)
      })

    do {
      _ = try await stages.mutate(credentials: credentials)
      Issue.record("Unverified AMFI policy stage unexpectedly continued")
    } catch {
      #expect(error as? PommeSecurityWorkflowError == .statusUnverified)
    }

    #expect(await trace.events == [.policy])
  }

  @Test("A failed first enable stage prevents the Recovery policy stage")
  func failedEnableBootArgumentsPreventsPolicy() async throws {
    let trace = StageTrace()
    let credentials = try testCredentials()
    let expected = StageTestError.firstStageFailed
    let stages = PommeSecurityAMFIStages(
      operation: .amfiEnable,
      changePolicy: { supplied in
        await trace.recordPolicy(supplied)
        return finalStage(disabled: false)
      },
      changeBootArguments: {
        await trace.recordBootArguments()
        throw expected
      })

    do {
      _ = try await stages.mutate(credentials: credentials)
      Issue.record("Failed AMFI boot-arguments stage unexpectedly continued")
    } catch {
      #expect(error as? StageTestError == expected)
    }

    #expect(await trace.events == [.bootArguments])
    #expect(await trace.policyCredentials.isEmpty)
  }

  @Test("A final AMFI state mismatch is rejected after both stages")
  func finalStateMismatchIsRejected() async throws {
    let trace = StageTrace()
    let credentials = try testCredentials()
    let stages = PommeSecurityAMFIStages(
      operation: .amfiEnable,
      changePolicy: { supplied in
        await trace.recordPolicy(supplied)
        return finalStage(disabled: true)
      },
      changeBootArguments: {
        await trace.recordBootArguments()
        return verifiedStage("normalBootArguments")
      })

    do {
      _ = try await stages.mutate(credentials: credentials)
      Issue.record("Mismatched final AMFI state unexpectedly passed")
    } catch {
      #expect(error as? PommeSecurityWorkflowError == .statusUnverified)
    }

    #expect(await trace.events == [.bootArguments, .policy])
  }

  @Test("Retries repeat stage order while durable guest receipts avoid duplicate native writes")
  func disableRetryUsesDurablePolicyReceipt() async throws {
    let trace = DisableRetryTrace()
    let credentials = try testCredentials()
    let stages = PommeSecurityAMFIStages(
      operation: .amfiDisable,
      changePolicy: { supplied in try await trace.changePolicy(supplied) },
      changeBootArguments: { try await trace.changeBootArguments() })

    do {
      _ = try await stages.mutate(credentials: credentials)
      Issue.record("Interrupted AMFI disable unexpectedly completed")
    } catch {
      #expect(error as? StageTestError == .bootStageInterrupted)
    }
    let result = try await stages.mutate(credentials: credentials)

    #expect(result == finalStage(disabled: true))
    #expect(await trace.events == [.policyWrite, .bootWrite, .policyReceipt, .bootReceipt])
    #expect(await trace.policyWrites == 1)
    #expect(await trace.bootWrites == 1)
    #expect(await trace.policyCredentials == [credentials, credentials])
  }

  @Test("Enable retry repeats normal-first ordering after a durable boot-arguments receipt")
  func enableRetryUsesDurableBootArgumentsReceipt() async throws {
    let trace = EnableRetryTrace()
    let credentials = try testCredentials()
    let stages = PommeSecurityAMFIStages(
      operation: .amfiEnable,
      changePolicy: { supplied in try await trace.changePolicy(supplied) },
      changeBootArguments: { try await trace.changeBootArguments() })

    do {
      _ = try await stages.mutate(credentials: credentials)
      Issue.record("Interrupted AMFI enable unexpectedly completed")
    } catch {
      #expect(error as? StageTestError == .bootStageInterrupted)
    }
    let result = try await stages.mutate(credentials: credentials)

    #expect(result == finalStage(disabled: false))
    #expect(await trace.events == [.bootWrite, .bootReceipt, .policyWrite])
    #expect(await trace.bootWrites == 1)
    #expect(await trace.policyWrites == 1)
    #expect(await trace.policyCredentials == [credentials])
  }
}

private actor StageTrace {
  enum Event: Equatable, Sendable {
    case policy
    case bootArguments
  }

  private(set) var events: [Event] = []
  private(set) var policyCredentials: [PommeGuestSecurityCredentials] = []

  func recordPolicy(_ credentials: PommeGuestSecurityCredentials) {
    policyCredentials.append(credentials)
    events.append(.policy)
  }

  func recordBootArguments() {
    events.append(.bootArguments)
  }
}

private actor DisableRetryTrace {
  enum Event: Equatable, Sendable {
    case policyWrite
    case bootWrite
    case policyReceipt
    case bootReceipt
  }

  private(set) var events: [Event] = []
  private(set) var policyWrites = 0
  private(set) var bootWrites = 0
  private(set) var policyCredentials: [PommeGuestSecurityCredentials] = []
  private var policyDurable = false
  private var bootDurable = false
  private var failBootOnce = true

  func changePolicy(_ credentials: PommeGuestSecurityCredentials) -> JSONValue {
    policyCredentials.append(credentials)
    if policyDurable {
      events.append(.policyReceipt)
    } else {
      policyDurable = true
      policyWrites += 1
      events.append(.policyWrite)
    }
    return verifiedStage("policy")
  }

  func changeBootArguments() throws -> JSONValue {
    if bootDurable {
      events.append(.bootReceipt)
      return finalStage(disabled: true)
    }
    bootDurable = true
    bootWrites += 1
    events.append(.bootWrite)
    if failBootOnce {
      failBootOnce = false
      throw StageTestError.bootStageInterrupted
    }
    return finalStage(disabled: true)
  }
}

private actor EnableRetryTrace {
  enum Event: Equatable, Sendable {
    case bootWrite
    case bootReceipt
    case policyWrite
  }

  private(set) var events: [Event] = []
  private(set) var bootWrites = 0
  private(set) var policyWrites = 0
  private(set) var policyCredentials: [PommeGuestSecurityCredentials] = []
  private var bootDurable = false
  private var policyDurable = false
  private var failBootOnce = true

  func changeBootArguments() throws -> JSONValue {
    if bootDurable {
      events.append(.bootReceipt)
      return verifiedStage("normalBootArguments")
    }
    bootDurable = true
    bootWrites += 1
    events.append(.bootWrite)
    if failBootOnce {
      failBootOnce = false
      throw StageTestError.bootStageInterrupted
    }
    return verifiedStage("normalBootArguments")
  }

  func changePolicy(_ credentials: PommeGuestSecurityCredentials) -> JSONValue {
    policyCredentials.append(credentials)
    if !policyDurable {
      policyDurable = true
      policyWrites += 1
      events.append(.policyWrite)
    }
    return finalStage(disabled: false)
  }
}

private enum StageTestError: Error, Equatable, Sendable {
  case firstStageFailed
  case bootStageInterrupted
}

private func testCredentials() throws -> PommeGuestSecurityCredentials {
  try PommeGuestSecurityCredentials(username: "owner", password: "offline-stage-secret")
}

private func verifiedStage(_ name: String) -> JSONValue {
  .object(["verified": .bool(true), "stage": .string(name)])
}

private func finalStage(disabled: Bool) -> JSONValue {
  .object(["verified": .bool(true), "amfiDisabled": .bool(disabled)])
}
