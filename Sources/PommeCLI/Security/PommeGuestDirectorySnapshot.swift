import Foundation

/// Local users the guest agent read through OpenDirectory. Owner evidence
/// keeps one strict parser for both sources: this renders the exact `dscl`
/// forms it consumes, so a native read cannot relax any validation, and a
/// value the text form cannot carry faithfully fails closed.
struct PommeGuestDirectorySnapshot: Equatable, Sendable {
    static let attributes = ["RecordName", "RealName", "GeneratedUID", "UniqueID", "NFSHomeDirectory"]

    /// Attribute values by record name.
    let users: [String: [String: String]]

    init(users: [String: [String: String]]) { self.users = users }

    /// Decodes the agent's `directory.localUsers.read` result.
    init(result: Any) throws {
        guard let object = result as? [String: Any], Set(object.keys) == ["users"],
              let rawUsers = object["users"] as? [[String: Any]] else {
            throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers)
        }
        var users: [String: [String: String]] = [:]
        for raw in rawUsers {
            guard Set(raw.keys).isSubset(of: Self.attributes),
                  let values = raw as? [String: String],
                  let name = values["RecordName"], users[name] == nil,
                  values.values.allSatisfy({ !$0.contains(where: \.isNewline) && !$0.contains("\0") })
            else { throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers) }
            users[name] = values
        }
        guard !users.isEmpty else { throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUsers) }
        self.users = users
    }

    /// The output `dscl` would print for the read-only forms owner evidence
    /// uses. Any other form is refused rather than guessed.
    func dsclOutput(_ arguments: [String]) throws -> String {
        let names = users.keys.sorted()
        switch arguments {
        case [".", "-list", "/Users", "UniqueID"], [".", "-list", "/Users", "GeneratedUID"]:
            let attribute = arguments[3]
            return names.map { name in
                users[name]?[attribute].map { "\(name) \($0)" } ?? name
            }.joined(separator: "\n") + "\n"
        default:
            guard arguments.count >= 4, arguments[0] == ".", arguments[1] == "-read",
                  arguments[2].hasPrefix("/Users/"),
                  Set(arguments.dropFirst(3)).isSubset(of: Self.attributes),
                  let record = users[String(arguments[2].dropFirst("/Users/".count))] else {
                throw PommeSecurityOwnerPreparationError.malformedEvidence(.localUserRecord)
            }
            return arguments.dropFirst(3).compactMap { attribute in
                record[attribute].map { "\(attribute): \($0)" }
            }.joined(separator: "\n") + "\n"
        }
    }
}
