import ArgumentParser
import Foundation
import Testing

@Suite("IPSW device identifiers")
struct IPSWDeviceIdentifierTests {
    @Test("Apple model identifiers are accepted", arguments: ["Mac16,10", "VirtualMac2,1", "Macmini9,1", "Bogus1,1"])
    func acceptsModelIdentifiers(value: String) {
        #expect(IPSWDeviceIdentifier.isValid(value))
    }

    @Test("Malformed identifiers are rejected", arguments: ["Bogus", "Mac16", "16,10", "Mac16,", "Mac16,10 ", "../Mac16,10", ""])
    func rejectsMalformedIdentifiers(value: String) {
        #expect(!IPSWDeviceIdentifier.isValid(value))
    }

    @Test("The device options reject a malformed identifier before any request")
    func optionsRejectMalformedIdentifier() {
        let error = #expect(throws: ValidationError.self) {
            try IPSWDeviceIdentifier.validate("Bogus", flag: "--device")
        }
        #expect(error?.message == "--device must be an Apple model identifier such as Mac16,10.")
        #expect(throws: (any Error).self) { try IPSWListCommand.parse(["--device", "Bogus"]) }
        #expect(throws: (any Error).self) { try IPSWDownloadCommand.parse(["latest", "--device", "Bogus"]) }
        #expect(throws: (any Error).self) { try CreateCommand.parse(["vm", "--version", "latest", "--ipsw-device", "Bogus"]) }
    }

    @Test("A 404 from the catalog names the device; other statuses name the catalog")
    func catalogFailureMapping() {
        #expect(PommeCore.catalogFailure(statusCode: 404, identifier: "Bogus1,1").localizedDescription
                == "Unknown device identifier Bogus1,1.")
        #expect(PommeCore.catalogFailure(statusCode: 500, identifier: "Bogus1,1").localizedDescription
                == "The restore-image catalog request failed with HTTP 500.")
    }

    @Test("A config with a malformed ipswDevice is rejected")
    func configRejectsMalformedDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-ipsw-device-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.yaml")
        try Data("schemaVersion: 1\nname: lab\nversions: [latest]\nipswDevice: Bogus\n".utf8).write(to: url)

        let error = #expect(throws: RunnerError.self) { try CreateConfigStore.load(path: url.path) }
        #expect(error?.localizedDescription == "ipswDevice must be an Apple model identifier such as Mac16,10.")
    }
}
