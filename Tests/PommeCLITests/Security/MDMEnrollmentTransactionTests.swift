import Foundation
import Testing

@Suite("Pomme MDM enrollment transaction")
struct MDMEnrollmentTransactionTests {
    @Test("Success uses authenticated describe, typed staging, file transfer, cleanup, and restoration in order")
    func successOrdering() async throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let events = EventRecorder()

        let transaction = makeTransaction(profile: profile, events: events)
        let result = try await transaction.execute()

        #expect(result.profileIdentifier == "com.example.mdm")
        #expect(result.transferredBytes == 4)
        #expect(result.agentCapabilities == MDMEnrollmentAgentDescription.requiredCapabilities.sorted())
        let recorded = await events.values()
        #expect(recorded.count == 8)
        #expect(recorded[0] == "describe")
        #expect(recorded[1] == "capture")
        #expect(recorded[2] == "prepare")
        #expect(recorded[3].hasPrefix("transfer:"))
        #expect(recorded[4].hasPrefix("enroll:"))
        #expect(recorded[5].hasPrefix("cleanup:"))
        #expect(recorded[6] == "restore")
        #expect(recorded[7] == "verify")
        #expect(recorded[3].split(separator: ":", maxSplits: 1).last?.hasPrefix("/private/var/db/pomme-mdm-enrollment/") == true)
        #expect(recorded[3].split(separator: ":", maxSplits: 1).last == recorded[4].split(separator: ":", maxSplits: 1).last)
        #expect(recorded[4].split(separator: ":", maxSplits: 1).last == recorded[5].split(separator: ":", maxSplits: 1).last)
    }

    @Test("Missing authentication or capabilities fails before baseline and guest effects")
    func agentGatePrecedesEffects() async throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let events = EventRecorder()
        let agent = PommeMDMEnrollmentAgentDependencies(
            describe: {
                await events.append("describe")
                return .init(
                    connected: true,
                    authenticated: false,
                    role: "persistent",
                    protocolName: MDMEnrollmentAgentDescription.protocolName,
                    protocolVersion: MDMEnrollmentAgentDescription.protocolVersion,
                    executableDigest: String(repeating: "a", count: 64),
                    capabilities: MDMEnrollmentAgentDescription.requiredCapabilities
                )
            },
            perform: { _ in
                await events.append("perform")
                return .object([:])
            },
            transferProfile: { _, _ in
                await events.append("transfer")
                throw TestFailure.injected
            }
        )
        let state = makeState(events: events)
        let transaction = PommeMDMEnrollmentTransaction(
            agent: agent,
            state: state,
            profileURL: profile,
            timeout: 60
        )

        do {
            _ = try await transaction.execute()
            Issue.record("Expected the unauthenticated agent to be rejected.")
        } catch let error as PommeMDMEnrollmentError {
            #expect(error == .agentUnverified)
        }
        #expect(await events.values() == ["describe"])
    }

    @Test("A transfer failure still invokes cleanup and restores the captured baseline")
    func transferFailureRestores() async throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let events = EventRecorder()
        let agent = makeAgent(events: events, transferError: true)
        let transaction = PommeMDMEnrollmentTransaction(
            agent: agent,
            state: makeState(events: events),
            profileURL: profile,
            timeout: 60
        )

        do {
            _ = try await transaction.execute()
            Issue.record("Expected transfer failure.")
        } catch let error as PommeMDMEnrollmentError {
            #expect(error == .transferFailed)
        }
        let recorded = await events.values()
        #expect(recorded.contains("prepare"))
        #expect(recorded.contains(where: { $0.hasPrefix("transfer:") }))
        #expect(recorded.contains(where: { $0.hasPrefix("cleanup:") }))
        #expect(Array(recorded.suffix(2)) == ["restore", "verify"])
    }

    @Test("A malformed or unavailable baseline fails before staging and transfer")
    func baselineCaptureFailsClosed() async throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let events = EventRecorder()
        let state = PommeMDMEnrollmentStateDependencies(
            capture: {
                await events.append("capture")
                return .init(sip: Data(), amfi: Data([2]), runState: .stopped)
            },
            restore: { _ in await events.append("restore") },
            verify: { _ in await events.append("verify"); return true }
        )
        let transaction = PommeMDMEnrollmentTransaction(
            agent: makeAgent(events: events),
            state: state,
            profileURL: profile,
            timeout: 60
        )

        do {
            _ = try await transaction.execute()
            Issue.record("Expected baseline capture failure.")
        } catch let error as PommeMDMEnrollmentError {
            #expect(error == .baselineCaptureFailed)
        }
        #expect(await events.values() == ["describe", "capture"])
    }

    @Test("Cleanup failure is reported after successful enrollment and restoration")
    func cleanupFailureIsFailClosed() async throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let events = EventRecorder()
        let agent = makeAgent(events: events, cleanupError: true)
        let transaction = PommeMDMEnrollmentTransaction(
            agent: agent,
            state: makeState(events: events),
            profileURL: profile,
            timeout: 60
        )

        do {
            _ = try await transaction.execute()
            Issue.record("Expected cleanup failure.")
        } catch let error as PommeMDMEnrollmentError {
            #expect(error == .cleanupFailed)
        }
        let recorded = await events.values()
        #expect(Array(recorded.suffix(2)) == ["restore", "verify"])
    }

    @Test("Restoration failure takes precedence over enrollment and cleanup failures")
    func restorationFailureHasPriority() async throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let events = EventRecorder()
        let agent = makeAgent(events: events, transferError: true, cleanupError: true)
        let state = makeState(events: events, restorationError: true)
        let transaction = PommeMDMEnrollmentTransaction(
            agent: agent,
            state: state,
            profileURL: profile,
            timeout: 60
        )

        do {
            _ = try await transaction.execute()
            Issue.record("Expected restoration failure.")
        } catch let error as PommeMDMEnrollmentError {
            #expect(error == .restorationFailed)
        }
        let recorded = await events.values()
        #expect(recorded.contains(where: { $0.hasPrefix("cleanup:") }))
        #expect(Array(recorded.suffix(2)) == ["restore", "verify"])
    }

    @Test("Unproven helper termination retains the profile while checking the baseline")
    func unprovenHelperRetainsProfile() async throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let events = EventRecorder()
        let transaction = PommeMDMEnrollmentTransaction(
            agent: makeAgent(events: events),
            state: makeState(events: events),
            profileURL: profile,
            timeout: 60,
            temporaryHelper: PommeMDMTemporaryHelperDependencies { _, _, _ in
                throw PommeMDMEnrollmentError.helperProcessTerminationUnproven
            }
        )
        do {
            _ = try await transaction.execute()
            Issue.record("Expected unproven helper termination")
        } catch let error as PommeMDMEnrollmentError {
            #expect(error == .helperProcessTerminationUnproven)
        }
        let recorded = await events.values()
        #expect(!recorded.contains(where: { $0.hasPrefix("cleanup:") }))
        #expect(Array(recorded.suffix(2)) == ["restore", "verify"])
    }

    @Test("Typed operation payloads have closed names and fixed staging paths")
    func typedOperations() throws {
        let path = "\(MDMProfileStaging.guestDirectory)/profile.mobileconfig"
        let enroll = PommeMDMEnrollmentAgentOperation.enroll(profilePath: path, timeout: 60)
        let enrollPayload = try enroll.payload()
        #expect(enroll.wireName == "mdm.enrollment")
        #expect(enrollPayload == .object([
            "action": .string("enroll"),
            "profilePath": .string(path),
            "timeout": .number(60)
        ]))
        #expect(PommeMDMEnrollmentAgentOperation.prepareStaging.wireName == "mdm.staging.prepare")
        let approval = PommeMDMEnrollmentAgentOperation.approve(profileIdentifier: "com.example.mdm", timeout: 60)
        let approvalPayload = try approval.payload()
        #expect(approval.wireName == "mdm.enrollment")
        #expect(approvalPayload == .object([
            "action": .string("approve"),
            "profileIdentifier": .string("com.example.mdm"),
            "timeout": .number(60)
        ]))
        #expect(PommeMDMEnrollmentAgentOperation.cleanup(profilePath: path).wireName == "mdm.staging.cleanup")
        #expect(throws: PommeMDMEnrollmentError.self) {
            _ = try PommeMDMEnrollmentAgentOperation.cleanup(profilePath: "/tmp/profile.mobileconfig").payload()
        }
    }

    @Test("Describe parsing requires the exact authenticated evidence shape")
    func authenticatedDescribeParsing() throws {
        let value = JSONValue.object([
            "role": .string("persistent"),
            "protocol": .string("PommeAgentProtocol"),
            "version": .integer(1),
            "executableSHA256": .string(String(repeating: "a", count: 64)),
            "capabilities": .array(
                MDMEnrollmentAgentDescription.requiredCapabilities.sorted().map(JSONValue.string)
            )
        ])
        let description = try MDMEnrollmentAgentDescription.fromAuthenticatedDescribe(value)
        #expect(description.authenticated)
        #expect(description.connected)
        #expect(description.role == MDMEnrollmentAgentDescription.normalRole)
        #expect(description.executableDigest == String(repeating: "a", count: 64))
        #expect(description.capabilities == MDMEnrollmentAgentDescription.requiredCapabilities)

        #expect(throws: PommeMDMEnrollmentError.self) {
            _ = try MDMEnrollmentAgentDescription.fromAuthenticatedDescribe(
                .object(value.objectValue!.merging(["unexpected": .bool(true)]) { current, _ in current })
            )
        }
    }

    @Test("Malformed guest responses and transfer receipts fail closed")
    func malformedResponses() async throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let events = EventRecorder()
        let agent = PommeMDMEnrollmentAgentDependencies(
            describe: {
                await events.append("describe")
                return Self.verifiedAgentDescription()
            },
            perform: { operation in
                switch operation {
                case .prepareStaging:
                    await events.append("prepare")
                    return .object(["ready": .bool(false)])
                case let .cleanup(path):
                    await events.append("cleanup:\(path)")
                    return .object(["removed": .bool(true)])
                default:
                    return .object([:])
                }
            },
            transferProfile: { _, _ in
                await events.append("transfer")
                return try PommeMDMProfileTransferReceipt(
                    destination: "\(MDMProfileStaging.guestDirectory)/profile.mobileconfig",
                    bytes: 1,
                    sha256: "bad"
                )
            }
        )
        let transaction = PommeMDMEnrollmentTransaction(
            agent: agent,
            state: makeState(events: events),
            profileURL: profile,
            timeout: 60
        )
        do {
            _ = try await transaction.execute()
            Issue.record("Expected malformed staging response.")
        } catch let error as PommeMDMEnrollmentError {
            #expect(error == .stagingPreparationFailed)
        }
        let recorded = await events.values()
        #expect(recorded.contains(where: { $0.hasPrefix("cleanup:") }))
    }

    private func makeTransaction(profile: URL, events: EventRecorder) -> PommeMDMEnrollmentTransaction {
        PommeMDMEnrollmentTransaction(
            agent: makeAgent(events: events),
            state: makeState(events: events),
            profileURL: profile,
            timeout: 60
        )
    }

    private func makeAgent(
        events: EventRecorder,
        transferError: Bool = false,
        cleanupError: Bool = false
    ) -> PommeMDMEnrollmentAgentDependencies {
        PommeMDMEnrollmentAgentDependencies(
            describe: {
                await events.append("describe")
                return Self.verifiedAgentDescription()
            },
            perform: { operation in
                switch operation {
                case .prepareStaging:
                    await events.append("prepare")
                    return .object(["ready": .bool(true)])
                case let .enroll(path, _):
                    await events.append("enroll:\(path)")
                    return .object([
                        "completed": .bool(true),
                        "profileIdentifier": .string("com.example.mdm")
                    ])
                case .approve:
                    await events.append("approve")
                    return .object(["completed": .bool(true)])
                case let .cleanup(path):
                    await events.append("cleanup:\(path)")
                    if cleanupError { throw TestFailure.injected }
                    return .object(["removed": .bool(true)])
                }
            },
            transferProfile: { _, destination in
                await events.append("transfer:\(destination)")
                if transferError { throw TestFailure.injected }
                return try PommeMDMProfileTransferReceipt(
                    destination: destination,
                    bytes: 4,
                    sha256: String(repeating: "a", count: 64)
                )
            }
        )
    }

    private func makeState(
        events: EventRecorder,
        restorationError: Bool = false
    ) -> PommeMDMEnrollmentStateDependencies {
        let baseline = PommeMDMEnrollmentStateBaseline(
            sip: Data([1]),
            amfi: Data([2]),
            runState: .stopped
        )
        return .init(
            capture: {
                await events.append("capture")
                return baseline
            },
            restore: { _ in
                await events.append("restore")
                if restorationError { throw TestFailure.injected }
            },
            verify: { _ in
                await events.append("verify")
                return !restorationError
            }
        )
    }

    private static func verifiedAgentDescription() -> MDMEnrollmentAgentDescription {
        .init(
            connected: true,
            authenticated: true,
            role: "persistent",
            protocolName: MDMEnrollmentAgentDescription.protocolName,
            protocolVersion: MDMEnrollmentAgentDescription.protocolVersion,
            executableDigest: String(repeating: "a", count: 64),
            capabilities: MDMEnrollmentAgentDescription.requiredCapabilities
        )
    }

    private func makeProfile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-mdm-\(UUID().uuidString).mobileconfig")
        try Data([0, 1, 2, 3]).write(to: url, options: .atomic)
        return url
    }

    private actor EventRecorder {
        private var events: [String] = []

        func append(_ event: String) { events.append(event) }
        func values() -> [String] { events }
    }

    private enum TestFailure: Error {
        case injected
    }
}
