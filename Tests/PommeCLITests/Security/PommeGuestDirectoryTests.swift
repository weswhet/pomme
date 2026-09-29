import Foundation
import Testing

@Suite("Guest OpenDirectory operations")
struct PommeGuestDirectoryTests {
    private let records: [[String: [String]]] = [
        ["RecordName": ["root"], "RealName": ["System Administrator"], "UniqueID": ["0"],
         "GeneratedUID": ["FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000"], "NFSHomeDirectory": ["/var/root"]],
        ["RecordName": ["pomme"], "RealName": ["Pomme"], "UniqueID": ["501"],
         "GeneratedUID": ["08E1A855-1082-48D6-943D-6834E28BE2BD"], "NFSHomeDirectory": ["/Users/pomme"]],
    ]

    @Test("Local users are returned with single-valued attributes; verification returns a boolean")
    func operations() throws {
        let directory = PommeGuestDirectory(effectiveUserID: { 0 }, readRecords: { records },
                                            verify: { $0 == "pomme" && $1 == "secret" })
        let users = try directory.perform(operation: PommeGuestDirectory.readUsersOperation, payload: .object([:]))
        let snapshot = try PommeGuestDirectorySnapshot(result: users.publicValue)
        #expect(snapshot.users["pomme"]?["UniqueID"] == "501")
        #expect(snapshot.users["root"]?["NFSHomeDirectory"] == "/var/root")
        #expect(try directory.perform(operation: PommeGuestDirectory.verifyPasswordOperation,
            payload: .object(["username": .string("pomme"), "password": .string("secret")]))
            == .object(["verified": .bool(true)]))
        #expect(try directory.perform(operation: PommeGuestDirectory.verifyPasswordOperation,
            payload: .object(["username": .string("pomme"), "password": .string("wrong")]))
            == .object(["verified": .bool(false)]))
    }

    @Test("Record-name aliases use the primary name and other multiple values are space-joined, like dscl")
    func multipleValues() throws {
        let directory = PommeGuestDirectory(effectiveUserID: { 0 }, readRecords: {
            [["RecordName": ["root", "BUILTIN\\Local System"], "UniqueID": ["0"], "RealName": ["System", "Administrator"]]]
        }, verify: { _, _ in true })
        let users = try PommeGuestDirectorySnapshot(result: directory.perform(
            operation: PommeGuestDirectory.readUsersOperation, payload: .object([:])).publicValue).users
        #expect(users["root"]?["RecordName"] == "root")
        #expect(users["root"]?["RealName"] == "System Administrator")
        #expect(try PommeGuestDirectorySnapshot(users: users).dsclOutput([".", "-list", "/Users", "UniqueID"]) == "root 0\n")
    }

    @Test("Non-root agents, malformed payloads, and newline values are refused")
    func refusals() {
        let unprivileged = PommeGuestDirectory(effectiveUserID: { 501 }, readRecords: { records }, verify: { _, _ in true })
        #expect(throws: PommeAgentOperationError.self) {
            try unprivileged.perform(operation: PommeGuestDirectory.readUsersOperation, payload: .object([:]))
        }
        let directory = PommeGuestDirectory(effectiveUserID: { 0 }, readRecords: {
            [["RecordName": ["pomme"], "RealName": ["Line\nbreak"]]]
        }, verify: { _, _ in true })
        #expect(throws: PommeAgentOperationError.self) {
            try directory.perform(operation: PommeGuestDirectory.readUsersOperation, payload: .object([:]))
        }
        for payload: JSONValue in [
            .object(["username": .string("pomme")]),
            .object(["username": .string("../x"), "password": .string("p")]),
            .object(["username": .string("pomme"), "password": .string("")]),
            .object(["username": .string("pomme"), "password": .string("p"), "extra": .bool(true)]),
        ] {
            #expect(throws: PommeAgentOperationError.self) {
                try directory.perform(operation: PommeGuestDirectory.verifyPasswordOperation, payload: payload)
            }
        }
        #expect(throws: PommeAgentOperationError.self) {
            try directory.perform(operation: PommeGuestDirectory.readUsersOperation, payload: .object(["x": .bool(true)]))
        }
    }

    @Test("The host allowlist and agent capabilities include both operations")
    func wiring() throws {
        for operation in PommeGuestDirectory.operations {
            #expect(PommeAgent.persistentCapabilities.contains(operation))
            #expect(throws: Never.self) {
                _ = try PommeAgentPerformRequest.parse(from: ["operation": .string(operation), "payload": .object([:])])
            }
        }
    }

    @Test("Snapshots render exactly the dscl forms owner evidence parses")
    func rendering() throws {
        let snapshot = PommeGuestDirectorySnapshot(users: [
            "pomme": ["RecordName": "pomme", "RealName": "Pomme", "UniqueID": "501",
                      "GeneratedUID": "08E1A855-1082-48D6-943D-6834E28BE2BD", "NFSHomeDirectory": "/Users/pomme"],
            "nobody": ["RecordName": "nobody", "RealName": "Unprivileged User", "UniqueID": "-2"],
        ])
        #expect(try snapshot.dsclOutput([".", "-list", "/Users", "UniqueID"]) == "nobody -2\npomme 501\n")
        #expect(try snapshot.dsclOutput([".", "-list", "/Users", "GeneratedUID"])
            == "nobody\npomme 08E1A855-1082-48D6-943D-6834E28BE2BD\n")
        #expect(try snapshot.dsclOutput([".", "-read", "/Users/pomme", "RecordName", "UniqueID"])
            == "RecordName: pomme\nUniqueID: 501\n")
        for arguments in [[".", "-read", "/Users/absent", "RecordName"], [".", "-authonly", "pomme"],
                          [".", "-read", "/Users/pomme", "Password"]] {
            #expect(throws: PommeSecurityOwnerPreparationError.self) { try snapshot.dsclOutput(arguments) }
        }
    }

    @Test("Agent results with newlines, unknown attributes, or duplicates are rejected")
    func decoding() {
        for users: [[String: Any]] in [
            [["RecordName": "pomme", "RealName": "Pom\nme"]],
            [["RecordName": "pomme", "Password": "x"]],
            [["RecordName": "pomme"], ["RecordName": "pomme"]],
            [],
        ] {
            #expect(throws: PommeSecurityOwnerPreparationError.self) {
                try PommeGuestDirectorySnapshot(result: ["users": users])
            }
        }
    }
}
