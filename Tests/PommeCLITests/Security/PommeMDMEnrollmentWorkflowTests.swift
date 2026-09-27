import Foundation
import Testing

@Suite("Durable MDM enrollment journal")
struct PommeMDMEnrollmentWorkflowTests {
    @Test("An intent journal binds security only after its initial durable write and reloads without staleness")
    func durableBaselineBinding() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let first = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .unapproved, originalRunState: .paused(previousBootMode: .recovery),
            sipWasDisabled: nil, amfiWasDisabled: nil, ownedArtifacts: [], lease: fixture.lease,
            now: fixture.date
        )
        #expect(first.sipWasDisabled == nil)
        let bound = try fixture.store.bindSecurityBaseline(
            first, sipWasDisabled: false, amfiWasDisabled: false, lease: fixture.lease,
            now: fixture.date.addingTimeInterval(1)
        )
        #expect(try fixture.store.loadIfPresent(lease: fixture.lease) == bound)
        let checked = try fixture.store.advance(
            bound, to: .existingEnrollmentChecked, lease: fixture.lease,
            now: fixture.date.addingTimeInterval(2)
        )
        #expect(checked.generation == bound.generation + 1)
    }

    @Test("Schema 4 remains readable without inventing clean retry evidence")
    func schema4PreservesBindings() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initial = try fixture.store.begin(identity: fixture.identity, profile: fixture.profile,
            agentSHA256: fixture.digest, enrollmentMode: .supervised, originalRunState: .stopped,
            ownedArtifacts: [], lease: fixture.lease)
        var object = try fixture.onDiskObject()
        object["schema"] = 4
        object.removeValue(forKey: "failure")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: fixture.store.journalURL)
        let loaded = try #require(try fixture.store.loadIfPresent(lease: fixture.lease))
        #expect(loaded.agentSHA256 == initial.agentSHA256)
        #expect(loaded.profile == initial.profile)
        #expect(loaded.failure == nil)
        #expect(!loaded.canRetryEnrollment)
        let failed = try fixture.store.update(loaded, failure: .beforeDispatch, lease: fixture.lease)
        #expect(try fixture.store.loadIfPresent(lease: fixture.lease) == failed)
        #expect(failed.phase == initial.phase)
        #expect(failed.failure == .beforeDispatch)
    }

    @Test("An explicit restoration failure survives verified enrollment")
    func restorationFailureIsDurable() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initial = try fixture.store.begin(identity: fixture.identity, profile: fixture.profile,
            agentSHA256: fixture.digest, enrollmentMode: .supervised, originalRunState: .stopped,
            ownedArtifacts: [], lease: fixture.lease)
        let verified = try fixture.store.update(initial, enrollmentVerified: true, lease: fixture.lease)
        let failed = try fixture.store.update(verified, enrollmentVerified: true,
            failure: .restoration, lease: fixture.lease)
        #expect(failed.enrollmentVerified)
        #expect(failed.failure == .restoration)
        #expect(try fixture.store.loadIfPresent(lease: fixture.lease) == failed)
    }

    @Test("An unfinished operation rejects mode changes, while a completed one permits a new mode")
    func modeInterlockAndTerminalUpgrade() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initial = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .unapproved, originalRunState: .stopped,
            sipWasDisabled: nil, amfiWasDisabled: nil, ownedArtifacts: [], lease: fixture.lease,
            now: fixture.date
        )
        #expect(throws: PommeMDMEnrollmentWorkflowError.self) {
            _ = try fixture.store.begin(
                identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
                enrollmentMode: .supervised, originalRunState: .stopped,
                sipWasDisabled: nil, amfiWasDisabled: nil, ownedArtifacts: [], lease: fixture.lease
            )
        }
        let bound = try fixture.store.bindSecurityBaseline(
            initial, sipWasDisabled: true, amfiWasDisabled: true, lease: fixture.lease
        )
        let checked = try fixture.store.advance(bound, to: .existingEnrollmentChecked, lease: fixture.lease)
        let restoring = try fixture.store.advance(checked, to: .securityRestorationIntent, lease: fixture.lease)
        let restored = try fixture.store.advance(restoring, to: .securityRestored, lease: fixture.lease)
        let run = try fixture.store.advance(restored, to: .runStateRestorationIntent, lease: fixture.lease)
        _ = try fixture.store.advance(run, to: .restorationComplete, lease: fixture.lease)
        let upgraded = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .supervised, originalRunState: .stopped,
            sipWasDisabled: nil, amfiWasDisabled: nil, ownedArtifacts: [], lease: fixture.lease
        )
        #expect(upgraded.enrollmentMode == .supervised)
    }

    @Test("No-op evidence may be verified without a helper dispatch")
    func verifiedNoOpDoesNotRequireDispatch() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initial = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .supervised, originalRunState: .stopped, ownedArtifacts: [], lease: fixture.lease
        )
        let checked = try fixture.store.update(
            initial, phase: .existingEnrollmentChecked, lease: fixture.lease
        )
        let verified = try fixture.store.update(
            checked, phase: .postEnrollmentEvidenceVerified, enrollmentVerified: true,
            lease: fixture.lease
        )
        #expect(verified.enrollmentVerified)
        #expect(!verified.enrollmentDispatched)
    }

    @Test("A restored lost helper reply may reopen without retaining a child marker")
    func restoredLostDispatchMayReopenForObservedUpgrade() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initial = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .supervised, originalRunState: .stopped, ownedArtifacts: [], lease: fixture.lease
        )
        let bound = try fixture.store.bindSecurityBaseline(
            initial, sipWasDisabled: false, amfiWasDisabled: false, lease: fixture.lease
        )
        let checked = try fixture.store.update(bound, phase: .existingEnrollmentChecked, lease: fixture.lease)
        let preparing = try fixture.store.update(checked, phase: .securityPreparationIntent, lease: fixture.lease)
        let prepared = try fixture.store.update(preparing, phase: .securityPrepared, lease: fixture.lease)
        let dispatched = try fixture.store.update(
            prepared, phase: .enrollmentIntent, enrollmentDispatched: true, lease: fixture.lease
        )
        let restoration = try fixture.store.update(
            dispatched, phase: .securityRestorationIntent, pendingChild: .some(nil), lease: fixture.lease
        )
        let restored = try fixture.store.update(restoration, phase: .securityRestored, lease: fixture.lease)
        let runState = try fixture.store.update(restored, phase: .runStateRestorationIntent, lease: fixture.lease)
        let terminal = try fixture.store.update(runState, phase: .restorationComplete, lease: fixture.lease)
        #expect(terminal.pendingChild == nil)
        let restartIntent = try fixture.store.update(
            terminal, phase: .runStateRestorationIntent, lease: fixture.lease
        )
        let reopened = try fixture.store.update(
            restartIntent, phase: .securityPreparationIntent, lease: fixture.lease
        )
        #expect(reopened.phase == .securityPreparationIntent)
    }

    @Test("Configured boot arguments are a canonical immutable companion to active arguments")
    func configuredBootArgumentsRoundTripAndRemainImmutable() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initial = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .supervised, originalRunState: .stopped, ownedArtifacts: [], lease: fixture.lease
        )
        let configured = try PommeProvisioningCoding.encode(JSONValue.null)
        let captured = try fixture.store.update(
            initial, normalBootArguments: Data(), configuredBootArguments: configured, lease: fixture.lease
        )
        #expect(captured.configuredBootArguments == configured)
        #expect(try fixture.store.loadIfPresent(lease: fixture.lease) == captured)
        #expect(throws: PommeMDMEnrollmentWorkflowError.self) {
            _ = try fixture.store.update(
                captured, normalBootArguments: Data("changed".utf8),
                configuredBootArguments: configured, lease: fixture.lease
            )
        }
    }

    @Test("Profile staging ownership is durable and cannot be cleared")
    func stagedProfileOwnershipIsSticky() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initial = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .supervised, originalRunState: .stopped, ownedArtifacts: [], lease: fixture.lease
        )
        let owned = try fixture.store.update(initial, stagedProfileOwned: true, lease: fixture.lease)
        #expect(owned.stagedProfileOwned)
        #expect(try fixture.store.loadIfPresent(lease: fixture.lease) == owned)
        #expect(throws: PommeMDMEnrollmentWorkflowError.self) {
            _ = try fixture.store.update(owned, stagedProfileOwned: false, lease: fixture.lease)
        }
    }

    @Test("A completed schema 3 journal upgrades as clean schema 4 state")
    func terminalSchema3MapsToUnownedSchema4() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let terminal = try fixture.terminalJournal()
        try fixture.replaceOnDiskWithSchema3(terminal)

        let migrated = try #require(try fixture.store.loadIfPresent(lease: fixture.lease))
        #expect(migrated.schema == PommeMDMEnrollmentJournal.schemaVersion)
        #expect(migrated.phase == .restorationComplete)
        #expect(!migrated.stagedProfileOwned)
        let next = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .supervised, originalRunState: .stopped, ownedArtifacts: [], lease: fixture.lease
        )
        #expect(next.schema == PommeMDMEnrollmentJournal.schemaVersion)
    }

    @Test("An unfinished schema 3 journal is rejected without migration")
    func unfinishedSchema3IsNotRewritten() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initial = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .unapproved, originalRunState: .stopped, ownedArtifacts: [], lease: fixture.lease
        )
        let bound = try fixture.store.bindSecurityBaseline(
            initial, sipWasDisabled: false, amfiWasDisabled: false, lease: fixture.lease
        )
        let checked = try fixture.store.update(bound, phase: .existingEnrollmentChecked, lease: fixture.lease)
        let preparing = try fixture.store.update(
            checked, phase: .securityPreparationIntent, lease: fixture.lease
        )
        let prepared = try fixture.store.update(preparing, phase: .securityPrepared, lease: fixture.lease)
        let incomplete = try fixture.store.update(prepared, phase: .enrollmentIntent, lease: fixture.lease)
        try fixture.replaceOnDiskWithSchema3(incomplete)

        #expect(throws: PommeMDMEnrollmentWorkflowError.self) {
            _ = try fixture.store.loadIfPresent(lease: fixture.lease)
        }
        #expect(try fixture.onDiskSchema() == 3)
        #expect(try fixture.onDiskObject()["stagedProfileOwned"] == nil)
    }

    @Test("A pre-transfer schema 3 journal resumes as an unowned schema 4 journal")
    func preTransferSchema3MayResume() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let initial = try fixture.store.begin(
            identity: fixture.identity, profile: fixture.profile, agentSHA256: fixture.digest,
            enrollmentMode: .unapproved, originalRunState: .stopped, ownedArtifacts: [], lease: fixture.lease
        )
        let bound = try fixture.store.bindSecurityBaseline(
            initial, sipWasDisabled: false, amfiWasDisabled: false, lease: fixture.lease
        )
        let checked = try fixture.store.update(bound, phase: .existingEnrollmentChecked, lease: fixture.lease)
        let preparing = try fixture.store.update(
            checked, phase: .securityPreparationIntent, lease: fixture.lease
        )
        try fixture.replaceOnDiskWithSchema3(preparing)

        let resumed = try #require(try fixture.store.loadIfPresent(lease: fixture.lease))
        #expect(resumed.phase == .securityPreparationIntent)
        #expect(!resumed.enrollmentDispatched)
        #expect(!resumed.stagedProfileOwned)
        let advanced = try fixture.store.update(resumed, phase: .securityPrepared, lease: fixture.lease)
        #expect(advanced.schema == PommeMDMEnrollmentJournal.schemaVersion)
    }

    private struct Fixture {
        let directory: URL
        let store: PommeMDMEnrollmentJournalStore
        let lease: VMBundleMutationLease
        let identity: PommeSecurityWorkflowIdentity
        let profile: MDMEnrollmentProfileIdentity
        let digest = String(repeating: "a", count: 64)
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)

        static func make() throws -> Self {
            let name = "mdmjournal-\(UUID().uuidString.prefix(8).lowercased())"
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pomme-mdm-journal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let lease = try VMBundleMutationLease.acquire(name: name)
            let identity = try PommeSecurityWorkflowIdentity(
                vmName: name, vmUUID: UUID(), machineIdentifierSHA256: String(repeating: "b", count: 64),
                diskImageFileResourceID: "1:2", startupVolumeGroupUUID: UUID(),
                immutableProvisioningPlanDigest: String(repeating: "c", count: 64)
            )
            let profile = MDMEnrollmentProfileIdentity(
                identifier: "com.example.mdm", uuid: UUID(), serverURL: "https://mdm.example.test",
                digest: String(repeating: "d", count: 64)
            )
            return .init(directory: directory, store: .init(bundleURL: directory), lease: lease,
                         identity: identity, profile: profile)
        }

        func remove() {
            lease.release()
            try? FileManager.default.removeItem(at: directory)
        }

        func terminalJournal() throws -> PommeMDMEnrollmentJournal {
            let initial = try store.begin(
                identity: identity, profile: profile, agentSHA256: digest,
                enrollmentMode: .unapproved, originalRunState: .stopped, ownedArtifacts: [], lease: lease
            )
            let restoration = try store.update(initial, phase: .securityRestorationIntent, lease: lease)
            let restored = try store.update(restoration, phase: .securityRestored, lease: lease)
            let runState = try store.update(restored, phase: .runStateRestorationIntent, lease: lease)
            return try store.update(runState, phase: .restorationComplete, lease: lease)
        }

        func replaceOnDiskWithSchema3(_ journal: PommeMDMEnrollmentJournal) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(journal)
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["schema"] = 3
            object.removeValue(forKey: "stagedProfileOwned")
            object.removeValue(forKey: "failure")
            let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try legacy.write(to: store.journalURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.journalURL.path)
        }

        func onDiskObject() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.journalURL)) as! [String: Any]
        }

        func onDiskSchema() throws -> Int {
            try #require(onDiskObject()["schema"] as? Int)
        }
    }
}
