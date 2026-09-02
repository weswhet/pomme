import Testing

@Suite("Pomme restore-image discovery")
struct PommeRestoreImageTests {
    @Test("Only a missing trailing zero patch is equivalent")
    func versionMatching() {
        #expect(PommeCore.ipswVersionMatches("26.6", catalogVersion: "26.6.0"))
        #expect(PommeCore.ipswVersionMatches("26.6.0", catalogVersion: "26.6"))
        #expect(PommeCore.ipswVersionMatches(" 26.6 ", catalogVersion: "26.6.0"))
        #expect(PommeCore.ipswVersionMatches("26.6.0", catalogVersion: "26.6.0"))

        for (requested, catalog) in [
            ("26.6.1", "26.6.0"),
            ("26.7", "26.6.0"),
            ("26.6.0.0", "26.6.0"),
            ("26.06", "26.6.0"),
            ("26.6", "26.6.1"),
            ("15.6", "26.6.0")
        ] {
            #expect(!PommeCore.ipswVersionMatches(requested, catalogVersion: catalog))
        }
    }

    @Test("Catalog selection never returns unsigned firmware")
    func signedSelectionOnly() throws {
        let unsignedLatest = firmware(version: "26.6.0", build: "25G72", signed: false)
        let signedOlder = firmware(version: "26.5.0", build: "25F90", signed: true)
        let signedTarget = firmware(version: "26.6.0", build: "25G72", signed: true)

        #expect(throws: RunnerError.self) {
            _ = try PommeCore.selectIPSWFirmware([unsignedLatest], selection: "latest")
        }
        #expect(try PommeCore.selectIPSWFirmware([unsignedLatest, signedOlder], selection: "latest").identifier == signedOlder.identifier)
        #expect(try PommeCore.selectIPSWFirmware([unsignedLatest, signedTarget], selection: "26.6").identifier == signedTarget.identifier)
        #expect(throws: RunnerError.self) {
            _ = try PommeCore.selectIPSWFirmware([unsignedLatest], selection: "26.6.0")
        }
    }

    @Test("Download response decisions distinguish fresh and resumed responses")
    func responseDecisions() throws {
        #expect(try PommeCore.ipswDownloadResponseDecision(
            statusCode: 200,
            requestedOffset: 0,
            contentRange: nil,
            expectedSize: 100
        ) == .overwrite)
        #expect(try PommeCore.ipswDownloadResponseDecision(
            statusCode: 200,
            requestedOffset: 40,
            contentRange: nil,
            expectedSize: 100
        ) == .overwrite)
        #expect(try PommeCore.ipswDownloadResponseDecision(
            statusCode: 206,
            requestedOffset: 40,
            contentRange: "bytes 40-99/100",
            expectedSize: 100
        ) == .append)

        #expect(throws: PommeCore.IPSWDownloadResponseError.self) {
            _ = try PommeCore.ipswDownloadResponseDecision(
                statusCode: 206,
                requestedOffset: 0,
                contentRange: "bytes 0-99/100",
                expectedSize: 100
            )
        }
        #expect(throws: PommeCore.IPSWDownloadResponseError.self) {
            _ = try PommeCore.ipswDownloadResponseDecision(
                statusCode: 206,
                requestedOffset: 40,
                contentRange: "bytes 0-99/100",
                expectedSize: 100
            )
        }
        #expect(throws: PommeCore.IPSWDownloadResponseError.self) {
            _ = try PommeCore.ipswDownloadResponseDecision(
                statusCode: 206,
                requestedOffset: 40,
                contentRange: "bytes 40-99/101",
                expectedSize: 100
            )
        }
    }
}

private func firmware(version: String, build: String, signed: Bool?) -> IPSWMEFirmware {
    IPSWMEFirmware(
        identifier: "VirtualMac2,1",
        version: version,
        buildid: build,
        filesize: 100,
        url: "https://example.invalid/restore.ipsw",
        releasedate: nil,
        uploaddate: nil,
        signed: signed,
        sha1sum: nil,
        md5sum: nil,
        sha256sum: nil
    )
}
