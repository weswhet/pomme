import Foundation

/// A coding key for reading whatever keys a keyed container holds, used by
/// every decoder here that checks a payload's exact key set.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Throws when the keyed value at `decoder` holds a key `allowed` does not
/// define, naming the dotted path and the keys that are recognized there.
func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(in decoder: any Decoder, allowed: Keys.Type) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let known = Set(Keys.allCases.map(\.stringValue))
    guard let unknown = container.allKeys.map(\.stringValue).filter({ !known.contains($0) }).sorted().first else {
        return
    }
    let path = (decoder.codingPath.map(\.stringValue) + [unknown]).joined(separator: ".")
    throw RunnerError.hostCommandFailed(
        "Config key '\(path)' is not recognized. Known keys: \(known.sorted().joined(separator: ", "))."
    )
}
