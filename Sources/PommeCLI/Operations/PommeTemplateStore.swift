import Foundation

/// Describes an installed-but-unprovisioned macOS image kept under
/// `Templates/<name>.bundle`. A template holds only the restored `Disk.img`,
/// its `AuxiliaryStorage`, and `HardwareModel`; every VM created from it
/// clones those files (APFS copy-on-write) and then runs the ordinary
/// Recovery bootstrap with a machine identifier and UUID of its own.
struct PommeTemplateManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let name: String
    let version: String
    let build: String
    /// SHA-256 of the restore image the template was installed from. VMs
    /// created from the template record it as their plan's restore digest.
    let restoreImageDigest: String
    let restoreImagePath: String
    let diskSizeBytes: UInt64
    let createdAt: Date
    /// Present when the template was captured with an owner account already
    /// prepared, so VMs cloned from it can reach an owner-authenticated
    /// workflow such as MDM enrollment without creating one first. The
    /// password is deliberately absent: a clone recovers it from its own
    /// automatic-login configuration. Absent on installed-only templates.
    let provisionedOwnerAccount: String?
    /// True when the capture was taken with System Integrity Protection
    /// disabled and the AMFI override active, so a clone can run an
    /// owner-authenticated workflow without any security mutation. Every VM
    /// cloned from such a template inherits that posture.
    let provisionedSecurityDisabled: Bool?

    init(
        name: String,
        version: String,
        build: String,
        restoreImageDigest: String,
        restoreImagePath: String,
        diskSizeBytes: UInt64,
        createdAt: Date = Date(),
        provisionedOwnerAccount: String? = nil,
        provisionedSecurityDisabled: Bool? = nil
    ) {
        schema = Self.schemaVersion
        self.name = name
        self.version = version
        self.build = build
        self.restoreImageDigest = restoreImageDigest
        self.restoreImagePath = restoreImagePath
        self.diskSizeBytes = diskSizeBytes
        self.createdAt = createdAt
        self.provisionedOwnerAccount = provisionedOwnerAccount
        self.provisionedSecurityDisabled = provisionedSecurityDisabled
    }

    var isProvisioned: Bool { provisionedOwnerAccount != nil }
    /// True only for a capture taken with SIP disabled and the AMFI override
    /// active. Absent in manifests written before that was recorded.
    var isSecurityDisabled: Bool { provisionedSecurityDisabled == true }

    func validate() throws {
        guard schema == Self.schemaVersion,
              !name.isEmpty, !version.isEmpty, !build.isEmpty,
              PommeProvisioningDigest.isSHA256(restoreImageDigest),
              diskSizeBytes > 0,
              provisionedOwnerAccount.map(
                PommeGuestOwnerCredentialReader.isSafeAccount) ?? true
        else { throw PommeTemplateError.invalidManifest }
    }
}

enum PommeTemplateError: Error, Equatable, PommeDescribedError {
    case invalidManifest
    case notFound(String)
    case alreadyExists(String)
    case incompleteBundle(String)
    case diskSizeMismatch(template: UInt64, requested: UInt64)
    /// Copying a template file into a VM bundle failed. `cause` keeps the
    /// file-system reason, such as a full disk.
    case cloneFailed(cause: PommeErrorReport)

    var code: PommeErrorCode {
        switch self {
        case .invalidManifest: .templateManifestInvalid
        case .notFound: .templateNotFound
        case .alreadyExists: .templateExists
        case .incompleteBundle: .templateIncomplete
        case .diskSizeMismatch: .templateDiskSizeMismatch
        case .cloneFailed: .templateCloneFailed
        }
    }

    var underlying: (any Error)? {
        if case .cloneFailed(let cause) = self { return cause }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return "The template manifest is missing or malformed."
        case .notFound(let name):
            return "No template named \(name) exists. Create it with `pomme template create \(name) --latest` or run `pomme template list`."
        case .alreadyExists(let name):
            return "A template named \(name) already exists. Delete it before creating a replacement."
        case .incompleteBundle(let name):
            return "Template \(name) is missing its disk image, auxiliary storage, or hardware model."
        case .diskSizeMismatch(let template, let requested):
            return "The template disk is \(byteCountText(template)), and --disk-size asks for \(byteCountText(requested)). A VM cloned from a template keeps the template's disk size."
        case .cloneFailed(let cause):
            return "Cloning the template failed: \(PommeErrorDescriber.clause(for: cause))."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidManifest, .incompleteBundle:
            return "Delete the template with `pomme template delete NAME`, then create it again with `pomme template create NAME`."
        case .notFound:
            return nil
        case .alreadyExists(let name):
            return "Run `pomme template delete \(name)`, then retry."
        case .diskSizeMismatch:
            return "Omit --disk-size to use the template's size."
        case .cloneFailed(let cause):
            return cause.hint
        }
    }
}

enum PommeTemplateStore {
    static let directoryName = "Templates"
    static let manifestName = "Template.json"

    static func directory(create: Bool = true) throws -> URL {
        let url = try applicationSupportRoot(create: create)
            .appendingPathComponent(directoryName, isDirectory: true)
        if create, !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return url
    }

    static func bundle(for name: String) throws -> BundleLayout {
        let validName = try validateIdentifier(name, kind: .template)
        return BundleLayout(rootURL: try directory().appendingPathComponent("\(validName).bundle", isDirectory: true))
    }

    static func manifestURL(for bundle: BundleLayout) -> URL {
        bundle.rootURL.appendingPathComponent(manifestName)
    }

    static func manifest(for name: String) throws -> PommeTemplateManifest {
        let bundle = try bundle(for: name)
        guard FileManager.default.fileExists(atPath: bundle.rootURL.path) else {
            throw PommeTemplateError.notFound(name)
        }
        return try manifest(in: bundle)
    }

    static func manifest(in bundle: BundleLayout) throws -> PommeTemplateManifest {
        guard let data = try? Data(contentsOf: manifestURL(for: bundle)),
              let manifest = try? decoder().decode(PommeTemplateManifest.self, from: data)
        else { throw PommeTemplateError.invalidManifest }
        try manifest.validate()
        for url in [bundle.diskImageURL, bundle.auxiliaryStorageURL, bundle.hardwareModelURL]
        where !FileManager.default.fileExists(atPath: url.path) {
            throw PommeTemplateError.incompleteBundle(manifest.name)
        }
        return manifest
    }

    static func write(_ manifest: PommeTemplateManifest, to bundle: BundleLayout) throws {
        try manifest.validate()
        let data = try encoder().encode(manifest)
        try data.write(to: manifestURL(for: bundle), options: .atomic)
    }

    static func list() throws -> [PommeTemplateManifest] {
        let directory = try directory(create: false)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "bundle" }
            .compactMap { try? manifest(in: BundleLayout(rootURL: $0)) }
            .sorted { $0.name < $1.name }
    }

    static func delete(name: String) throws -> URL {
        let bundle = try bundle(for: name)
        guard FileManager.default.fileExists(atPath: bundle.rootURL.path) else {
            throw PommeTemplateError.notFound(name)
        }
        try FileManager.default.removeItem(at: bundle.rootURL)
        return bundle.rootURL
    }

    /// Copy-on-write clone of one template file into a VM bundle. APFS
    /// `clonefile(2)` shares the blocks, so a 20 GB image clones in
    /// milliseconds; other filesystems fall back to a plain copy.
    static func clone(_ source: URL, to destination: URL) throws {
        if Darwin.clonefile(source.path, destination.path, 0) == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EXDEV else {
            throw PommeTemplateError.cloneFailed(cause: PommeErrorReport(
                keepingSystemCause: NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            ))
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw PommeTemplateError.cloneFailed(cause: PommeErrorReport(keepingSystemCause: error))
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
