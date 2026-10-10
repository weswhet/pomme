import Darwin
import Foundation
import Security
import Testing

@Suite("Error codes, translators, and reports")
struct PommeErrorTests {
    // MARK: Catalog

    @Test("Catalog codes are unique, kebab-case, and fully described")
    func catalogIsWellFormed() {
        let codes = PommeErrorCatalog.entries.map(\.code)
        #expect(Set(codes).count == codes.count)
        for entry in PommeErrorCatalog.entries {
            #expect(entry.code.isWellFormed, "\(entry.code) isn't kebab-case")
            #expect(!entry.area.isEmpty, "\(entry.code) has no area")
            #expect(!entry.title.isEmpty, "\(entry.code) has no title")
            #expect(!entry.cause.isEmpty, "\(entry.code) has no cause")
            #expect(!entry.resolution.isEmpty, "\(entry.code) has no resolution")
            #expect(entry.resolution.allSatisfy { !$0.isEmpty }, "\(entry.code) has an empty step")
        }
    }

    @Test("Every RunnerError and system translation uses a catalogued code")
    func usedCodesAreCatalogued() {
        let errors: [any PommeDescribedError] = [
            RunnerError.usage, RunnerError.namedVMNotFound("vm"), RunnerError.noRunningVM(URL(fileURLWithPath: "/tmp/s")),
            RunnerError.invalidControlCommand("x"), RunnerError.invalidRequest(field: "--last", reason: "bad"),
            RunnerError.controlSocketTimedOut, RunnerError.posix(function: "open", code: ENOSPC),
            RunnerError.vmBootModeConflict(name: "vm", paused: true, current: "recovery", requested: "normal"),
            RunnerError.vmBootModeConflict(name: "vm", paused: false, current: "recovery", requested: "normal"),
            RunnerError.vmHelperRunning(name: "vm"), RunnerError.guestAgentUnavailable, RunnerError.keychainError("x"),
            RunnerError.controlCommandFailed("x"), RunnerError.hostCommandFailed("x"), RunnerError.virtualMachineState("x")
        ]
        for error in errors {
            #expect(PommeErrorCatalog.entry(for: error.code) != nil, "\(error.code) isn't catalogued")
        }
        let vzCodes = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 10001, 10002, 10003, 10004, 10005, 10006, 10007,
                       20001, 20002, 30001, 30002, 30003, 30004, 40001, 40002, 40003, 50001, 50002, 99999]
        for code in vzCodes {
            let description = SystemErrorDescription.virtualization(code: code)
            #expect(PommeErrorCatalog.entry(for: description.pommeCode) != nil, "VZ \(code) maps to \(description.pommeCode)")
        }
    }

    // MARK: Translators

    @Test("Virtualization errors read as sentences and keep their domain and number")
    func virtualizationTranslation() throws {
        let error = NSError(domain: "VZErrorDomain", code: 8)
        let description = try #require(SystemErrorDescription(error))
        #expect(description.pommeCode == .hostDiskFull)
        #expect(description.message == "The disk is out of space.")
        #expect(description.domain == "VZErrorDomain")
        #expect(description.code == "8")
        #expect(description.clause == "the disk is out of space (VZErrorDomain 8)")

        #expect(SystemErrorDescription.virtualization(code: 6).pommeCode == .vmLimitReached)
        #expect(SystemErrorDescription.virtualization(code: 2).pommeCode == .vmConfigurationInvalid)
        #expect(SystemErrorDescription.virtualization(code: 10006).pommeCode == .hostUpdateRequired)
        #expect(SystemErrorDescription.virtualization(code: 10007).pommeCode == .macosInstallFailed)
        #expect(SystemErrorDescription.virtualization(code: 99999, fallback: "Something odd").message == "Something odd.")
    }

    @Test("Clauses lowercase ordinary words but keep acronyms and names")
    func clauseCapitalization() {
        #expect(SystemErrorDescription.lowercasingFirstWord("The disk is full") == "the disk is full")
        #expect(SystemErrorDescription.lowercasingFirstWord("VM is busy") == "VM is busy")
        #expect(SystemErrorDescription.lowercasingFirstWord("macOS failed") == "macOS failed")
        #expect(SystemErrorDescription.lowercasingFirstWord("Pomme couldn't start") == "Pomme couldn't start")
        #expect(SystemErrorDescription.lowercasingFirstWord("Pommes are fruit") == "pommes are fruit")
    }

    @Test("POSIX errors use strerror text")
    func posixTranslation() throws {
        let description = try #require(SystemErrorDescription(POSIXError(.ENOSPC)))
        #expect(description.message == String(cString: strerror(ENOSPC)) + ".")
        #expect(description.domain == NSPOSIXErrorDomain)
        #expect(description.code == String(ENOSPC))
        #expect(description.pommeCode == .hostDiskFull)
        #expect(SystemErrorDescription.posix(EACCES).pommeCode == .permissionDenied)
        #expect(SystemErrorDescription.posix(ENOENT).pommeCode == .fileNotFound)
        #expect(SystemErrorDescription.posix(EINVAL).pommeCode == .systemCallFailed)
    }

    @Test("OSStatus errors use the Security framework's text")
    func osStatusTranslation() throws {
        let error = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound))
        let description = try #require(SystemErrorDescription(error))
        #expect(description.message == SystemErrorDescription.sentence(securityErrorMessage(errSecItemNotFound)))
        #expect(description.code == String(errSecItemNotFound))
        #expect(description.pommeCode == .keychainError)
    }

    @Test("URL errors name the network failure")
    func urlTranslation() throws {
        let description = try #require(SystemErrorDescription(URLError(.timedOut)))
        #expect(description.message == "The network request timed out.")
        #expect(description.pommeCode == .networkError)
        #expect(description.domain == NSURLErrorDomain)
        #expect(SystemErrorDescription(URLError(.notConnectedToInternet))?.message == "This Mac isn't connected to the internet.")
    }

    @Test("Cocoa file errors name the file")
    func cocoaTranslation() throws {
        let error = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/tmp/missing"])
        let description = try #require(SystemErrorDescription(error))
        #expect(description.message == "`/tmp/missing` doesn't exist.")
        #expect(description.pommeCode == .fileNotFound)
        #expect(SystemErrorDescription(CocoaError(.fileWriteOutOfSpace))?.pommeCode == .hostDiskFull)
    }

    @Test("Decoding errors name the key path")
    func decodingTranslation() throws {
        struct Shape: Decodable { let inner: Inner; struct Inner: Decodable { let value: Int } }
        let error = try #require(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Shape.self, from: Data(#"{"inner":{}}"#.utf8))
        }
        let description = try #require(SystemErrorDescription(error))
        #expect(description.message == "The data is missing the required key 'inner.value'.")
        #expect(description.pommeCode == .dataInvalid)
        #expect(description.code == "keyNotFound")
    }

    @Test("Swift errors that aren't system errors aren't translated")
    func nativeErrorsAreNotSystemErrors() {
        #expect(SystemErrorDescription(RunnerError.usage) == nil)
        #expect(SystemErrorDescription(CancellationError())?.pommeCode == .operationCancelled)
    }

    // MARK: Reports

    @Test("A report walks the underlying chain")
    func reportChain() {
        let cause = NSError(domain: "VZErrorDomain", code: 8, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        ])
        let wrapper = WrappingError(underlying: cause)
        let report = PommeErrorReport(wrapper)
        #expect(report.code == "provisioning-phase-failed")
        #expect(report.message == "Installing macOS failed: the disk is out of space (VZErrorDomain 8).")
        #expect(report.causes.map(\.domain) == ["VZErrorDomain", NSPOSIXErrorDomain])
        #expect(report.causes.map(\.code) == ["8", String(ENOSPC)])
    }

    @Test("An undescribed error becomes internal-error with its type name")
    func internalError() {
        struct Opaque: Error {}
        let report = PommeErrorReport(Opaque())
        #expect(report.code == .internalError)
        #expect(report.message.contains("Opaque"))
        #expect(PommeErrorCatalog.entry(for: .internalError)?.reportable == true)
    }

    @Test("Reports round-trip through Codable")
    func reportCodable() throws {
        let report = PommeErrorReport(
            code: .vmNotFound,
            message: "No Pomme-owned VM named a exists.",
            hint: "Run `pomme list`.",
            causes: [.init(domain: "VZErrorDomain", code: "8", description: "The disk is out of space.")]
        )
        let decoded = try JSONDecoder().decode(PommeErrorReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(PommeErrorReport(payload: report.payloadObject) == report)
        #expect(PommeErrorReport(payload: ["code": "Not Kebab", "message": "x"]) == nil)
        #expect(PommeErrorReport(payload: nil) == nil)
    }

    @Test("Reports withhold secrets and cap their length")
    func reportRedaction() {
        let report = PommeErrorReport(RunnerError.hostCommandFailed("the password is hunter2"))
        #expect(report.message == PommeErrorRedaction.withheldMessage)
        #expect(!report.message.contains("hunter2"))
        let unredacted = PommeErrorReport(RunnerError.hostCommandFailed("the password is hunter2"), redaction: .none)
        #expect(unredacted.message.contains("hunter2"))
        let long = PommeErrorReport(RunnerError.hostCommandFailed(String(repeating: "x", count: 2000)))
        #expect(long.message.count == PommeErrorRedaction.maximumCharacters)
        #expect(PommeErrorRedaction.abbreviatingHome("/Users/someone/VMs/a", home: "/Users/someone") == "~/VMs/a")
    }

    @Test("A codes-only report keeps no message text")
    func codesOnlyReport() {
        let error = WrappingError(underlying: NSError(domain: "VZErrorDomain", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "private detail"
        ]))
        let report = PommeErrorReport(codesOnly: error)
        #expect(report.code == "provisioning-phase-failed")
        #expect(!report.message.contains("Installing"))
        #expect(report.causes.first?.description == "VZErrorDomain error 8.")
    }

    // MARK: Control envelope compatibility

    @Test("A failure from an older helper still decodes and keeps its text")
    func oldHelperFailureDecodes() throws {
        let id = UUID()
        let line = Data(#"{"type":"response","protocolVersion":\#(PommeControlProtocol.version),"id":"\#(id.uuidString)","ok":false,"error":{"code":"command-failed","message":"It broke."}}"#.utf8) + Data([0x0A])
        let response = try ControlWireCodec.decodeResponse(line, matching: id)
        #expect(response.error?.report == nil)
        let error = try #require(response.error?.clientError as? RunnerError)
        #expect(error.localizedDescription == "The running VM helper rejected the command: command-failed: It broke.")
    }

    @Test("A failure with a report becomes a RemotePommeError")
    func reportedFailureRoundTrips() throws {
        let id = UUID()
        let report = PommeErrorReport(code: .guestCommandNotFound, message: "The command doesn't exist in the guest.")
        let response = PommeControlResponse.failure(id: id, code: "command-failed", message: report.message, report: report)
        let decoded = try ControlWireCodec.decodeResponse(try ControlWireCodec.encodeLine(response), matching: id)
        let remote = try #require(decoded.error?.clientError as? RemotePommeError)
        #expect(remote.code == .guestCommandNotFound)
        #expect(remote.localizedDescription == report.message)
    }

    // MARK: Output

    @Test("Failure text keeps the first line and adds the hint and code")
    func failureText() {
        let report = PommeErrorReport(code: .vmNotRunning, message: "x", hint: "Start it with `pomme start NAME`.")
        let text = PommeErrorOutput.failureText(message: "No running VM helper is listening.", report: report)
        #expect(text == """
        Error: No running VM helper is listening.
        Start it with `pomme start NAME`.
        Error code: vm-not-running. For help, see https://pommevm.dev/reference/errors/#vm-not-running
        """)
        let internalLine = PommeErrorOutput.codeLine(for: .internalError)
        #expect(internalLine.hasSuffix("To report it, run `pomme bug-report`."))
        #expect(PommeErrorOutput.codeLine(for: "not-in-catalog").contains("pomme bug-report"))
    }

    @Test("Failed result payloads gain errorCode, hint, and causes")
    func decorateFailure() {
        let report = PommeErrorReport(code: .guestNotFound, message: "Missing.", hint: "Check the path.")
        var payload: [String: Any] = ["ok": false, "error": "Missing.", PommeErrorReport.payloadKey: report.payloadObject]
        PommeErrorOutput.decorateFailure(&payload)
        #expect(payload["errorCode"] as? String == "guest-not-found")
        #expect(payload["hint"] as? String == "Check the path.")
        #expect((payload["causes"] as? [Any])?.isEmpty == true)
        #expect(payload[PommeErrorReport.payloadKey] == nil)

        var legacy: [String: Any] = ["ok": false, "error": "Old helper text."]
        PommeErrorOutput.decorateFailure(&legacy)
        #expect(legacy["errorCode"] as? String == "operation-failed")

        var success: [String: Any] = ["ok": true]
        PommeErrorOutput.decorateFailure(&success)
        #expect(success["errorCode"] == nil)
    }

    @Test("Recorded arguments keep the command's shape but not private values")
    func redactedArguments() {
        #expect(PommeErrorOutput.redactedArguments(["ui", "type", "--text", "hello", "--vm", "a"])
            == ["ui", "type", "--text", "<redacted>", "--vm", "a"])
        #expect(PommeErrorOutput.redactedArguments(["exec", "a", "--", "/bin/echo", "private"])
            == ["exec", "a", "--", "/bin/echo", "<redacted>"])
        #expect(PommeErrorOutput.redactedArguments(["start", "my-secret-vm"]) == ["start", "<redacted>"])
        #expect(PommeErrorOutput.redactedArguments(["ui", "type", "--text=hi"]) == ["ui", "type", "--text=<redacted>"])
    }

    @Test("The last error round-trips through its file")
    func lastErrorFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-last-error-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let report = PommeErrorReport(code: .vmNotFound, message: "x", hint: "Run `pomme list`.")
        PommeErrorOutput.recordLastError(report: report, message: "No Pomme-owned VM named a exists.", url: url)
        let record = try #require(PommeErrorOutput.readLastError(url: url))
        #expect(record.code == .vmNotFound)
        #expect(record.message == "No Pomme-owned VM named a exists.")
        #expect(record.hint == "Run `pomme list`.")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    // MARK: Bug report

    @Test("A bug report abbreviates the home directory and withholds secret lines")
    func bugReportRedaction() {
        let text = PommeBugReport.render([
            .init(title: "Host", body: "- Path: /Users/someone/VMs/a", preformatted: false),
            .init(title: "Log", body: "fine line\nauth token=abc123\n/Users/someone/x", preformatted: true)
        ], home: "/Users/someone")
        #expect(text.contains("- Path: ~/VMs/a"))
        #expect(!text.contains("abc123"))
        #expect(text.contains(PommeBugReport.withheldLine))
        #expect(text.contains("~/x"))
        #expect(!text.contains("/Users/someone"))
    }

    @Test("A bug report withholds only the inspect lines that mention a secret")
    func bugReportInspectRedaction() {
        let inspect = PommeBugReport.prettyJSON(#"{"name":"lab","capabilities":["directory.password.verify","exec"]}"#)
        let text = PommeBugReport.render([.init(title: "inspect", body: inspect, preformatted: true)])
        #expect(text.contains(#""name" : "lab""#))
        #expect(text.contains(#""exec""#))
        #expect(!text.contains("directory.password.verify"))
        #expect(PommeBugReport.prettyJSON("not json") == "not json")
    }

    @Test("A bug report refuses to replace an existing file")
    func bugReportDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pomme-bug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("report.md")
        try Data().write(to: existing)
        #expect(throws: RunnerError.self) {
            _ = try PommeBugReport.destination(existing.path, now: Date(), directory: directory)
        }
        let fresh = try PommeBugReport.destination(nil, now: Date(timeIntervalSince1970: 0), directory: directory)
        #expect(fresh.lastPathComponent.hasPrefix("pomme-bug-report-"))
        #expect(fresh.pathExtension == "md")
    }

    @Test("The VM for a bug report comes from the last error's arguments")
    func bugReportVMName() {
        let record = PommeErrorOutput.LastError(
            code: .vmNotRunning, message: "x", hint: nil, causes: [],
            arguments: ["exec", "lab", "--", "/bin/ls"], time: Date(), version: "pomme 0 (x)"
        )
        #expect(PommeBugReport.vmName(in: record, existing: { ["lab", "other"] }) == "lab")
        #expect(PommeBugReport.vmName(in: record, existing: { ["other"] }) == nil)
        #expect(PommeBugReport.vmName(in: nil, existing: { ["lab"] }) == nil)
    }
}

/// A stand-in for a wrapping error, such as a failed provisioning phase.
private struct WrappingError: PommeDescribedError {
    let cause: any Error
    init(underlying: any Error) { cause = underlying }
    var code: PommeErrorCode { "provisioning-phase-failed" }
    var errorDescription: String? { "Installing macOS failed: \(PommeErrorDescriber.clause(for: cause))." }
    var underlying: (any Error)? { cause }
}
