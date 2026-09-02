import CryptoKit
import Darwin
import Foundation
import Testing

@Suite("Durable VM security state")
struct VMSecurityStateStoreTests {
    @Test("Owner-only state round-trips and clears only after verification")
    func roundTripAndVerifiedClear() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let store = VMSecurityStateStore(bundle: fixture.bundle)
        let snapshot = fixture.snapshot()

        try store.save(snapshot)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.bundle.securityStateURL.path)
        let permissions = try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
        #expect(permissions & 0o777 == 0o600)
        #expect(try store.load(matching: snapshot.identity) == snapshot)
        #expect(throws: VMSecurityStateStoreError.self) {
            try store.clearIfVerifiedComplete(matching: snapshot.identity)
        }
        #expect(throws: VMSecurityStateStoreError.self) {
            try store.advance(snapshot, to: .securityMutationComplete)
        }

        var phaseSnapshot = snapshot
        for phase in [
            VMSecurityStatePhase.preflightComplete,
            .securityMutationStarted,
            .securityMutationComplete,
            .restorationStarted,
            .verifiedComplete
        ] {
            phaseSnapshot = try store.advance(phaseSnapshot, to: phase)
        }
        try store.clearIfVerifiedComplete(matching: snapshot.identity)
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.securityStateURL.path))
    }

    @Test("Initial security capture never replaces an existing state")
    func saveIfAbsentPreservesExistingCapture() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let store = VMSecurityStateStore(bundle: fixture.bundle)
        let first = fixture.snapshot(updatedAt: Date(timeIntervalSince1970: 1_000))
        let second = fixture.snapshot(updatedAt: Date(timeIntervalSince1970: 2_000))

        try store.saveIfAbsent(first)
        #expect(throws: VMSecurityStateStoreError.alreadyExists) {
            try store.saveIfAbsent(second)
        }
        #expect(try store.load(matching: first.identity) == first)
    }

    @Test("Initial capture refuses a dangling state symlink and publishes an owner-only regular file")
    func saveIfAbsentRejectsDanglingSymlinkAndPublishesSafeFile() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let store = VMSecurityStateStore(bundle: fixture.bundle)
        let snapshot = fixture.snapshot()
        let danglingTarget = fixture.root.appendingPathComponent("missing-security-state")

        #expect(symlink(danglingTarget.path, fixture.bundle.securityStateURL.path) == 0)
        #expect(throws: VMSecurityStateStoreError.alreadyExists) {
            try store.saveIfAbsent(snapshot)
        }
        var linkStatus = stat()
        #expect(lstat(fixture.bundle.securityStateURL.path, &linkStatus) == 0)
        #expect(linkStatus.st_mode & S_IFMT == S_IFLNK)

        try FileManager.default.removeItem(at: fixture.bundle.securityStateURL)
        try store.saveIfAbsent(snapshot)
        var stateStatus = stat()
        #expect(lstat(fixture.bundle.securityStateURL.path, &stateStatus) == 0)
        #expect(stateStatus.st_mode & S_IFMT == S_IFREG)
        #expect(stateStatus.st_mode & 0o777 == 0o600)
        #expect(stateStatus.st_uid == geteuid())
        #expect(try store.load(matching: snapshot.identity) == snapshot)
    }

    @Test("Initial capture refuses an existing hardlink and never adds an alias")
    func saveIfAbsentRejectsHardlinkDestination() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("attacker-alias")
        try Data("attacker".utf8).write(to: alias)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: alias.path)
        #expect(link(alias.path, fixture.bundle.securityStateURL.path) == 0)

        var before = stat()
        #expect(lstat(fixture.bundle.securityStateURL.path, &before) == 0)
        #expect(before.st_nlink == 2)
        #expect(throws: VMSecurityStateStoreError.alreadyExists) {
            try VMSecurityStateStore(bundle: fixture.bundle).saveIfAbsent(fixture.snapshot())
        }
        var after = stat()
        #expect(lstat(fixture.bundle.securityStateURL.path, &after) == 0)
        #expect(after.st_nlink == 2)
        #expect(after.st_ino == before.st_ino)
    }

    @Test("Concurrent initial captures publish exactly one single-link destination")
    func concurrentSaveIfAbsentHasOneWinner() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let recorder = SecurityStateRaceRecorder()
        let bundle = fixture.bundle
        let snapshot = fixture.snapshot()

        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                try VMSecurityStateStore(bundle: bundle).saveIfAbsent(snapshot)
                recorder.recordSuccess()
            } catch VMSecurityStateStoreError.alreadyExists {
                recorder.recordAlreadyExists()
            } catch {
                recorder.recordUnexpected()
            }
        }

        #expect(recorder.successes == 1)
        #expect(recorder.alreadyExists == 1)
        #expect(recorder.unexpected == 0)
        var final = stat()
        #expect(lstat(bundle.securityStateURL.path, &final) == 0)
        #expect(final.st_mode & S_IFMT == S_IFREG)
        #expect(final.st_nlink == 1)
        #expect(final.st_uid == geteuid())
        #expect(final.st_mode & 0o777 == 0o600)
    }

    @Test("Post-publication failure remains a failure and cannot leave a hardlink alias")
    func postPublicationFailureFailsClosedWithoutAlias() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let store = VMSecurityStateStore(
            bundle: fixture.bundle,
            createIfAbsent: { data, destination in
                try data.write(to: destination, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                throw CocoaError(.fileWriteUnknown)
            }
        )
        #expect(throws: VMSecurityStateStoreError.self) {
            try store.saveIfAbsent(fixture.snapshot())
        }
        var final = stat()
        #expect(lstat(fixture.bundle.securityStateURL.path, &final) == 0)
        #expect(final.st_mode & S_IFMT == S_IFREG)
        #expect(final.st_nlink == 1)
        #expect(final.st_uid == geteuid())
        #expect(final.st_mode & 0o777 == 0o600)
    }

    @Test("Presence checks are strict and restoration age cannot be refreshed by phase changes")
    func presenceAndRestorationFreshness() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let store = VMSecurityStateStore(bundle: fixture.bundle)
        let captured = fixture.snapshot(updatedAt: Date(timeIntervalSince1970: 1_000))

        #expect(try !store.hasState())
        try store.save(captured)
        #expect(try store.hasState())

        let restoration = try store.advanceThrough(
            captured,
            to: .restorationStarted,
            at: Date(timeIntervalSince1970: 10_000)
        )
        #expect(restoration.phase == .restorationStarted)
        #expect(restoration.createdAt == captured.createdAt)
        #expect(restoration.updatedAt == Date(timeIntervalSince1970: 10_000))
        #expect(throws: VMSecurityStateStoreError.stale) {
            try store.load(maximumAge: 100, now: Date(timeIntervalSince1970: 10_001))
        }
    }

    @Test("Malformed, mismatched, stale, and insecure state fails closed")
    func rejectsUnsafeState() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let store = VMSecurityStateStore(bundle: fixture.bundle)
        let snapshot = fixture.snapshot(updatedAt: Date(timeIntervalSince1970: 10))
        try store.save(snapshot)

        #expect(throws: VMSecurityStateStoreError.self) {
            try store.load(matching: fixture.otherIdentity())
        }
        #expect(throws: VMSecurityStateStoreError.self) {
            try store.load(matching: snapshot.identity, maximumAge: 1, now: Date(timeIntervalSince1970: 100))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.bundle.securityStateURL.path)
        #expect(throws: VMSecurityStateStoreError.self) {
            try store.load(matching: snapshot.identity)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.bundle.securityStateURL.path)
        let wrongOwnerStore = VMSecurityStateStore(
            bundle: fixture.bundle,
            readAttributes: { path in
                var attributes = try FileManager.default.attributesOfItem(atPath: path)
                attributes[.ownerAccountID] = NSNumber(value: 0)
                return attributes
            }
        )
        #expect(throws: VMSecurityStateStoreError.self) {
            try wrongOwnerStore.load(matching: snapshot.identity)
        }
        try Data("not-json".utf8).write(to: fixture.bundle.securityStateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.bundle.securityStateURL.path)
        #expect(throws: VMSecurityStateStoreError.self) {
            try store.load(matching: snapshot.identity)
        }
    }

    @Test("Write injection does not leave a success state")
    func writeFailureIsReported() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let baselineStore = VMSecurityStateStore(bundle: fixture.bundle)
        let baseline = fixture.snapshot()
        try baselineStore.save(baseline)
        let store = VMSecurityStateStore(bundle: fixture.bundle, writeAtomically: { _, _ in
            throw CocoaError(.fileWriteUnknown)
        })
        #expect(throws: VMSecurityStateStoreError.self) {
            try store.save(fixture.snapshot())
        }
        #expect(try baselineStore.load(matching: baseline.identity) == baseline)
    }

    @Test("Reconstructible policy snapshots reject unknown or missing flags")
    func rejectsUnknownPolicyFlags() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let invalid = VMSecurityStateSnapshot(
            identity: fixture.identity(),
            policyMode: .exactSnapshot,
            reconstructible: true,
            bootPolicyFlags: ["allowsCustomBootArguments": true],
            bootPolicyPlatformVersion: "1",
            bootArgumentsPresent: false,
            bootArgumentsValue: nil,
            preflightDigest: String(repeating: "a", count: 64)
        )
        #expect(throws: VMSecurityStateStoreError.self) {
            try VMSecurityStateStore(bundle: fixture.bundle).save(invalid)
        }
    }

    @Test("Exact guest preflight binds host identity and rejects altered data")
    func strictGuestPreflight() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        try fixture.prepareIdentityFiles()
        let payload = fixture.preflightPayload()

        let snapshot = try VMSecurityStatePreflight.snapshot(
            guestPayload: payload,
            bundle: fixture.bundle,
            capturedAt: Date(timeIntervalSince1970: 2_000.75)
        )
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 2_000))
        #expect(snapshot.identity.vmUUID == "11111111-2222-3333-4444-555555555555")
        #expect(snapshot.identity.buildVersion == "24A123")
        #expect(snapshot.identity.volumeGroupUUID == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        #expect(snapshot.identity.volumeVUID == "ABC-123")
        #expect(snapshot.bootArgumentsValue == "keepsyms=1")
        #expect(snapshot.preflightDigest == payload["digest"] as? String)
        let store = VMSecurityStateStore(bundle: fixture.bundle)
        try store.save(snapshot)
        #expect(try store.load(matching: snapshot.identity) == snapshot)

        var altered = payload
        altered["bootArguments"] = "debug=1"
        #expect(throws: VMSecurityStateStoreError.self) {
            try VMSecurityStatePreflight.snapshot(guestPayload: altered, bundle: fixture.bundle)
        }
        altered = payload
        altered["unexpected"] = true
        #expect(throws: VMSecurityStateStoreError.self) {
            try VMSecurityStatePreflight.snapshot(guestPayload: altered, bundle: fixture.bundle)
        }
    }

    @Test("Exact restoration evidence is phase-stable, identity-bound, and non-secret")
    func exactRestorationEvidence() throws {
        let fixture = try SecurityStateFixture()
        defer { fixture.remove() }
        let snapshot = fixture.exactSnapshot()

        let captured = try snapshot.exactRestorationEvidence()
        let advanced = try snapshot.advancing(to: .preflightComplete, at: Date(timeIntervalSince1970: 2_000))
        let afterPhaseAdvance = try advanced.exactRestorationEvidence()
        #expect(captured == afterPhaseAdvance)

        let payload = captured.payload(snapshotConsumed: true)
        #expect(payload["snapshotSHA256"] as? String == captured.snapshotSHA256)
        #expect(captured.snapshotSHA256.count == 64)
        #expect(payload["vmUUID"] as? String == snapshot.identity.vmUUID)
        #expect(payload["buildVersion"] as? String == snapshot.identity.buildVersion)
        #expect(payload["policyRestorationMode"] as? String == "exactSnapshot")
        #expect(payload["verified"] as? Bool == true)
        #expect(payload["snapshotConsumed"] as? Bool == true)
        #expect(payload["bootArgumentsSHA256"] as? String == captured.bootArgumentsSHA256)
        #expect(captured.bootArgumentsSHA256.count == 64)
        #expect(payload["bootArguments"] == nil)
        #expect(payload["volumeGroupUUID"] == nil)
        #expect(payload["volumeVUID"] == nil)

        var changedFlags = snapshot.bootPolicyFlags
        changedFlags["allowsKexts"] = true
        let changed = VMSecurityStateSnapshot(
            identity: snapshot.identity,
            policyMode: .exactSnapshot,
            reconstructible: true,
            bootPolicyFlags: changedFlags,
            securityMode: "reduced",
            bootPolicyPlatformVersion: snapshot.bootPolicyPlatformVersion,
            bootArgumentsPresent: snapshot.bootArgumentsPresent,
            bootArgumentsValue: snapshot.bootArgumentsValue,
            preflightDigest: fixture.exactPreflightDigest(
                securityMode: "reduced",
                flags: changedFlags
            ),
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
        #expect(try changed.exactRestorationEvidence() != captured)

        #expect(throws: VMSecurityStateStoreError.malformed) {
            try fixture.snapshot().exactRestorationEvidence()
        }
    }
}

private final class SecurityStateFixture {
    let root: URL
    let bundle: BundleLayout

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-security-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bundle = BundleLayout(rootURL: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func snapshot(updatedAt: Date = Date(timeIntervalSince1970: 1_000)) -> VMSecurityStateSnapshot {
        .init(
            identity: identity(),
            policyMode: .restoreOriginal,
            reconstructible: true,
            bootPolicyFlags: [
                "allowsCustomBootArguments": false,
                "allowsMDM": false,
                "allowsKexts": false,
                "kernelCTRRDisabled": false,
                "ssvDisabled": false
            ],
            securityMode: "full",
            bootPolicyPlatformVersion: "1",
            bootArgumentsPresent: true,
            bootArgumentsValue: "amfi_get_out_of_my_way=1",
            preflightDigest: preflightDigest(
                volumeGroupUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                vuid: "volume-vuid",
                securityMode: "full",
                flags: [
                    "allowsMDM": false,
                    "allowsKexts": false,
                    "kernelCTRRDisabled": false,
                    "allowsCustomBootArguments": false,
                    "ssvDisabled": false
                ],
                platformVersion: "1",
                bootArgumentsPresent: true,
                bootArguments: "amfi_get_out_of_my_way=1"
            ),
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    func exactSnapshot() -> VMSecurityStateSnapshot {
        let flags: [String: Bool] = [
            "allowsCustomBootArguments": false,
            "allowsMDM": true,
            "allowsKexts": false,
            "kernelCTRRDisabled": false,
            "ssvDisabled": false
        ]
        return .init(
            identity: identity(),
            policyMode: .exactSnapshot,
            reconstructible: true,
            bootPolicyFlags: flags,
            securityMode: "reduced",
            bootPolicyPlatformVersion: "1",
            bootArgumentsPresent: true,
            bootArgumentsValue: "amfi_get_out_of_my_way=1",
            preflightDigest: preflightDigest(
                volumeGroupUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                vuid: "volume-vuid",
                securityMode: "reduced",
                flags: flags,
                platformVersion: "1",
                bootArgumentsPresent: true,
                bootArguments: "amfi_get_out_of_my_way=1"
            ),
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    func exactPreflightDigest(securityMode: String, flags: [String: Bool]) -> String {
        preflightDigest(
            volumeGroupUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            vuid: "volume-vuid",
            securityMode: securityMode,
            flags: flags,
            platformVersion: "1",
            bootArgumentsPresent: true,
            bootArguments: "amfi_get_out_of_my_way=1"
        )
    }

    func identity() -> VMSecurityStateIdentity {
        .init(
            vmUUID: "11111111-2222-3333-4444-555555555555",
            machineIdentifierSHA256: String(repeating: "a", count: 64),
            diskImageFileResourceID: "disk-file-resource-id",
            buildVersion: "24A123",
            volumeGroupUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            volumeVUID: "volume-vuid"
        )
    }

    func otherIdentity() -> VMSecurityStateIdentity {
        .init(
            vmUUID: "99999999-2222-3333-4444-555555555555",
            machineIdentifierSHA256: String(repeating: "a", count: 64),
            diskImageFileResourceID: "disk-file-resource-id",
            buildVersion: "24A123",
            volumeGroupUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            volumeVUID: "volume-vuid"
        )
    }

    func prepareIdentityFiles() throws {
        try Data("machine-id".utf8).write(to: bundle.machineIdentifierURL)
        #expect(FileManager.default.createFile(atPath: bundle.diskImageURL.path, contents: Data()))
        let metadata: [String: Any] = [
            Constants.vmUUIDMetadataKey: "11111111-2222-3333-4444-555555555555",
            "buildVersion": "24A123"
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: bundle.metadataURL)
    }

    func preflightPayload() -> [String: Any] {
        let flags: [String: Bool] = [
            "allowsMDM": true,
            "allowsKexts": false,
            "kernelCTRRDisabled": false,
            "allowsCustomBootArguments": false,
            "ssvDisabled": false
        ]
        let digest = preflightDigest(
            volumeGroupUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            vuid: "ABC-123",
            securityMode: "reduced",
            flags: flags,
            platformVersion: "26.5.2",
            bootArgumentsPresent: true,
            bootArguments: "keepsyms=1"
        )
        var flagsPayload = flags.reduce(into: [String: Any]()) { result, entry in
            result[entry.key] = entry.value
        }
        flagsPayload["securityMode"] = "reduced"
        return [
            "volumeGroupUUID": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "vuid": "ABC-123",
            "platformVersion": "26.5.2",
            "bootPolicyFlags": flagsPayload,
            "bootArgumentsPresent": true,
            "bootArguments": "keepsyms=1",
            "digest": digest
        ]
    }
}

private final class SecurityStateRaceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSuccesses = 0
    private var storedAlreadyExists = 0
    private var storedUnexpected = 0

    var successes: Int { lock.withLock { storedSuccesses } }
    var alreadyExists: Int { lock.withLock { storedAlreadyExists } }
    var unexpected: Int { lock.withLock { storedUnexpected } }

    func recordSuccess() { lock.withLock { storedSuccesses += 1 } }
    func recordAlreadyExists() { lock.withLock { storedAlreadyExists += 1 } }
    func recordUnexpected() { lock.withLock { storedUnexpected += 1 } }
}

private func preflightDigest(
    volumeGroupUUID: String,
    vuid: String,
    securityMode: String,
    flags: [String: Bool],
    platformVersion: String,
    bootArgumentsPresent: Bool,
    bootArguments: String
) -> String {
    let text = [
        volumeGroupUUID,
        vuid,
        securityMode,
        flags["allowsMDM"]! ? "1" : "0",
        flags["allowsKexts"]! ? "1" : "0",
        flags["kernelCTRRDisabled"]! ? "1" : "0",
        flags["allowsCustomBootArguments"]! ? "1" : "0",
        flags["ssvDisabled"]! ? "1" : "0",
        platformVersion,
        bootArgumentsPresent ? "1" : "0",
        bootArguments
    ].joined(separator: "\u{1F}")
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
