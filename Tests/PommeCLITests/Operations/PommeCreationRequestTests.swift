import ArgumentParser
import Foundation
import Testing

@Suite("Shared direct creation request")
struct PommeCreationRequestTests {
    @Test("A template, version, or restore image selects the source")
    func sourceSelection() {
        #expect(PommeCreationRequest.source(version: nil, restoreImage: nil, fromTemplate: "base", ipswDevice: nil)
            == .template("base"))
        #expect(PommeCreationRequest.source(version: "latest", restoreImage: nil, fromTemplate: nil, ipswDevice: "Mac14,3")
            == .version("latest", ipswDevice: "Mac14,3"))
        #expect(PommeCreationRequest.source(version: nil, restoreImage: "/tmp/R.ipsw", fromTemplate: nil, ipswDevice: nil)
            == .restoreImage("/tmp/R.ipsw"))
        #expect(PommeCreationRequest.source(version: nil, restoreImage: nil, fromTemplate: nil, ipswDevice: nil) == nil)
    }

    @Test("Conflicting sources and invalid sizes are rejected", arguments: [
        ("26", nil, "base", nil, "60GB", "8GB"),
        (nil, "/tmp/R.ipsw", "base", nil, "60GB", "8GB"),
        ("26", "/tmp/R.ipsw", nil, nil, "60GB", "8GB"),
        (nil, "  ", nil, nil, "60GB", "8GB"),
        (nil, "/tmp/R.ipsw", nil, "Mac14,3", "60GB", "8GB"),
        (nil, nil, "base", nil, "0GB", "8GB"),
        (nil, nil, "base", nil, "60GB", "lots"),
    ] as [(String?, String?, String?, String?, String, String)])
    func rejectsInvalidOptions(
        version: String?, restoreImage: String?, fromTemplate: String?, ipswDevice: String?,
        diskSize: String, memory: String
    ) {
        #expect(throws: ValidationError.self) {
            try PommeCreationRequest.validate(version: version, restoreImage: restoreImage,
                fromTemplate: fromTemplate, ipswDevice: ipswDevice, diskSize: diskSize, memory: memory)
        }
    }

    @Test("Valid single sources pass validation")
    func acceptsValidOptions() throws {
        try PommeCreationRequest.validate(version: nil, restoreImage: nil, fromTemplate: "base", ipswDevice: nil,
                                          diskSize: "40GB", memory: "4GB")
        try PommeCreationRequest.validate(version: "latest", restoreImage: nil, fromTemplate: nil, ipswDevice: nil,
                                          diskSize: PommeCreationRequest.defaultDiskSize,
                                          memory: PommeCreationRequest.defaultMemory)
    }
}
