import Foundation
import Security
import Darwin

func readSecureLine(prompt: String) -> String? {
    guard isatty(STDIN_FILENO) == 1 else {
        return nil
    }

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
        return nil
    }
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
        return nil
    }
    defer {
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        fputs("\n", stderr)
    }

    fputs(prompt, stderr)
    fflush(stderr)
    return readLine()?.trimmingCharacters(in: .newlines)
}

func stableIdentifier(for value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return lowercaseHexString(hash, width: 16)
}

func throwPOSIX(_ function: String) throws -> Never {
    throw RunnerError.posix(function: function, code: errno)
}

func withUnixSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    let pathLength = path.utf8.count
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathLength < pathCapacity else {
        throw RunnerError.socketPathTooLong(path)
    }

    address.sun_family = sa_family_t(AF_UNIX)
    let length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + pathLength + 1)
    address.sun_len = UInt8(length)

    withUnsafeMutableBytes(of: &address.sun_path) { pathBuffer in
        memset(pathBuffer.baseAddress, 0, pathBuffer.count)
        _ = path.withCString { cPath in
            memcpy(pathBuffer.baseAddress, cPath, pathLength)
        }
    }

    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            try body(socketAddress, length)
        }
    }
}

func readString(from fd: Int32) throws -> String {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)

    while true {
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        if count > 0 {
            data.append(contentsOf: buffer.prefix(count))
            if data.contains(0x0A) {
                break
            }
        } else if count == 0 {
            break
        } else if errno != EINTR {
            try throwPOSIX("read")
        }
    }

    return String(data: data, encoding: .utf8) ?? ""
}

func writeString(_ text: String, to fd: Int32) throws {
    let bytes = Array(text.utf8)
    try bytes.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                try throwPOSIX("write")
            }
        }
    }
}

func parseJSONObject(from text: String) throws -> [String: Any] {
    guard let data = text.data(using: .utf8) else {
        throw RunnerError.invalidControlResponse(text)
    }
    let value = try JSONSerialization.jsonObject(with: data)
    guard let object = value as? [String: Any] else {
        throw RunnerError.invalidControlResponse(text)
    }
    return object
}

func jsonLine(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [])
    guard let text = String(data: data, encoding: .utf8) else {
        throw RunnerError.invalidControlResponse(String(describing: object))
    }
    return "\(text)\n"
}

func integerValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
        return value
    }
    if let value = value as? NSNumber {
        return value.intValue
    }
    if let value = value as? String {
        return Int(value)
    }
    return nil
}

func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value
    }
    if let value = value as? NSNumber {
        return value.doubleValue
    }
    if let value = value as? String {
        return Double(value)
    }
    return nil
}

func uint64Value(_ value: Any?) -> UInt64? {
    if let value = value as? UInt64 {
        return value
    }
    if let value = value as? Int, value >= 0 {
        return UInt64(value)
    }
    if let value = value as? Int64, value >= 0 {
        return UInt64(value)
    }
    if let value = value as? NSNumber, value.int64Value >= 0 {
        return UInt64(value.int64Value)
    }
    if let value = value as? String {
        return ByteSizeParser.parse(value)
    }
    return nil
}

func byteCountText(_ bytes: UInt64) -> String {
    guard bytes <= UInt64(Int64.max) else {
        return "\(bytes) bytes"
    }
    return Int64(bytes).formatted(.byteCount(style: .file))
}

func boolFromAny(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
        return value
    }
    if let value = value as? NSNumber {
        return value.boolValue
    }
    if let value = value as? String {
        return (value as NSString).boolValue
    }
    return nil
}

func keyValueLinesPayload(_ text: String) -> [String: String] {
    var payload: [String: String] = [:]
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let separator = line.firstIndex(of: "=") else {
            continue
        }
        let key = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        payload[key] = value
    }
    return payload
}

func validateGuestAccountName(_ value: String, flag: String) throws -> String {
    guard !value.isEmpty, value.count <= 64 else {
        throw RunnerError.invalidSIPBootstrapConfiguration("\(flag) requires a 1-64 character guest short name.")
    }
    let allowedPunctuation: Set<Character> = [".", "_", "-"]
    for (index, character) in value.enumerated() {
        let isAlphanumeric = character.isASCII && (character.isLetter || character.isNumber)
        if index == 0 {
            guard character.isASCII && character.isLetter else {
                throw RunnerError.invalidSIPBootstrapConfiguration("\(flag) must start with an ASCII letter.")
            }
        } else {
            guard isAlphanumeric || allowedPunctuation.contains(character) else {
                throw RunnerError.invalidSIPBootstrapConfiguration("\(flag) contains unsupported character \(character). Use ASCII letters, numbers, dots, underscores, or hyphens.")
            }
        }
    }
    return value
}

func vmUUID(from metadata: [String: Any]) -> String? {
    guard let rawValue = metadata[Constants.vmUUIDMetadataKey] as? String,
          UUID(uuidString: rawValue) != nil
    else {
        return nil
    }
    return rawValue.lowercased()
}

func vmUUID(for bundle: BundleLayout) -> String? {
    guard let metadata = try? metadataPayload(bundle: bundle) else {
        return nil
    }
    return vmUUID(from: metadata)
}

/// Returns the one host Keychain service used by Pomme for a VM identity.
/// The VM UUID is part of the service name so credentials cannot collide
/// across Pomme-owned VM bundles.
func pommeCredentialService(forUUID uuid: String) -> String {
    "\(Constants.credentialServicePrefix).\(uuid.lowercased())"
}

/// Resolves the canonical service for an already-identified VM. Pomme does
/// not derive a service from a bundle path or probe alternate namespaces.
func pommeCredentialService(for reference: VMReference) throws -> String {
    guard let uuid = vmUUID(for: reference.bundle) else {
        throw RunnerError.sipCredentialUnavailable(
            "Pomme VM metadata does not contain a valid immutable VM UUID."
        )
    }
    return pommeCredentialService(forUUID: uuid)
}

func writeMetadataPayload(_ metadata: [String: Any], bundle: BundleLayout) throws {
    let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: bundle.metadataURL)
}

func ensureVMUUID(for bundle: BundleLayout) throws -> String {
    var metadata = try metadataPayload(bundle: bundle)
    if let uuid = vmUUID(from: metadata) {
        return uuid
    }
    let uuid = UUID().uuidString.lowercased()
    metadata[Constants.vmUUIDMetadataKey] = uuid
    try writeMetadataPayload(metadata, bundle: bundle)
    return uuid
}

func ensurePommeCredentialService(for reference: VMReference) throws -> String {
    pommeCredentialService(forUUID: try ensureVMUUID(for: reference.bundle))
}

let kcpasswordKeyBytes: [UInt8] = [0x7d, 0x89, 0x52, 0x23, 0xd2, 0xbc, 0xdd, 0xea, 0xa3, 0xb9, 0x1f]

func kcpasswordData(for password: String) -> Data {
    var bytes = Array(password.utf8)
    let remainder = bytes.count % kcpasswordKeyBytes.count
    if remainder != 0 {
        bytes.append(contentsOf: repeatElement(0, count: kcpasswordKeyBytes.count - remainder))
    }
    for index in bytes.indices {
        bytes[index] ^= kcpasswordKeyBytes[index % kcpasswordKeyBytes.count]
    }
    return Data(bytes)
}

func kcpasswordString(from data: Data) -> String? {
    guard !data.isEmpty else {
        return ""
    }
    var bytes = Array(data)
    for index in bytes.indices {
        bytes[index] ^= kcpasswordKeyBytes[index % kcpasswordKeyBytes.count]
    }
    // Apple's autologin file may contain nonzero padding after the C-string
    // terminator. Padding is not password data and need not be valid UTF-8.
    return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
}

func kcpasswordString(at path: String) throws -> String? {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }
    let data = try Data(contentsOf: url)
    return kcpasswordString(from: data)
}

func securityErrorMessage(_ status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) as String? {
        return message
    }
    return "OSStatus \(status)"
}

enum HostKeychainUnlockPolicy {
    case allowTTYPrompt
    case disallowTTYPrompt
}

struct HostKeychainOpenResult {
    let keychain: SecKeychain
    let path: String
    let unlockSource: String
}

func defaultLoginKeychainPath() -> String {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Keychains/login.keychain-db")
        .path
}

func resolvedHostKeychainPath(_ path: String?) -> String {
    guard let path, !path.isEmpty else {
        return defaultLoginKeychainPath()
    }
    return path
}

func hostKeychainPathIsDefaultLogin(_ path: String) -> Bool {
    URL(fileURLWithPath: path).standardizedFileURL.path == URL(fileURLWithPath: defaultLoginKeychainPath()).standardizedFileURL.path
}

func openHostKeychainResult(
    path: String?,
    unlockPolicy: HostKeychainUnlockPolicy = .allowTTYPrompt
) throws -> HostKeychainOpenResult {
    let resolvedPath = resolvedHostKeychainPath(path)
    var keychain: SecKeychain?
    let status = SecKeychainOpen(resolvedPath, &keychain)
    guard status == errSecSuccess, let keychain else {
        throw RunnerError.keychainError("Could not open \(resolvedPath): \(securityErrorMessage(status))")
    }
    let unlockSource = try ensureHostKeychainUnlocked(keychain, path: resolvedPath, unlockPolicy: unlockPolicy)
    return HostKeychainOpenResult(keychain: keychain, path: resolvedPath, unlockSource: unlockSource)
}

func openHostKeychain(path: String?) throws -> SecKeychain {
    try openHostKeychainResult(path: path).keychain
}

func hostKeychainIsUnlocked(_ keychain: SecKeychain) throws -> Bool {
    var status: SecKeychainStatus = 0
    let result = SecKeychainGetStatus(keychain, &status)
    guard result == errSecSuccess else {
        throw RunnerError.keychainError("Could not read keychain lock state: \(securityErrorMessage(result))")
    }
    return (status & UInt32(kSecUnlockStateStatus)) != 0
}

func ensureHostKeychainUnlocked(
    _ keychain: SecKeychain,
    path: String,
    unlockPolicy: HostKeychainUnlockPolicy
) throws -> String {
    if try hostKeychainIsUnlocked(keychain) {
        return "alreadyUnlocked"
    }

    var hostKCPasswordError: String?
    if hostKeychainPathIsDefaultLogin(path) {
        do {
            if let password = try kcpasswordString(at: "/etc/kcpassword"), !password.isEmpty {
                let passwordBytes = Array(password.utf8)
                let unlockStatus = passwordBytes.withUnsafeBytes { buffer in
                    SecKeychainUnlock(keychain, UInt32(buffer.count), buffer.baseAddress, true)
                }
                if unlockStatus == errSecSuccess, try hostKeychainIsUnlocked(keychain) {
                    return "hostKCPassword"
                }
                hostKCPasswordError = "host /etc/kcpassword did not unlock the login keychain: \(securityErrorMessage(unlockStatus))"
            } else {
                hostKCPasswordError = "host /etc/kcpassword is not available"
            }
        } catch {
            hostKCPasswordError = "could not read host /etc/kcpassword: \(error.localizedDescription)"
        }
    }

    guard unlockPolicy == .allowTTYPrompt else {
        var message = "Keychain \(path) is locked and cannot be unlocked non-interactively."
        if let hostKCPasswordError {
            message += " \(hostKCPasswordError)."
        }
        throw RunnerError.keychainError(message)
    }

    let password = try readSecretFromTTY(
        prompt: "Password to unlock keychain \(path): ",
        unavailableMessage: "Keychain \(path) is locked and no interactive terminal is available. Unlock the keychain and retry."
    )
    let passwordBytes = Array(password.utf8)
    let unlockStatus: OSStatus
    if passwordBytes.isEmpty {
        unlockStatus = SecKeychainUnlock(keychain, 0, nil, true)
    } else {
        unlockStatus = passwordBytes.withUnsafeBytes { buffer in
            SecKeychainUnlock(keychain, UInt32(buffer.count), buffer.baseAddress, true)
        }
    }
    guard unlockStatus == errSecSuccess else {
        throw RunnerError.keychainError("Could not unlock keychain \(path): \(securityErrorMessage(unlockStatus))")
    }
    guard try hostKeychainIsUnlocked(keychain) else {
        throw RunnerError.keychainError("Keychain \(path) is still locked after unlock.")
    }
    return "tty"
}

func readSecretFromTTY(prompt: String, unavailableMessage: String) throws -> String {
    let fd = Darwin.open("/dev/tty", O_RDWR)
    guard fd >= 0 else {
        throw RunnerError.keychainError(unavailableMessage)
    }
    defer {
        Darwin.close(fd)
    }

    try writeString(prompt, to: fd)

    var original = termios()
    guard tcgetattr(fd, &original) == 0 else {
        try throwPOSIX("tcgetattr")
    }
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(fd, TCSANOW, &hidden) == 0 else {
        try throwPOSIX("tcsetattr")
    }
    defer {
        _ = tcsetattr(fd, TCSANOW, &original)
        _ = try? writeString("\n", to: fd)
    }

    return stringByRemovingTrailingNewlines(try readString(from: fd))
}

func stringByRemovingTrailingNewlines(_ value: String) -> String {
    var value = value
    while value.last == "\n" || value.last == "\r" {
        value.removeLast()
    }
    return value
}

// pomme stores VM credentials in the host keychain selected by the user, including
// file-based login/custom keychains. Do not route these queries to the macOS data
// protection keychain; explicit SecKeychain targeting is the required behavior here.
func hostKeychainQuery(service: String, account: String, keychain: SecKeychain) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecUseKeychain as String: keychain,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
    ]
}

func hostKeychainLookupQuery(service: String, account: String?, keychain: SecKeychain) -> [String: Any] {
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecMatchSearchList as String: [keychain],
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
    ]
    if let account {
        query[kSecAttrAccount as String] = account
    }
    return query
}

func findHostKeychainPassword(
    service: String,
    account: String,
    keychainPath: String?,
    unlockPolicy: HostKeychainUnlockPolicy = .allowTTYPrompt
) throws -> String? {
    let keychain = try openHostKeychainResult(path: keychainPath, unlockPolicy: unlockPolicy).keychain
    var query = hostKeychainLookupQuery(service: service, account: account, keychain: keychain)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
        return nil
    }
    guard status == errSecSuccess else {
        throw RunnerError.keychainError("Could not read credential \(service)/\(account): \(securityErrorMessage(status))")
    }
    guard let data = item as? Data else {
        throw RunnerError.keychainError("Could not read credential \(service)/\(account): keychain item data was not returned.")
    }
    return String(data: data, encoding: .utf8)
}

func findHostKeychainCredential(
    service: String,
    keychainPath: String?,
    unlockPolicy: HostKeychainUnlockPolicy = .allowTTYPrompt
) throws -> (service: String, account: String, password: String)? {
    let keychain = try openHostKeychainResult(path: keychainPath, unlockPolicy: unlockPolicy).keychain
    var query = hostKeychainLookupQuery(service: service, account: nil, keychain: keychain)
    query[kSecReturnAttributes as String] = true
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
        return nil
    }
    guard status == errSecSuccess else {
        throw RunnerError.keychainError("Could not read credential for \(service): \(securityErrorMessage(status))")
    }
    guard let dictionary = item as? [String: Any],
          let account = dictionary[kSecAttrAccount as String] as? String,
          let data = dictionary[kSecValueData as String] as? Data,
          let password = String(data: data, encoding: .utf8)
    else {
        throw RunnerError.keychainError("Could not read credential for \(service): keychain item account or data was not returned.")
    }
    query.removeAll(keepingCapacity: false)
    return (service: service, account: account, password: password)
}

@discardableResult
func storeHostKeychainPassword(
    service: String,
    account: String,
    password: String,
    keychainPath: String?,
    unlockPolicy: HostKeychainUnlockPolicy = .allowTTYPrompt
) throws -> HostKeychainOpenResult {
    let openResult = try openHostKeychainResult(path: keychainPath, unlockPolicy: unlockPolicy)
    let keychain = openResult.keychain
    let passwordData = Data(password.utf8)
    var addQuery = hostKeychainQuery(service: service, account: account, keychain: keychain)
    addQuery[kSecValueData as String] = passwordData
    addQuery[kSecAttrLabel as String] = "pomme guest credential: \(account)"

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecSuccess {
        return openResult
    }
    guard status == errSecDuplicateItem else {
        throw RunnerError.keychainError("Could not store credential \(service)/\(account): \(securityErrorMessage(status))")
    }

    // SecItemUpdate targets an existing item through a search list. kSecUseKeychain
    // is the add-item selector and can yield errSecItemNotFound after SecItemAdd
    // has already reported the item as a duplicate in a custom file keychain.
    let updateQuery = hostKeychainLookupQuery(service: service, account: account, keychain: keychain)
    let updateAttributes: [String: Any] = [
        kSecValueData as String: passwordData,
        kSecAttrLabel as String: "pomme guest credential: \(account)"
    ]
    let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
    guard updateStatus == errSecSuccess else {
        throw RunnerError.keychainError("Could not update credential \(service)/\(account): \(securityErrorMessage(updateStatus))")
    }
    return openResult
}

func generateSIPBootstrapPassword() throws -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
        throw RunnerError.keychainError("Could not generate a bootstrap password: \(securityErrorMessage(status))")
    }
    return String(bytes.map { alphabet[Int($0) % alphabet.count] })
}

func metadataPayload(bundle: BundleLayout) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: bundle.metadataURL.path) else {
        return [:]
    }
    let data = try Data(contentsOf: bundle.metadataURL)
    return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func sizeOptionsPayload(from metadata: [String: Any]) -> VMSizeOptions {
    VMSizeOptions(
        memorySizeBytes: uint64Value(metadata["memorySize"]) ?? Constants.defaultMemorySizeBytes,
        diskSizeBytes: uint64Value(metadata["diskSize"]) ?? Constants.defaultDiskSizeBytes
    )
}

func sizeOptions(for bundle: BundleLayout) -> VMSizeOptions {
    guard let metadata = try? metadataPayload(bundle: bundle) else {
        return .default
    }
    return sizeOptionsPayload(from: metadata)
}

func applicationSupportRoot(create: Bool = true) throws -> URL {
    let rootURL: URL
    if let override = ProcessInfo.processInfo.environment["POMME_APP_SUPPORT_DIR"], !override.isEmpty {
        rootURL = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    } else {
        rootURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(Constants.appSupportDirectoryName, isDirectory: true)
    }

    if create {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
    return rootURL
}

func vmStoreDirectory(create: Bool = true) throws -> URL {
    let directoryURL = try applicationSupportRoot(create: create)
        .appendingPathComponent(Constants.vmDirectoryName, isDirectory: true)
    if create {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
    return directoryURL
}

func configStoreDirectory(create: Bool = true) throws -> URL {
    let directoryURL = try applicationSupportRoot(create: create)
        .appendingPathComponent(Constants.configDirectoryName, isDirectory: true)
    if create {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
    return directoryURL
}

func runtimeDirectory(create: Bool = true) throws -> URL {
    let directoryURL = try applicationSupportRoot(create: create)
        .appendingPathComponent(Constants.runtimeDirectoryName, isDirectory: true)
    if create {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
    return directoryURL
}

/// The identifiers that share the managed-name character rules. The kind
/// only changes how a rejection is worded, so an operator who typed a valid
/// VM name and an invalid snapshot name is told about the snapshot name.
enum PommeIdentifierKind: String, Sendable {
    case vm = "VM name"
    case snapshot = "snapshot name"
    case template = "template name"
    case configDerived = "config-derived VM name"
}

func validateVMName(_ name: String) throws -> String {
    try validateIdentifier(name, kind: .vm)
}

func validateIdentifier(_ name: String, kind: PommeIdentifierKind) throws -> String {
    guard !name.isEmpty, name.count <= 64 else {
        throw RunnerError.invalidIdentifier(kind: kind, value: name)
    }

    let allowedPunctuation: Set<Character> = [".", "_", "-"]
    for (index, character) in name.enumerated() {
        let isAlphanumeric = character.isASCII && (character.isLetter || character.isNumber)
        if index == 0 {
            guard isAlphanumeric else {
                throw RunnerError.invalidIdentifier(kind: kind, value: name)
            }
        } else {
            guard isAlphanumeric || allowedPunctuation.contains(character) else {
                throw RunnerError.invalidIdentifier(kind: kind, value: name)
            }
        }
    }

    return name
}

func namedBundleURL(for name: String) throws -> URL {
    try vmStoreDirectory()
        .appendingPathComponent(name, isDirectory: true)
        .appendingPathExtension("bundle")
}

func namedVMReference(_ name: String, requireExists: Bool) throws -> VMReference {
    let validName = try validateVMName(name)
    let bundle = BundleLayout(rootURL: try namedBundleURL(for: validName))
    if requireExists, !FileManager.default.fileExists(atPath: bundle.rootURL.path) {
        throw RunnerError.namedVMNotFound(validName)
    }
    return VMReference(name: validName, bundle: bundle)
}

func vmReferenceListText(_ references: [VMReference]) -> String {
    references
        .map { reference in
            if let name = reference.name {
                return "\(name) (\(reference.bundle.rootURL.path))"
            }
            return reference.bundle.rootURL.path
        }
        .joined(separator: ", ")
}

struct HostProcessCapture: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

func runHostProcessCapturing(
    _ executable: String,
    arguments: [String],
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil
) throws -> HostProcessCapture {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    if let environment {
        process.environment = environment
    }

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return HostProcessCapture(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

func codeSignatureIsValid(at url: URL) -> Bool {
    guard let capture = try? runHostProcessCapturing("/usr/bin/codesign", arguments: ["-vv", url.path]) else {
        return false
    }
    return capture.status == 0
}
