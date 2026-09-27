import Foundation
import Synchronization
import Testing

@Suite("Bootstrap Buddy preference receipt guard")
struct PommeBootstrapBuddyPreferencesTests {
    private static let owner = PommeBuddyPreferencesOwner(account: "pomme", uid: 501,
        generatedUID: "22222222-2222-2222-2222-222222222222", homeDirectory: "/Users/pomme")

    private static func receipt() -> PommeBuddyPreferencesStatus {
        .init(bootSessionUUID: "11111111-1111-1111-1111-111111111111", productVersion: "27.0",
              buildVersion: "26A428", owner: owner, stage: "complete", outcome: "succeeded")
    }

    private static func payload(_ receipt: PommeBuddyPreferencesStatus) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(receipt))
    }

    @Test("native owner lookup uses a bounded local directory query")
    func readsNativeOwner() async throws {
        let value = try await PommeBootstrapBuddyPreferences.readOwner { command in
            #expect(command.path == "/usr/bin/dscl")
            #expect(command.arguments == ["-plist", "/Local/Default", "-read", "/Users/pomme",
                "RecordName", "UniqueID", "GeneratedUID", "NFSHomeDirectory"])
            #expect(command.timeout == 15)
            #expect(!command.pty)
            return try Self.ownerResult()
        }
        #expect(value == Self.owner)
    }

    private static func ownerResult(mode: String = "valid") throws -> GuestCommandResult {
        var attributes: [String: Any] = [
            "dsAttrTypeStandard:RecordName": [owner.account],
            "dsAttrTypeStandard:UniqueID": [String(owner.uid)],
            "dsAttrTypeStandard:GeneratedUID": [owner.generatedUID],
            "dsAttrTypeStandard:NFSHomeDirectory": [owner.homeDirectory]
        ]
        switch mode {
        case "multiple": attributes["dsAttrTypeStandard:RecordName"] = ["pomme", "alias"]
        case "numericType": attributes["dsAttrTypeStandard:UniqueID"] = [501]
        case "scalar": attributes["dsAttrTypeStandard:RecordName"] = "pomme"
        case "uidFormat": attributes["dsAttrTypeStandard:UniqueID"] = ["0501"]
        case "systemUID": attributes["dsAttrTypeStandard:UniqueID"] = ["0"]
        case "guid": attributes["dsAttrTypeStandard:GeneratedUID"] = ["invalid"]
        case "home": attributes["dsAttrTypeStandard:NFSHomeDirectory"] = ["/Users/other"]
        case "missing": attributes.removeValue(forKey: "dsAttrTypeStandard:GeneratedUID")
        case "extra": attributes["other"] = ["value"]
        default: break
        }
        let data = try PropertyListSerialization.data(fromPropertyList: attributes, format: .xml, options: 0)
        return .init(exitCode: mode == "exit" ? 1 : 0, signal: mode == "signal" ? 9 : nil,
            stdout: mode == "malformed" ? Data("invalid".utf8) : data,
            stderr: mode == "stderr" ? Data("error".utf8) : Data(),
            stdoutTruncated: mode == "truncated", stderrTruncated: false, timedOut: mode == "timeout")
    }

    @Test("native owner lookup rejects malformed identity and command failure", arguments: [
        "multiple", "numericType", "scalar", "uidFormat", "systemUID", "guid", "home",
        "missing", "extra", "exit", "signal", "malformed", "stderr", "truncated", "timeout"
    ])
    func rejectsNativeOwner(mode: String) async throws {
        await #expect(throws: PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed) {
            try await PommeBootstrapBuddyPreferences.readOwner { _ in try Self.ownerResult(mode: mode) }
        }
    }

    @Test("restore and sw_vers versions permit omitted zero patch components", arguments: ["27.0", "27.0.0"])
    func equivalentProductVersions(expected: String) async throws {
        let receipt = try await PommeBootstrapBuddyPreferences.wait(productVersion: expected, buildVersion: "26A428", expectedOwner: Self.owner, read: {
            try Self.payload(Self.receipt())
        })
        #expect(receipt.productVersion == "27.0")
    }

    @Test("numeric version normalization rejects different or malformed versions", arguments: ["27.0.1", "27..0", "27.0x"])
    func differentProductVersions(expected: String) async throws {
        await #expect(throws: PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed) {
            try await PommeBootstrapBuddyPreferences.wait(productVersion: expected, buildVersion: "26A428", expectedOwner: Self.owner, read: {
                try Self.payload(Self.receipt())
            })
        }
    }

    @Test("bootstrap waits for the same boot before allowing its next effect")
    func waits() async throws {
        let reads = Mutex(0)
        let clock = Mutex(0.0)
        let result = try await PommeBootstrapBuddyPreferences.wait(productVersion: "27.0", buildVersion: "26A428",
            expectedOwner: Self.owner, read: {
                let count = reads.withLock { $0 += 1; return $0 }
                if count == 1 { return .object(["initializing": .bool(true)]) }
                var receipt = Self.receipt()
                if count == 2 { receipt.outcome = "running"; receipt.stage = "maintainingBuild" }
                return try Self.payload(receipt)
            }, now: { clock.withLock { $0 } }, sleep: { delay in clock.withLock { $0 += delay } })
        #expect(result == Self.receipt())
        #expect(reads.withLock { $0 } == 3)
        #expect(clock.withLock { $0 } == 4)
    }

    @Test("failed and mismatched receipts stop bootstrap effects", arguments: [
        "failed", "build", "version", "uid", "guid", "account", "home", "boot", "stage", "error", "missingOwner", "changedBoot", "malformed", "unknownOutcome", "null", "invalidInitializing"
    ])
    func rejects(mode: String) async throws {
        let reads = Mutex(0)
        var effectOccurred = false
        do {
            _ = try await PommeBootstrapBuddyPreferences.wait(productVersion: "27.0", buildVersion: "26A428",
                expectedOwner: Self.owner, read: {
                    let count = reads.withLock { $0 += 1; return $0 }
                    if mode == "null" { return .null }
                    if mode == "invalidInitializing" { return .object(["initializing": .bool(true), "extra": .bool(true)]) }
                    if mode == "malformed" { return .object(["outcome": .string("succeeded")]) }
                    var value = Self.receipt()
                    switch mode {
                    case "unknownOutcome": value.outcome = "unexpected"
                    case "failed": value.outcome = "failed"; value.error = .init(code: "write-failed", numericCode: 1)
                    case "build": value.buildVersion = "26A999"
                    case "version": value.productVersion = "26.0"
                    case "uid": value.owner?.uid = 502
                    case "guid": value.owner?.generatedUID = "33333333-3333-3333-3333-333333333333"
                    case "account": value.owner?.account = "other"
                    case "home": value.owner?.homeDirectory = "/Users/other"
                    case "boot": value.bootSessionUUID = "invalid"
                    case "stage": value.stage = "maintainingBuild"
                    case "error": value.error = .init(code: "unexpected", numericCode: nil)
                    case "missingOwner": value.owner = nil
                    case "changedBoot":
                        if count == 1 { value.outcome = "running"; value.stage = "maintainingBuild" }
                        else { value.bootSessionUUID = "44444444-4444-4444-4444-444444444444" }
                    default: break
                    }
                    return try Self.payload(value)
                }, sleep: { _ in })
            effectOccurred = true
        } catch let error as PommeSecurityOwnerPreparationError {
            #expect(error == (mode == "failed" ? .buddyPreferencesFailed : .ownerCompletionVerificationFailed))
        }
        #expect(!effectOccurred)
        #expect(reads.withLock { $0 } == (mode == "changedBoot" ? 2 : 1))
    }

    @Test("waiting stops at the 120 second deadline without another query")
    func timeout() async throws {
        let clock = Mutex(0.0)
        let reads = Mutex(0)
        await #expect(throws: PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed) {
            try await PommeBootstrapBuddyPreferences.wait(productVersion: "27.0", buildVersion: "26A428", expectedOwner: Self.owner, read: {
                reads.withLock { $0 += 1 }
                return .object(["initializing": .bool(true)])
            }, now: { clock.withLock { $0 } }, sleep: { delay in clock.withLock { $0 += delay } })
        }
        #expect(clock.withLock { $0 } == 120)
        #expect(reads.withLock { $0 } == 60)
    }
}
