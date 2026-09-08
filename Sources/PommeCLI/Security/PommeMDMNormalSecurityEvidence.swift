import Foundation

/// Builds the security baseline used by normal-boot MDM enrollment from
/// already authenticated, bounded process output. This type performs no VM or
/// process operation of its own; its only authority is the supplied evidence.
enum PommeMDMNormalSecurityEvidence {
    private static let expectedSIPOutput = Data(
        "System Integrity Protection status: disabled.\n".utf8
    )
    private static let provenance = "authenticated-normal-agent"
    private static let configuredBootArgumentsKey = "configuredBootArgumentsBase64"
    private static let activeBootArgumentsKey = "activeBootArgumentsBase64"

    /// Converts the complete successful stdout receipts into the canonical
    /// baseline consumed by the MDM transaction. Both configured NVRAM and
    /// active boot arguments must carry the exact AMFI override token.
    static func baseline(
        csrutil: Data,
        nvram: Data,
        activeBootArguments: Data,
        runState: VMRunStateSnapshot
    ) throws -> PommeMDMEnrollmentStateBaseline {
        guard runState == .running(.normal), csrutil == expectedSIPOutput else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }

        let configured = try configuredBootArguments(from: nvram)
        let active = try Self.activeBootArguments(from: activeBootArguments)
        guard containsSingleAMFIOverride(configured),
              containsSingleAMFIOverride(active) else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }

        let sip = try PommeProvisioningCoding.encode(JSONValue.object([
            "operation": .string("sip.status"),
            "sipDisabled": .bool(true),
            "verified": .bool(true),
            "provenance": .string(provenance),
        ]))
        let amfi = try PommeProvisioningCoding.encode(JSONValue.object([
            "operation": .string("amfi.status"),
            "amfiDisabled": .bool(true),
            "verified": .bool(true),
            "provenance": .string(provenance),
            configuredBootArgumentsKey: .string(configured.base64EncodedString()),
            activeBootArgumentsKey: .string(active.base64EncodedString()),
        ]))
        return .init(sip: sip, amfi: amfi, runState: runState)
    }

    private static func configuredBootArguments(from data: Data) throws -> Data {
        guard !data.isEmpty else { throw PommeMDMEnrollmentError.baselineCaptureFailed }
        var format = PropertyListSerialization.PropertyListFormat.openStep
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ),
        format == .xml,
        let dictionary = propertyList as? [String: Any],
        Set(dictionary.keys) == ["boot-args"] else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }

        let bytes: Data
        switch dictionary["boot-args"] {
        case let value as Data:
            bytes = value
        case let value as String:
            bytes = Data(value.utf8)
        default:
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        guard bytes.count <= 64 * 1024, !bytes.contains(0) else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        return bytes
    }

    private static func activeBootArguments(from data: Data) throws -> Data {
        // sysctl appends one output newline. Remove exactly that delimiter and
        // retain every byte from the authenticated boot-args value.
        guard let final = data.last,
              final == 0x0a,
              data.count > 1,
              data[data.count - 2] != 0x0a else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        let value = Data(data.dropLast())
        guard value.count <= 64 * 1024,
              !value.contains(0),
              !value.contains(0x0d) else {
            throw PommeMDMEnrollmentError.baselineCaptureFailed
        }
        return value
    }

    /// PommeBootArguments is the policy authority for exact token matching.
    /// The surrounding token scan rejects duplicate exact switches and
    /// conflicting values before that policy result is accepted.
    private static func containsSingleAMFIOverride(_ data: Data) -> Bool {
        guard PommeBootArguments.containsOverride(data) else { return false }
        let override = Data(PommeBootArguments.amfiOverride.utf8)
        let keyPrefix = Data("amfi_get_out_of_my_way=".utf8)
        let tokens = data.split(whereSeparator: isBootArgumentWhitespace)
        var exactCount = 0
        for token in tokens {
            let tokenData = Data(token)
            if tokenData == override {
                exactCount += 1
            } else if tokenData.starts(with: keyPrefix) {
                return false
            }
        }
        return exactCount == 1
    }

    private static func isBootArgumentWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0a || byte == 0x0b
            || byte == 0x0c || byte == 0x0d || byte == 0x20
    }
}
