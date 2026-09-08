import Foundation
import Testing

@Suite("Private MDM helper")
struct PommeMDMPrivateHelperTests {
    @Test("Request parser accepts the exact enrollment schema")
    func exactRequestSchema() throws {
        let requestID = "01234567-89ab-cdef-0123-456789abcdef"
        let object: [String: Any] = [
            "version": 1,
            "action": "enroll",
            "requestID": requestID,
            "expiresAt": "2030-01-01T00:00:00Z",
            "helperSHA256": String(repeating: "a", count: 64),
            "profilePath": "/private/var/db/pomme-mdm-enrollment/profile.mobileconfig",
            "profileSHA256": String(repeating: "b", count: 64),
            "profileBytes": 128,
            "mode": "supervised",
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let request = try PommeMDMPrivateHelper.parseRequest(data, expectedRequestID: requestID)
        #expect(request.version == 1)
        #expect(request.action == "enroll")
        #expect(request.requestID == requestID)
        #expect(request.profileBytes == 128)
        #expect(request.mode.rawValue == MDMEnrollmentMode.supervised.rawValue)

        let digest = PommeProvisioningDigest.sha256(data)
        #expect(try PommeMDMPrivateHelper.parseBoundRequest(
            data, expectedRequestID: requestID, expectedSHA256: digest
        ) == request)
        var changed = object
        changed["profileBytes"] = 129
        let changedData = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: Error.self) {
            _ = try PommeMDMPrivateHelper.parseBoundRequest(
                changedData, expectedRequestID: requestID, expectedSHA256: digest
            )
        }
        #expect(throws: Error.self) {
            _ = try PommeMDMPrivateHelper.parseBoundRequest(
                data, expectedRequestID: requestID, expectedSHA256: digest.uppercased()
            )
        }
    }

    @Test("Request parser rejects extra keys, approval actions, and noncanonical UUIDs")
    func requestSchemaIsClosed() throws {
        let requestID = "01234567-89ab-cdef-0123-456789abcdef"
        var object: [String: Any] = [
            "version": 1,
            "action": "enroll",
            "requestID": requestID,
            "expiresAt": "2030-01-01T00:00:00Z",
            "helperSHA256": String(repeating: "a", count: 64),
            "profilePath": "/private/var/db/pomme-mdm-enrollment/profile.mobileconfig",
            "profileSHA256": String(repeating: "b", count: 64),
            "profileBytes": 128,
        ]

        object["password"] = "must-not-cross-the-boundary"
        let extra = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: Error.self) {
            _ = try PommeMDMPrivateHelper.parseRequest(extra, expectedRequestID: requestID)
        }

        object.removeValue(forKey: "password")
        object["action"] = "approve"
        let approval = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: Error.self) {
            _ = try PommeMDMPrivateHelper.parseRequest(approval, expectedRequestID: requestID)
        }

        object["action"] = "enroll"
        object["requestID"] = requestID.uppercased()
        let uppercase = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: Error.self) {
            _ = try PommeMDMPrivateHelper.parseRequest(uppercase, expectedRequestID: requestID)
        }

        object["requestID"] = requestID
        object["mode"] = "unsupported"
        let unsupportedMode = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: Error.self) {
            _ = try PommeMDMPrivateHelper.parseRequest(unsupportedMode, expectedRequestID: requestID)
        }

        object["mode"] = NSNull()
        let nullMode = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: Error.self) {
            _ = try PommeMDMPrivateHelper.parseRequest(nullMode, expectedRequestID: requestID)
        }

        object.removeValue(forKey: "mode")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let legacyRequest = try PommeMDMPrivateHelper.parseRequest(legacy, expectedRequestID: requestID)
        #expect(legacyRequest.mode.rawValue == MDMEnrollmentMode.unapproved.rawValue)
    }

    @Test("Derived artifacts are direct children with one UUID-bound basename")
    func derivedPaths() throws {
        let root = URL(fileURLWithPath: "/private/var/db/pomme-mdm-enrollment", isDirectory: true)
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        let paths = try PommeMDMPrivateHelper.Paths(requestID: id, root: root)
        #expect(paths.helper.path == root.path + "/helper-\(id).bin")
        #expect(paths.request.path == root.path + "/helper-\(id).request.json")
        #expect(paths.entitlements.path == root.path + "/helper-\(id).entitlements.plist")
        #expect(paths.helper.deletingLastPathComponent().path == root.path)
        #expect(throws: Error.self) {
            _ = try PommeMDMPrivateHelper.Paths(requestID: id.uppercased(), root: root)
        }
    }

    @Test("AMFI gate requires the exact boot argument token")
    func amfiGate() {
        #expect(PommeMDMPrivateHelper.hasAMFIOverride("foo amfi_get_out_of_my_way=0x1 bar"))
        #expect(PommeMDMPrivateHelper.hasAMFIOverride("amfi_get_out_of_my_way=0x1"))
        #expect(!PommeMDMPrivateHelper.hasAMFIOverride("foo amfi_get_out_of_my_way=0x10 bar"))
        #expect(!PommeMDMPrivateHelper.hasAMFIOverride("AMFI_GET_OUT_OF_MY_WAY=0x1"))
        #expect(!PommeMDMPrivateHelper.hasAMFIOverride(nil))
    }

    @Test("Entitlement gate accepts only the two private MDM entitlements")
    func entitlementGate() {
        let exact = PommeMDMPrivateHelper.requiredPrivateEntitlements
        #expect(PommeMDMPrivateHelper.acceptsEntitlementSet(exact))
        #expect(!PommeMDMPrivateHelper.acceptsEntitlementSet(exact.union(["com.apple.security.get-task-allow"])))
        #expect(!PommeMDMPrivateHelper.acceptsEntitlementSet(exact.subtracting([exact.first!])))
    }

    @Test("Request file lease is exclusive and reusable after release")
    func sharedFileLease() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomme-mdm-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("request.json")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data("{}".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let owner = geteuid()
        let group = getegid()
        let first = try PommeMDMPrivateHelper.SharedFileLease.acquire(
            at: file,
            expectedOwner: owner,
            expectedGroup: group
        )
        #expect(throws: Error.self) {
            _ = try PommeMDMPrivateHelper.SharedFileLease.acquire(
                at: file,
                expectedOwner: owner,
                expectedGroup: group
            )
        }
        first.release()
        let second = try PommeMDMPrivateHelper.SharedFileLease.acquire(
            at: file,
            expectedOwner: owner,
            expectedGroup: group
        )
        second.release()
    }
}
