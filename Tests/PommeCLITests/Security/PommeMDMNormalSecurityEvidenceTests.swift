import Foundation
import Testing

@Suite("Normal MDM security evidence")
struct PommeMDMNormalSecurityEvidenceTests {
    private let sipOutput = Data(
        "System Integrity Protection status: disabled.\n".utf8
    )
    private let override = PommeBootArguments.amfiOverride

    @Test("Builds a canonical baseline from authenticated normal evidence")
    func buildsBaseline() throws {
        let configured = Data("configured=1 \(override) configured=2".utf8)
        let active = Data("active=1 \(override) active=2\n".utf8)
        let baseline = try PommeMDMNormalSecurityEvidence.baseline(
            csrutil: sipOutput,
            nvram: try nvramXML(value: configured),
            activeBootArguments: active,
            runState: .running(.normal)
        )

        #expect(baseline.runState == .running(.normal))
        let sip = try #require(try JSONDecoder().decode(JSONValue.self, from: baseline.sip).objectValue)
        #expect(sip == [
            "operation": .string("sip.status"),
            "sipDisabled": .bool(true),
            "verified": .bool(true),
            "provenance": .string("authenticated-normal-agent"),
        ])
        let amfi = try #require(try JSONDecoder().decode(JSONValue.self, from: baseline.amfi).objectValue)
        #expect(Set(amfi.keys) == [
            "operation", "amfiDisabled", "verified", "provenance",
            "configuredBootArgumentsBase64", "activeBootArgumentsBase64",
        ])
        #expect(amfi["operation"] == .string("amfi.status"))
        #expect(amfi["amfiDisabled"] == .bool(true))
        #expect(amfi["verified"] == .bool(true))
        #expect(amfi["provenance"] == .string("authenticated-normal-agent"))
        #expect(amfi["configuredBootArgumentsBase64"] == .string(configured.base64EncodedString()))
        #expect(amfi["activeBootArgumentsBase64"] == .string(Data("active=1 \(override) active=2".utf8).base64EncodedString()))
    }

    @Test("Requires exact disabled SIP evidence and a normal run state")
    func rejectsSIPAndRunStateMismatches() throws {
        let nvram = try nvramXML(value: Data(override.utf8))
        let active = Data("\(override)\n".utf8)
        let states: [VMRunStateSnapshot] = [
            .stopped,
            .paused(previousBootMode: .normal),
            .running(.recovery),
        ]
        for state in states {
            #expect(throws: PommeMDMEnrollmentError.self) {
                try PommeMDMNormalSecurityEvidence.baseline(
                    csrutil: sipOutput,
                    nvram: nvram,
                    activeBootArguments: active,
                    runState: state
                )
            }
        }
        #expect(throws: PommeMDMEnrollmentError.self) {
            try PommeMDMNormalSecurityEvidence.baseline(
                csrutil: Data("System Integrity Protection status: enabled.\n".utf8),
                nvram: nvram,
                activeBootArguments: active,
                runState: .running(.normal)
            )
        }
    }

    @Test("Requires the exact AMFI token in both configured and active arguments")
    func requiresBothAMFIInputs() throws {
        let configuredOnly = try nvramXML(value: Data(override.utf8))
        let activeOnly = Data("\(override)\n".utf8)
        #expect(throws: PommeMDMEnrollmentError.self) {
            try PommeMDMNormalSecurityEvidence.baseline(
                csrutil: sipOutput,
                nvram: configuredOnly,
                activeBootArguments: Data("other=1\n".utf8),
                runState: .running(.normal)
            )
        }
        #expect(throws: PommeMDMEnrollmentError.self) {
            try PommeMDMNormalSecurityEvidence.baseline(
                csrutil: sipOutput,
                nvram: try nvramXML(value: Data("other=1".utf8)),
                activeBootArguments: activeOnly,
                runState: .running(.normal)
            )
        }
    }

    @Test("Rejects lookalike, conflicting, and duplicate AMFI tokens")
    func rejectsAMFILookalikesAndDuplicates() throws {
        let active = Data("\(override)\n".utf8)
        let invalidConfiguredValues = [
            "amfi_get_out_of_my_way=0x10",
            "amfi_get_out_of_my_way=0x0 \(override)",
            "\(override) \(override)",
        ]
        for value in invalidConfiguredValues {
            #expect(throws: PommeMDMEnrollmentError.self) {
                try PommeMDMNormalSecurityEvidence.baseline(
                    csrutil: sipOutput,
                    nvram: try nvramXML(value: Data(value.utf8)),
                    activeBootArguments: active,
                    runState: .running(.normal)
                )
            }
        }

        #expect(throws: PommeMDMEnrollmentError.self) {
            try PommeMDMNormalSecurityEvidence.baseline(
                csrutil: sipOutput,
                nvram: try nvramXML(value: Data(override.utf8)),
                activeBootArguments: Data("\(override) \(override)\n".utf8),
                runState: .running(.normal)
            )
        }
    }

    @Test("Rejects malformed, missing, and non XML NVRAM receipts")
    func rejectsMalformedNVRAM() throws {
        let active = Data("\(override)\n".utf8)
        let malformed: [Data] = [
            Data(),
            Data("not plist".utf8),
            try nvramXML(value: Data(override.utf8), extra: ["other": "1"]),
            try plist(value: ["boot-args": 1]),
            try plist(value: ["boot-args": Data(override.utf8)]),
        ]
        for value in malformed {
            #expect(throws: PommeMDMEnrollmentError.self) {
                try PommeMDMNormalSecurityEvidence.baseline(
                    csrutil: sipOutput,
                    nvram: value,
                    activeBootArguments: active,
                    runState: .running(.normal)
                )
            }
        }
    }

    @Test("Rejects malformed active boot argument output")
    func rejectsMalformedActiveArguments() throws {
        let nvram = try nvramXML(value: Data(override.utf8))
        let invalid: [Data] = [
            Data(override.utf8),
            Data("\(override)\n\n".utf8),
            Data("\(override)\r\n".utf8),
            Data([UInt8(ascii: "a"), 0, 0x0a]),
        ]
        for active in invalid {
            #expect(throws: PommeMDMEnrollmentError.self) {
                try PommeMDMNormalSecurityEvidence.baseline(
                    csrutil: sipOutput,
                    nvram: nvram,
                    activeBootArguments: active,
                    runState: .running(.normal)
                )
            }
        }
    }

    @Test("Preserves raw configured bytes in the baseline comparison")
    func rawConfiguredChangeChangesBaseline() throws {
        let active = Data("\(override)\n".utf8)
        let first = try PommeMDMNormalSecurityEvidence.baseline(
            csrutil: sipOutput,
            nvram: try nvramXML(value: Data("prefix-a \(override)".utf8)),
            activeBootArguments: active,
            runState: .running(.normal)
        )
        let second = try PommeMDMNormalSecurityEvidence.baseline(
            csrutil: sipOutput,
            nvram: try nvramXML(value: Data("prefix-b \(override)".utf8)),
            activeBootArguments: active,
            runState: .running(.normal)
        )
        #expect(first != second)
        #expect(first.sip == second.sip)
        #expect(first.amfi != second.amfi)
    }

    private func nvramXML(
        value: Data,
        extra: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = ["boot-args": String(decoding: value, as: UTF8.self)]
        object.merge(extra) { current, _ in current }
        return try plist(value: object, format: .xml)
    }

    private func plist(
        value: Any,
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }
}
