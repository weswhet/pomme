#!/usr/bin/env -S swift -suppress-warnings
// Export Pomme's Developer ID Application and Installer identities from the
// login keychain as one .p12, and give it to configure-release-secrets.sh,
// which stores it in the pomme-signing GitHub environment.
//
// Run it yourself in a terminal. macOS asks for your login keychain password
// once for each private key; choose Allow, never Always Allow, so that the
// Swift interpreter doesn't keep access to the keys.

import CryptoKit
import Darwin
import Foundation
import Security

// Print each line now, so that this script's output and the child's interleave
// in order.
setvbuf(stdout, nil, _IOLBF, 0)

let applicationIdentity = "Developer ID Application: Wesley Whetstone (2D8XQ77EBQ)"
let installerIdentity = "Developer ID Installer: Wesley Whetstone (2D8XQ77EBQ)"

func usage() -> String {
    """
    Usage: Scripts/export-signing-identities.swift [--list | --output FILE] [CONFIGURE_OPTIONS...]

    Finds the two Developer ID identities in the login keychain and exports
    them, with their private keys, as one password-protected .p12.

    By default, the script writes the .p12 to a private temporary directory,
    runs Scripts/configure-release-secrets.sh --p12 with it and a random
    password, and deletes it afterwards. It passes CONFIGURE_OPTIONS, such as
    --check-only, --skip-homebrew, or --repo OWNER/REPO, to that script.

      --list         Show the identities that the script would export, and
                     export nothing.
      --output FILE  Write the .p12 to FILE instead, and ask for its password.
                     FILE must not exist. Delete it when you're done with it.
    """
}

func fail(_ message: String, status: Int32 = 65) -> Never {
    FileHandle.standardError.write(Data("export-signing-identities: \(message)\n".utf8))
    exit(status)
}

func describe(_ status: OSStatus) -> String {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
}

// MARK: - Arguments

var listOnly = false
var outputPath: String?
var configureArguments: [String] = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--list":
        listOnly = true
    case "--output":
        guard let path = arguments.popFirst() else { fail(usage(), status: 64) }
        outputPath = path
    case "--help", "-h":
        print(usage())
        exit(0)
    case "--p12":
        fail("the script supplies --p12 itself.", status: 64)
    default:
        configureArguments.append(argument)
    }
}
if listOnly && outputPath != nil { fail("use either --list or --output.", status: 64) }
if outputPath != nil && !configureArguments.isEmpty {
    fail("--output doesn't run configure-release-secrets.sh, so it doesn't take \(configureArguments[0]).", status: 64)
}

// MARK: - Find the identities

let loginKeychainPath = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
var loginKeychain: SecKeychain?
var status = SecKeychainOpen(loginKeychainPath, &loginKeychain)
guard status == errSecSuccess, let loginKeychain else {
    fail("couldn't open the login keychain: \(describe(status))")
}

var found: CFTypeRef?
status = SecItemCopyMatching([
    kSecClass: kSecClassIdentity,
    kSecMatchSearchList: [loginKeychain],
    kSecMatchLimit: kSecMatchLimitAll,
    kSecReturnRef: true,
] as CFDictionary, &found)
guard status == errSecSuccess, let identities = found as? [SecIdentity] else {
    fail("couldn't list the login keychain's identities: \(describe(status))")
}

struct Candidate {
    let identity: SecIdentity
    let name: String
    let sha1: String
    let notAfter: Date
}

func candidate(_ identity: SecIdentity) -> Candidate? {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
          let name = SecCertificateCopySubjectSummary(certificate) as String?,
          name == applicationIdentity || name == installerIdentity else { return nil }
    let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil)
        as? [CFString: [CFString: Any]]
    guard let seconds = values?[kSecOIDX509V1ValidityNotAfter]?[kSecPropertyKeyValue] as? NSNumber else { return nil }
    let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
    return Candidate(identity: identity, name: name,
                     sha1: digest.map { String(format: "%02X", $0) }.joined(),
                     notAfter: Date(timeIntervalSinceReferenceDate: seconds.doubleValue))
}

let now = Date()
let candidates = identities.compactMap(candidate)
var chosen: [Candidate] = []
for name in [applicationIdentity, installerIdentity] {
    let matches = candidates.filter { $0.name == name }
    let valid = matches.filter { $0.notAfter > now }
    switch valid.count {
    case 1:
        chosen.append(valid[0])
    case 0 where matches.isEmpty:
        fail("the login keychain has no \(name) identity with its private key.")
    case 0:
        fail("every \(name) identity in the login keychain has expired. Renew it first.")
    default:
        let list = valid.map { "  \($0.sha1), expires \($0.notAfter)" }.joined(separator: "\n")
        fail("the login keychain has \(valid.count) valid \(name) identities:\n\(list)\nDelete the one you don't use, and run the script again.")
    }
}

for identity in chosen {
    print("Found \(identity.name)\n  SHA-1 \(identity.sha1), expires \(identity.notAfter.formatted(date: .abbreviated, time: .omitted))")
}
if listOnly { exit(0) }

// MARK: - Export

func readPassword(_ prompt: String) -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
        fail("couldn't read a password from the terminal.")
    }
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    return String(cString: buffer)
}

let password: String
if outputPath != nil {
    let first = readPassword("Password for the .p12: ")
    guard first.count >= 12 else { fail("use a password of at least 12 characters.", status: 64) }
    guard readPassword("Password again: ") == first else { fail("the passwords don't match.", status: 64) }
    password = first
} else {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        fail("couldn't generate a password.")
    }
    password = Data(bytes).base64EncodedString()
}

print("Exporting. macOS asks for your login keychain password for each private key; choose Allow.")
let passphrase = password as CFString
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.passphrase = Unmanaged.passUnretained(passphrase)
var exported: CFData?
status = withExtendedLifetime(passphrase) {
    SecItemExport(chosen.map(\.identity) as CFArray, .formatPKCS12, [], &parameters, &exported)
}
guard status == errSecSuccess, let exported else {
    fail("couldn't export the identities: \(describe(status))")
}
let p12 = exported as Data

// Write the file so that only you can read it, and refuse to replace anything.
func writePrivately(_ data: Data, to path: String) {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { fail("couldn't create \(path): \(String(cString: strerror(errno)))") }
    let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == data.count, fsync(descriptor) == 0, close(descriptor) == 0 else {
        unlink(path)
        fail("couldn't write \(path).")
    }
}

if let outputPath {
    writePrivately(p12, to: outputPath)
    print("""
    Wrote \(outputPath). To store it in GitHub, run:
      bash Scripts/configure-release-secrets.sh --p12 \(outputPath)
    Then delete \(outputPath).
    """)
    exit(0)
}

// MARK: - Hand off to configure-release-secrets.sh

let configureScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("configure-release-secrets.sh").path
guard FileManager.default.isReadableFile(atPath: configureScript) else {
    fail("couldn't find \(configureScript).")
}

var template = Array((NSTemporaryDirectory() + "pomme-signing.XXXXXX").utf8CString)
guard let directoryPointer = mkdtemp(&template) else { fail("couldn't create a private temporary directory.") }
let directory = String(cString: directoryPointer)
let p12Path = directory + "/developer-id.p12"
func cleanUp() {
    unlink(p12Path)
    rmdir(directory)
}
writePrivately(p12, to: p12Path)

// Ignore Ctrl-C here, so that the file is deleted after the child stops. The
// child gets the default handling back.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var attributes: posix_spawnattr_t?
posix_spawnattr_init(&attributes)
var defaults = sigset_t()
sigemptyset(&defaults)
sigaddset(&defaults, SIGINT)
sigaddset(&defaults, SIGTERM)
posix_spawnattr_setsigdefault(&attributes, &defaults)
posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

var environment = ProcessInfo.processInfo.environment
environment["DEVELOPER_ID_CERTIFICATE_PASSWORD"] = password
let argv = ["/bin/bash", configureScript, "--p12", p12Path] + configureArguments
let envp = environment.map { "\($0.key)=\($0.value)" }
var cArgv = argv.map { strdup($0) } + [nil]
var cEnvp = envp.map { strdup($0) } + [nil]
var pid: pid_t = 0
let spawned = posix_spawn(&pid, "/bin/bash", nil, &attributes, &cArgv, &cEnvp)
posix_spawnattr_destroy(&attributes)
(cArgv + cEnvp).forEach { free($0) }
guard spawned == 0 else {
    cleanUp()
    fail("couldn't run configure-release-secrets.sh: \(String(cString: strerror(spawned)))")
}

var waitStatus: Int32 = 0
while waitpid(pid, &waitStatus, 0) < 0 && errno == EINTR {}
cleanUp()
print("Deleted the temporary .p12.")
let exitStatus = waitStatus & 0x7f == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
exit(exitStatus)
