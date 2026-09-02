import Foundation
import Testing

@Suite("JSON value type preservation")
struct JSONValueTests {
    @Test("NSNumber integers do not bridge to booleans")
    func integerNSNumber() throws {
        #expect(try JSONValue(any: NSNumber(value: 0)) == .integer(0))
        #expect(try JSONValue(any: NSNumber(value: 1)) == .integer(1))
    }

    @Test("CFBoolean values remain booleans")
    func booleanNSNumber() throws {
        #expect(try JSONValue(any: NSNumber(value: false)) == .bool(false))
        #expect(try JSONValue(any: NSNumber(value: true)) == .bool(true))
    }
}
