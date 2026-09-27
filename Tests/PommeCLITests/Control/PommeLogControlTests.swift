import Foundation
import Testing

@Suite("Pomme log helper control")
struct PommeLogControlTests {
    @Test("History routing applies typed defaults and keeps streaming mandatory")
    func showDefaults() throws {
        let request = PommeControlRequest(command: "logs.show", payload: .object([:]), streaming: true)
        guard case .logsShow(let log) = try PommeVMControlRouter.route(request) else {
            Issue.record("logs.show was not routed")
            return
        }
        #expect(log.last == "10m")
        #expect(log.categories.isEmpty)
        #expect(log.level == "info")
        #expect(log.format == .text)
        #expect(log.timeout == 60)
        #expect(throws: RunnerError.self) {
            try PommeVMControlRouter.route(.init(command: "logs.show", payload: .object([:])))
        }
    }

    @Test("Log requests reject unknown keys, malformed types, and out-of-range timeouts")
    func strictWireValidation() throws {
        let invalidShow: [[String: JSONValue]] = [
            ["last": .string("0m")],
            ["last": .string("10w")],
            ["last": .integer(10)],
            ["categories": .string("buddy-preferences")],
            ["categories": .array([.string("")])],
            ["level": .string("notice")],
            ["format": .string("raw")],
            ["timeout": .number(0)],
            ["timeout": .number(300.1)],
            ["unknown": .bool(true)],
        ]
        for payload in invalidShow {
            #expect(throws: RunnerError.self) {
                try PommeVMControlRouter.route(.init(command: "logs.show", payload: .object(payload), streaming: true))
            }
        }

        for payload: [String: JSONValue] in [
            ["last": .string("1m")],
            ["format": .string("json")],
            ["timeout": .integer(1)],
        ] {
            #expect(throws: RunnerError.self) {
                try PommeVMControlRouter.route(.init(command: "logs.stream", payload: .object(payload), streaming: true))
            }
        }
    }

    @Test("Log durations use ASCII decimals and categories reject control characters")
    func durationAndCategoryBoundaries() throws {
        for last in ["١m", "+1m", "1e2m", "１m"] {
            #expect(throws: RunnerError.self) {
                try PommeVMControlRouter.route(.init(
                    command: "logs.show",
                    payload: .object(["last": .string(last)]),
                    streaming: true
                ))
            }
        }

        for category in ["line\nbreak", "tab\tbreak", "delete\u{7f}", "next\u{85}"] {
            #expect(throws: RunnerError.self) {
                try PommeVMControlRouter.route(.init(
                    command: "logs.stream",
                    payload: .object(["categories": .array([.string(category)])]),
                    streaming: true
                ))
            }
        }

        guard case .logsShow(let accepted) = try PommeVMControlRouter.route(.init(
            command: "logs.show",
            payload: .object(["last": .string(".5h"), "categories": .array([.string("quoted\"category")])]),
            streaming: true
        )) else {
            Issue.record("ASCII duration and escaped category were not routed")
            return
        }
        #expect(accepted.last == ".5h")
        #expect(accepted.logPredicate.contains(#"category == "quoted\"category""#))
    }

    @Test("Log arguments pin the subsystem and escape exact category literals")
    func argumentConstruction() throws {
        let request = PommeControlRequest(command: "logs.show", payload: .object([
            "last": .string("1.5h"),
            "categories": .array([.string("buddy-preferences"), .string("quoted\"category")]),
            "level": .string("debug"),
            "format": .string("jsonl"),
            "timeout": .integer(120),
        ]), streaming: true)
        guard case .logsShow(let log) = try PommeVMControlRouter.route(request) else {
            Issue.record("logs.show was not routed")
            return
        }
        #expect(log.logArguments == [
            "show", "--style", "ndjson", "--predicate",
            #"subsystem == "com.github.weswhet.pomme" AND (category == "buddy-preferences" OR category == "quoted\"category")"#,
            "--last", "1.5h", "--debug",
        ])
        guard let payload = log.processPayload.objectValue else {
            Issue.record("Log process payload was not an object")
            return
        }
        #expect(payload["path"] == .string("/usr/bin/log"))
        #expect(payload["pty"] == .bool(false))
        #expect(payload["detached"] == .bool(false))
    }

    @Test("Follow uses log stream style and explicit level")
    func streamArguments() throws {
        let request = PommeControlRequest(command: "logs.stream", payload: .object([
            "categories": .array([.string("buddy-preferences")]),
            "level": .string("default"),
            "format": .string("jsonl"),
        ]), streaming: true)
        guard case .logsStream(let log) = try PommeVMControlRouter.route(request) else {
            Issue.record("logs.stream was not routed")
            return
        }
        #expect(log.logArguments == [
            "stream", "--style", "ndjson", "--predicate",
            #"subsystem == "com.github.weswhet.pomme" AND (category == "buddy-preferences")"#,
            "--level", "default",
        ])
        #expect(log.processPayload.objectValue?["timeout"] == .number(300))
    }

    @Test("Only an authenticated persistent PommeAgent receipt can start logs")
    func capabilityReceipt() {
        let required: JSONValue = .object([
            "role": .string("persistent"),
            "protocol": .string(PommeAgentProtocol.name),
            "version": .integer(Int64(PommeAgentProtocol.version)),
            "capabilities": .array([
                .string("process.start"), .string("process.status"), .string("process.signal"),
            ]),
        ])
        #expect(PommeCore.supportsPommeLog(required))
        for capability in ["process.start", "process.status", "process.signal"] {
            var values = required.objectValue ?? [:]
            values["capabilities"] = .array([
                .string("process.start"), .string("process.status"), .string("process.signal"),
            ].filter { $0 != .string(capability) })
            #expect(!PommeCore.supportsPommeLog(.object(values)))
        }
        #expect(!PommeCore.supportsPommeLog(.object([
            "role": .string("recovery"),
            "protocol": .string(PommeAgentProtocol.name),
            "version": .integer(Int64(PommeAgentProtocol.version)),
            "capabilities": .array([]),
        ])))
    }
}
