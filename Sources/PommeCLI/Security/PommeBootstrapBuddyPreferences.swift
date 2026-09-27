import Foundation

/// Prevents bootstrap cleanup and reboot from passing an incomplete guest attempt.
/// The caller supplies an authenticated status query; this helper never starts writes.
enum PommeBootstrapBuddyPreferences {
    static func readOwner(
        execute: @Sendable (GuestCommandRequest) async throws -> GuestCommandResult
    ) async throws -> PommeBuddyPreferencesOwner {
        let invalid = PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
        let result = try await execute(.init(path: "/usr/bin/dscl", arguments: [
            "-plist", "/Local/Default", "-read", "/Users/pomme",
            "RecordName", "UniqueID", "GeneratedUID", "NFSHomeDirectory"
        ], timeout: 15))
        guard result.exited, !result.detached, result.exitCode == 0, result.signal == nil,
              !result.timedOut, !result.stdoutTruncated, !result.stderrTruncated,
              result.stderr.isEmpty, !result.stdout.isEmpty, result.stdout.count <= 16_384,
              let values = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              Set(values.keys) == Set(["RecordName", "UniqueID", "GeneratedUID", "NFSHomeDirectory"].map { "dsAttrTypeStandard:" + $0 })
        else { throw invalid }
        func value(_ key: String) throws -> String {
            guard let strings = values["dsAttrTypeStandard:" + key] as? [String],
                  strings.count == 1, !strings[0].isEmpty else { throw invalid }
            return strings[0]
        }
        let uidText = try value("UniqueID")
        guard let uid = UInt32(uidText), String(uid) == uidText else { throw invalid }
        let owner = try PommeBuddyPreferencesOwner(account: value("RecordName"), uid: uid,
            generatedUID: value("GeneratedUID"), homeDirectory: value("NFSHomeDirectory"))
        do { try owner.validate() } catch { throw invalid }
        return owner
    }

    /// Restore metadata may include a zero patch component omitted by sw_vers.
    private static func sameProductVersion(_ actual: String?, _ expected: String) -> Bool {
        func components(_ value: String) -> [UInt]? {
            let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
            guard (2...3).contains(pieces.count),
                  pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return nil }
            var numbers = pieces.compactMap { UInt($0) }
            guard numbers.count == pieces.count else { return nil }
            while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
            return numbers
        }
        guard let actual, let actualComponents = components(actual),
              let expectedComponents = components(expected) else { return false }
        return actualComponents == expectedComponents
    }

    @discardableResult
    static func wait(
        productVersion: String,
        buildVersion: String,
        expectedOwner: PommeBuddyPreferencesOwner,
        read: @Sendable () async throws -> JSONValue,
        now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) async throws -> PommeBuddyPreferencesStatus {
        let invalid = PommeSecurityOwnerPreparationError.ownerCompletionVerificationFailed
        do { try expectedOwner.validate() } catch { throw invalid }
        let deadline = now() + 120
        var boot: UUID?
        for _ in 0..<61 {
            try Task.checkCancellation()
            guard now() < deadline else { throw invalid }
            let payload = try await read()
            guard now() < deadline else { throw invalid }
            if payload != .object(["initializing": .bool(true)]) {
                let receipt: PommeBuddyPreferencesStatus
                do {
                    receipt = try JSONDecoder().decode(PommeBuddyPreferencesStatus.self,
                        from: JSONEncoder().encode(payload))
                } catch { throw invalid }
                guard let receiptBoot = UUID(uuidString: receipt.bootSessionUUID),
                      boot == nil || boot == receiptBoot,
                      receipt.productVersion == nil || sameProductVersion(receipt.productVersion, productVersion),
                      receipt.buildVersion == nil || receipt.buildVersion == buildVersion else { throw invalid }
                boot = receiptBoot
                if let owner = receipt.owner {
                    do { try owner.validate() } catch { throw invalid }
                    guard owner.account == expectedOwner.account, owner.uid == expectedOwner.uid,
                          owner.homeDirectory == expectedOwner.homeDirectory,
                          UUID(uuidString: owner.generatedUID) == UUID(uuidString: expectedOwner.generatedUID)
                    else { throw invalid }
                }
                guard receipt.outcome == "failed" || receipt.error == nil else { throw invalid }
                switch (receipt.outcome, receipt.stage) {
                case ("failed", _):
                    throw PommeSecurityOwnerPreparationError.buddyPreferencesFailed
                case ("succeeded", "complete"):
                    guard receipt.owner != nil, sameProductVersion(receipt.productVersion, productVersion),
                          receipt.buildVersion == buildVersion else { throw invalid }
                    return receipt
                case ("waiting", "detectingOS"):
                    guard receipt.owner == nil else { throw invalid }
                case ("waiting", "waitingForOwner"):
                    guard receipt.owner == nil, sameProductVersion(receipt.productVersion, productVersion),
                          receipt.buildVersion == buildVersion else { throw invalid }
                case ("running", "maintainingBuild"), ("running", "maintainingMiniBuddy"):
                    guard receipt.owner != nil, sameProductVersion(receipt.productVersion, productVersion),
                          receipt.buildVersion == buildVersion else { throw invalid }
                default: throw invalid
                }
            }
            let remaining = deadline - now()
            guard remaining > 0 else { throw invalid }
            try await sleep(min(2, remaining))
        }
        throw invalid
    }
}
