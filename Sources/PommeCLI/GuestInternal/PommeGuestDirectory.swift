import Foundation
import OpenDirectory

/// Local user records and password verification through the OpenDirectory
/// API, so the host never spawns `dscl` in the guest. Records carry only the
/// attributes owner verification uses, each as its single string value.
struct PommeGuestDirectory: Sendable {
    static let readUsersOperation = "directory.localUsers.read"
    static let verifyPasswordOperation = "directory.password.verify"
    static let operations = [readUsersOperation, verifyPasswordOperation]
    static let attributes: [String: String] = [
        "RecordName": kODAttributeTypeRecordName,
        "RealName": kODAttributeTypeFullName,
        "GeneratedUID": kODAttributeTypeGUID,
        "UniqueID": kODAttributeTypeUniqueID,
        "NFSHomeDirectory": kODAttributeTypeNFSHomeDirectory,
    ]
    static let maximumUsers = 512
    static let maximumValueBytes = 1024

    typealias RecordReader = @Sendable () throws -> [[String: [String]]]
    typealias PasswordVerifier = @Sendable (String, String) throws -> Bool

    private let effectiveUserID: @Sendable () -> uid_t
    private let readRecords: RecordReader
    private let verify: PasswordVerifier

    init(
        effectiveUserID: @escaping @Sendable () -> uid_t = { geteuid() },
        readRecords: @escaping RecordReader = PommeGuestDirectory.liveRecords,
        verify: @escaping PasswordVerifier = PommeGuestDirectory.liveVerify
    ) {
        self.effectiveUserID = effectiveUserID
        self.readRecords = readRecords
        self.verify = verify
    }

    func perform(operation: String, payload: JSONValue) throws -> JSONValue {
        guard effectiveUserID() == 0 else {
            throw PommeAgentOperationError.described(.unsupported, message: "Directory access requires the root agent.")
        }
        switch operation {
        case Self.readUsersOperation:
            guard payload.objectValue?.isEmpty == true else { throw PommeAgentOperationError.invalid }
            return .object(["users": .array(try users().map(JSONValue.object))])
        case Self.verifyPasswordOperation:
            guard let values = payload.objectValue, Set(values.keys) == ["username", "password"],
                  let username = values["username"]?.stringValue, Self.isRecordName(username),
                  let password = values["password"]?.stringValue, !password.isEmpty,
                  password.utf8.count <= 1024 else { throw PommeAgentOperationError.invalid }
            return .object(["verified": .bool(try verify(username, password))])
        default:
            throw PommeAgentOperationError.unsupported
        }
    }

    /// Every local user record, keyed by the public attribute names, in the
    /// form `dscl` reports: the primary (first) record name, since system
    /// records carry aliases such as `BUILTIN\\Local System`, and any other
    /// multi-valued attribute joined by spaces for the host's strict parser
    /// to judge. An absent attribute is omitted; an oversized one is refused.
    func users() throws -> [[String: JSONValue]] {
        let records = try readRecords()
        guard records.count <= Self.maximumUsers else { throw PommeAgentOperationError.invalid }
        return try records.map { record in
            var user: [String: JSONValue] = [:]
            for (name, _) in Self.attributes {
                guard let values = record[name], !values.isEmpty else { continue }
                let value = name == "RecordName" ? values[0] : values.joined(separator: " ")
                guard value.utf8.count <= Self.maximumValueBytes, !value.contains("\0"),
                      !value.contains(where: \.isNewline)
                else { throw PommeAgentOperationError.invalid }
                user[name] = .string(value)
            }
            guard let name = user["RecordName"]?.stringValue, Self.isRecordName(name) else {
                throw PommeAgentOperationError.invalid
            }
            return user
        }
    }

    static func isRecordName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && !value.contains("\0") && !value.contains("/")
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    }

    static func liveRecords() throws -> [[String: [String]]] {
        let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
        let query = try ODQuery(node: node, forRecordTypes: kODRecordTypeUsers,
                                attribute: kODAttributeTypeRecordName, matchType: ODMatchType(kODMatchAny),
                                queryValues: nil, returnAttributes: Array(attributes.values),
                                maximumResults: maximumUsers + 1)
        guard let records = try query.resultsAllowingPartial(false) as? [ODRecord] else {
            throw PommeAgentOperationError.io
        }
        return try records.map { record in
            var values: [String: [String]] = [:]
            for (name, attribute) in attributes {
                // A missing attribute is reported by the framework as an error.
                guard let read = try? record.values(forAttribute: attribute) else { continue }
                guard let strings = read as? [String] else { throw PommeAgentOperationError.invalid }
                values[name] = strings
            }
            return values
        }
    }

    static func liveVerify(username: String, password: String) throws -> Bool {
        let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: username, attributes: nil)
        do {
            try record.verifyPassword(password)
            return true
        } catch let error as NSError where error.domain == ODFrameworkErrorDomain
            && error.code == Int(kODErrorCredentialsInvalid.rawValue) {
            // Only a definite credential rejection is "not verified"; any
            // other directory failure propagates as an error.
            return false
        }
    }
}
