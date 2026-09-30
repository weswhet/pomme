import Foundation
import Testing

@Suite("IPSW download progress offsets")
struct PommeDownloadProgressTests {
    @Test("Fresh, resumed, and restarted responses use the persisted byte offset")
    func validatedOffsets() throws {
        for (status, offset, range, expected) in [
            (200, Int64(0), Optional<String>.none, Int64(0)),
            (206, Int64(40), Optional("bytes 40-99/100"), Int64(40)),
            (200, Int64(40), Optional<String>.none, Int64(0))
        ] {
            let decision = try PommeCore.ipswDownloadResponseDecision(
                statusCode: status, requestedOffset: offset,
                contentRange: range, expectedSize: 100)
            #expect(PommeCore.ipswDownloadProgressOffset(
                decision: decision, requestedOffset: offset) == expected)
        }
    }

    @Test("An invalid resume response cannot supply a progress offset")
    func rejectsUnvalidatedResume() {
        #expect(throws: PommeCore.IPSWDownloadResponseError.self) {
            let decision = try PommeCore.ipswDownloadResponseDecision(
                statusCode: 206, requestedOffset: 40,
                contentRange: "bytes 20-99/100", expectedSize: 100)
            _ = PommeCore.ipswDownloadProgressOffset(decision: decision, requestedOffset: 40)
        }
    }
}

private final class DownloadOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.lock(); defer { lock.unlock() }; value += text }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

extension PommeDownloadProgressTests {
    @Test("The real byte loop preserves resumed data and resets restarted downloads",
          arguments: ["fresh", "resumed", "restarted", "cached", "complete-partial", "short", "publication"])
    func downloadEvents(scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("restore.ipsw")
        let partial = directory.appendingPathComponent(".restore.ipsw.part")
        let expected = Data([1, 2, 3, 4])
        if scenario == "resumed" || scenario == "restarted" {
            try Data([1, 2]).write(to: partial)
        }
        if scenario == "cached" { try expected.write(to: destination) }
        if scenario == "complete-partial" { try expected.write(to: partial) }
        let output = DownloadOutput()
        let session = PommeProgressSession(mode: .plain, structuredOutput: false, debug: false,
            write: { output.append($0) }, isTerminal: false, startTimer: false, signalCleanup: false)
        let firmware = IPSWMEFirmware(identifier: "VirtualMac2,1", version: "27.0", buildid: "26A428",
            filesize: 4, url: "https://example.invalid/restore.ipsw", releasedate: nil, uploaddate: nil,
            signed: true, sha1sum: nil, md5sum: nil, sha256sum: nil)
        var fetched = false
        var failed = false
        do {
            let result = try await PommeProgressContext.$sink.withValue(session.sink) {
                try await PommeCore.downloadFirmware(firmware, resume: true, vmName: "sample", directory: directory,
                    publish: { partial, destination in
                        if scenario == "publication" { throw CocoaError(.fileWriteUnknown) }
                        try PommeCore.publishDownloadedFirmware(partial, destination)
                    }) { request in
                    fetched = true
                    #expect(scenario != "cached")
                    if scenario == "resumed" || scenario == "restarted" {
                        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=2-")
                    } else { #expect(request.value(forHTTPHeaderField: "Range") == nil) }
                    let values: [UInt8] = scenario == "resumed" ? [3, 4] : scenario == "short" ? [1] : [1, 2, 3, 4]
                    let bytes = AsyncStream<UInt8> { continuation in
                        values.forEach { continuation.yield($0) }
                        continuation.finish()
                    }
                    let response = HTTPURLResponse(url: request.url!, statusCode: scenario == "resumed" ? 206 : 200,
                        httpVersion: nil, headerFields: scenario == "resumed" ? ["Content-Range": "bytes 2-3/4"] : nil)!
                    return (bytes, response as URLResponse)
                }
            }
            #expect(try Data(contentsOf: result) == expected)
        } catch {
            failed = true
            #expect(scenario == "short" || scenario == "publication", "Unexpected \(scenario) download failure: \(error)")
        }
        #expect(failed == (scenario == "short" || scenario == "publication"))
        #expect(fetched == (scenario != "cached" && scenario != "complete-partial"))
        if fetched {
            #expect(output.text.contains("Connecting to server for IPSW 27.0"))
            #expect(output.text.contains("Downloading IPSW 27.0"))
            #expect(output.text.contains("Verifying IPSW 27.0"))
        }
        if scenario == "complete-partial" {
            #expect(output.text.contains("Publishing IPSW 27.0"))
        }
        if scenario == "cached" {
            #expect(output.text.contains("Using cached IPSW 27.0"))
            #expect(!output.text.contains("Downloading IPSW"))
        } else if failed {
            #expect(!output.text.contains("Downloaded IPSW"))
        } else {
            #expect(output.text.contains("Downloaded IPSW 27.0"))
            #expect(output.text.contains("100%"))
        }
    }
}
