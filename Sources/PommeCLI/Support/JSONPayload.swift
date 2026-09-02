import Foundation

struct QueueConfined<Value>: @unchecked Sendable {
    let value: Value
}

struct JSONPayload: @unchecked Sendable {
    let object: [String: Any]

    init(_ object: [String: Any]) {
        self.object = object
    }
}
