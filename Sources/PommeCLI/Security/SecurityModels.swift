import Foundation

enum SIPAction: String, CaseIterable, Codable, Sendable {
    case status
    case disable
    case enable
}
enum AMFIAction: String, CaseIterable, Codable, Sendable {
    case status
    case disable
    case enable
}

enum PrivateXPCSecurityAction: String, CaseIterable, Codable, Sendable {
    case status
    case prepare
}

struct SIPBootstrapOptions: Sendable {
    var enabled = false
    var user: String?
    var password: String?
    var fullName: String?
    var authorizerUser: String?
    var authorizerPassword: String?
    var keychainPath: String?
}

struct SIPCredentialResolution: @unchecked Sendable {
    let user: String
    let password: String
    let source: String
    let keychainService: String
    let keychainAccount: String
    let bootstrapPayload: [String: Any]?
}

struct StartupDiskCredential: Sendable {
    let user: String
    let password: String
    let source: String
}

struct GuestKCPasswordCredential: @unchecked Sendable {
    let user: String
    let password: String
    let payload: [String: Any]
}
