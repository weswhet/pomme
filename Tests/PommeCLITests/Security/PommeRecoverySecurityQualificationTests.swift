import Testing

@Suite("Recovery security profile qualification")
struct PommeRecoverySecurityQualificationTests {
    @Test("Reviewed Tahoe permits Recovery security operations")
    func acceptsReviewedTahoe() throws {
        try PommeRecoverySecurityQualification.require(profile: tahoe)
    }

    @Test("A planner-qualified experimental profile permits Recovery security operations")
    func acceptsQualifiedExperimental() throws {
        try PommeRecoverySecurityQualification.require(profile: experimental)
    }

    @Test("Pending-review builds and experimental evidence with a wrong manifest are rejected")
    func rejectsPendingAndMismatchedProfiles() {
        #expect(throws: PommeRecoverySecurityQualification.Error.unqualifiedRestoreProfile) {
            try PommeRecoverySecurityQualification.require(profile: pending)
        }
        let mismatched = PommeRecoveryProfileEvidence(
            build: .experimental(version: "26.6.2", build: "25G83"),
            locale: .english,
            geometry: .pixels1280x800,
            privateHostABI: .qualifiedRecoveryInputV1,
            manifestHash: .experimentalProfile("profile-digest"),
            ownership: .verified
        )
        #expect(throws: PommeRecoveryInputQualificationError.manifestHashMismatch) {
            try PommeRecoverySecurityQualification.require(profile: mismatched)
        }
    }

    @Test("A reviewed identity still requires exact locale and host evidence")
    func preservesEvidenceRestrictions() {
        let unqualifiedLocale = PommeRecoveryProfileEvidence(
            build: .tahoe2660Build25G72,
            locale: .unknown,
            geometry: .pixels1280x800,
            privateHostABI: .qualifiedRecoveryInputV1,
            manifestHash: .tahoe2660Build25G72,
            ownership: .verified
        )
        #expect(throws: PommeRecoveryInputQualificationError.unsupportedLocale) {
            try PommeRecoverySecurityQualification.require(profile: unqualifiedLocale)
        }
    }

    private var tahoe: PommeRecoveryProfileEvidence {
        .init(
            build: .tahoe2660Build25G72,
            locale: .english,
            geometry: .pixels1280x800,
            privateHostABI: .qualifiedRecoveryInputV1,
            manifestHash: .tahoe2660Build25G72,
            ownership: .verified
        )
    }

    private var experimental: PommeRecoveryProfileEvidence {
        .init(
            build: .experimental(version: "26.6.2", build: "25G83"),
            locale: .english,
            geometry: .pixels1280x800,
            privateHostABI: .qualifiedRecoveryInputV1,
            manifestHash: .experimentalProfile(
                (try? PommeRecoveryProfileSelector.descriptor(version: "26.6.2", build: "25G83").digest) ?? ""
            ),
            ownership: .verified
        )
    }

    private var pending: PommeRecoveryProfileEvidence {
        .init(
            build: .sequoia1561Build24G90,
            locale: .english,
            geometry: .pixels1280x800,
            privateHostABI: .qualifiedRecoveryInputV1,
            manifestHash: .sequoia1561Build24G90,
            ownership: .verified
        )
    }
}
