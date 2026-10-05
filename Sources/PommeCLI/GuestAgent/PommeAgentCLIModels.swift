import CoreFoundation
import Darwin
import Foundation

/// Limits shared by the CLI-facing request models and PommeAgentProtocol.
///
/// A request is allowed to carry one stream-sized stdin chunk. Larger input is
/// sent with authenticated stream frames by the operation layer. File reads
/// and writes are kept at the smaller file-operation limit.
enum PommeAgentCLIModelLimits {
    static let maximumFrameBytes = PommeAgentProtocol.maximumFrameBytes
    static let maximumStreamChunkBytes = PommeAgentProtocol.maximumStreamChunkBytes
    static let maximumFileChunkBytes = PommeAgentProtocol.maximumFileChunkBytes
    static let maximumPathBytes = 4 * 1024
    static let maximumArgumentBytes = 64 * 1024
    static let maximumArgumentCount = 1024
}

private enum PommeAgentCLIModelSupport {
    static let agentCommand = "agent.perform"

    static func controlPayload(operation: String, payload: [String: Any]) -> [String: Any] {
        [
            "command": agentCommand,
            "operation": operation,
            "payload": payload
        ]
    }

    static func operation(from object: [String: Any], expected: String) throws -> [String: Any] {
        let command = object["command"] as? String
        let operation = object["operation"] as? String
        guard Set(object.keys).isSubset(of: ["command", "operation", "payload"]),
              command == agentCommand, operation == expected,
              let payload = object["payload"] as? [String: Any]
        else {
            throw RunnerError.invalidControlCommand(String(describing: command ?? operation ?? ""))
        }
        return payload
    }

    static func exactKeys(_ object: [String: Any], allowed: Set<String>, error: String) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw RunnerError.invalidGuestCommand(error)
        }
    }

    static func guestPath(_ path: String, label: String) throws -> String {
        guard !path.isEmpty,
              path.utf8.count <= PommeAgentCLIModelLimits.maximumPathBytes,
              path.hasPrefix("/"),
              !path.contains("\0")
        else {
            throw RunnerError.invalidGuestCommand("\(label) must be an absolute guest path.")
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw RunnerError.invalidGuestCommand("\(label) cannot contain a parent-directory component.")
        }
        return path
    }

    static func hostURL(_ url: URL, label: String) throws -> URL {
        let standardized = url.standardizedFileURL
        guard !url.path.isEmpty,
              standardized.isFileURL,
              standardized.path.hasPrefix("/"),
              standardized.path.utf8.count <= PommeAgentCLIModelLimits.maximumPathBytes,
              !standardized.path.contains("\0")
        else {
            throw RunnerError.invalidCopyEndpoint("Invalid \(label) path.")
        }
        return standardized
    }

    static func optionalString(_ object: [String: Any], _ key: String, label: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let value = value as? String else {
            throw RunnerError.invalidGuestCommand("\(label) must be a string.")
        }
        return value
    }

    static func validateString(_ value: String, label: String, maxBytes: Int = PommeAgentCLIModelLimits.maximumArgumentBytes) throws {
        guard !value.contains("\0"), value.utf8.count <= maxBytes else {
            throw RunnerError.invalidGuestCommand("\(label) is too long or contains an invalid character.")
        }
    }

    static func validateTimeout(_ timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0 else {
            throw RunnerError.invalidGuestCommand("Timeout must be finite and greater than zero.")
        }
    }

    static func validateIdentity(
        user: String?, uid: UInt32?, group: String?, gid: UInt32?
    ) throws {
        guard !(user != nil && uid != nil) else {
            throw RunnerError.invalidGuestCommand("--user conflicts with --uid.")
        }
        guard !(group != nil && gid != nil) else {
            throw RunnerError.invalidGuestCommand("--group conflicts with --gid.")
        }
        if let user {
            try validateString(user, label: "user", maxBytes: 256)
            guard !user.isEmpty else { throw RunnerError.invalidGuestCommand("User must not be empty.") }
        }
        if let group {
            try validateString(group, label: "group", maxBytes: 256)
            guard !group.isEmpty else { throw RunnerError.invalidGuestCommand("Group must not be empty.") }
        }
    }

    static func validateEnvironment(_ environment: [String: String]) throws {
        for (key, value) in environment {
            guard !key.isEmpty,
                  key.utf8.count <= 256,
                  key.first?.isNumber != true,
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            else {
                throw RunnerError.invalidGuestCommand("Environment keys must use ASCII letters, numbers, and underscores and must not start with a number.")
            }
            try validateString(value, label: "Environment value")
        }
    }

    static func validateJobID(_ jobID: String) throws -> UUID {
        guard let uuid = UUID(uuidString: jobID) else {
            throw RunnerError.invalidGuestCommand("Job ID must be a UUID.")
        }
        return uuid
    }

    static func integer(_ value: Any?, label: String) throws -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Int32 { return Int(value) }
        if let value = value as? UInt32 { return Int(value) }
        if let value = value as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(),
           let integer = Int(exactly: value.int64Value) {
            return integer
        }
        throw RunnerError.invalidGuestCommand("\(label) must be an integer.")
    }

    static func bool(_ value: Any?, label: String) throws -> Bool {
        guard let value = value as? Bool else {
            throw RunnerError.invalidGuestCommand("\(label) must be a Boolean.")
        }
        return value
    }

    static func data(from object: [String: Any], base64Key: String, textKey: String) throws -> Data {
        guard !(object[base64Key] != nil && object[textKey] != nil) else {
            throw RunnerError.invalidControlResponse("A process result must use either \(base64Key) or \(textKey), not both.")
        }
        if let value = object[base64Key] {
            guard let encoded = value as? String else {
                throw RunnerError.invalidControlResponse("Invalid \(base64Key).")
            }
            guard let data = Data(base64Encoded: encoded),
                  data.count <= PommeAgentProtocol.maximumStreamChunkBytes
            else {
                throw RunnerError.invalidControlResponse("Invalid or oversized \(base64Key).")
            }
            return data
        }
        if let value = object[textKey] {
            guard let text = value as? String,
                  text.utf8.count <= PommeAgentProtocol.maximumStreamChunkBytes
            else {
                throw RunnerError.invalidControlResponse("Invalid or oversized \(textKey).")
            }
            return Data(text.utf8)
        }
        return Data()
    }

    static func payloadFitsFrame(_ payload: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw RunnerError.invalidGuestCommand("Pomme agent payload is not valid JSON.")
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard data.count < PommeAgentProtocol.maximumFrameBytes else {
            throw RunnerError.invalidGuestCommand("Pomme agent request exceeds the 256 KiB frame limit.")
        }
    }
}

/// Signals accepted by `process.signal` and correlated process streams.
enum GuestSignal: String, CaseIterable, Sendable {
    case term = "TERM"
    case kill = "KILL"
    case int = "INT"
    case hup = "HUP"

    var posixNumber: Int {
        switch self {
        case .hup: 1
        case .int: 2
        case .kill: 9
        case .term: 15
        }
    }

    static func parse(_ value: String) throws -> Self {
        guard let signal = Self(rawValue: value.uppercased()) else {
            throw RunnerError.invalidGuestCommand("Unsupported signal \(value). Use TERM, KILL, INT, or HUP.")
        }
        return signal
    }
}

/// A validated process-start request at the CLI boundary.
struct GuestCommandRequest: Sendable {
    let path: String
    let arguments: [String]
    let timeout: TimeInterval
    let inputData: Data?
    let attachStdin: Bool
    let pty: Bool
    let cwd: String?
    let environment: [String: String]
    let user: String?
    let uid: UInt32?
    let group: String?
    let gid: UInt32?
    let guestStdinPath: String?
    let guestStdoutPath: String?
    let guestStderrPath: String?

    init(
        path: String,
        arguments: [String],
        timeout: TimeInterval,
        inputData: Data? = nil,
        attachStdin: Bool = false,
        pty: Bool = false,
        cwd: String? = nil,
        environment: [String: String] = [:],
        user: String? = nil,
        uid: UInt32? = nil,
        group: String? = nil,
        gid: UInt32? = nil,
        guestStdinPath: String? = nil,
        guestStdoutPath: String? = nil,
        guestStderrPath: String? = nil
    ) {
        self.path = path
        self.arguments = arguments
        self.timeout = timeout
        self.inputData = inputData
        self.attachStdin = attachStdin
        self.pty = pty
        self.cwd = cwd
        self.environment = environment
        self.user = user
        self.uid = uid
        self.group = group
        self.gid = gid
        self.guestStdinPath = guestStdinPath
        self.guestStdoutPath = guestStdoutPath
        self.guestStderrPath = guestStderrPath
    }

    /// Checks all process-start invariants before a control request is sent.
    func validate(detached: Bool = false) throws {
        _ = try PommeAgentCLIModelSupport.guestPath(path, label: "Executable path")
        guard arguments.count <= PommeAgentCLIModelLimits.maximumArgumentCount else {
            throw RunnerError.invalidGuestCommand("A Pomme process request has too many arguments.")
        }
        for argument in arguments {
            try PommeAgentCLIModelSupport.validateString(argument, label: "Process argument")
        }
        try PommeAgentCLIModelSupport.validateTimeout(timeout)
        if let inputData {
            guard inputData.count <= PommeAgentCLIModelLimits.maximumStreamChunkBytes else {
                throw RunnerError.invalidGuestCommand("Initial stdin is limited to 64 KiB; use authenticated stream frames for more input.")
            }
        }
        if let cwd { _ = try PommeAgentCLIModelSupport.guestPath(cwd, label: "Working directory") }
        try PommeAgentCLIModelSupport.validateEnvironment(environment)
        try PommeAgentCLIModelSupport.validateIdentity(user: user, uid: uid, group: group, gid: gid)
        for (value, label) in [
            (guestStdinPath, "Guest stdin path"),
            (guestStdoutPath, "Guest stdout path"),
            (guestStderrPath, "Guest stderr path")
        ] {
            if let value { _ = try PommeAgentCLIModelSupport.guestPath(value, label: label) }
        }
        guard !(attachStdin && guestStdinPath != nil) else {
            throw RunnerError.invalidGuestCommand("Attached stdin conflicts with a guest stdin path.")
        }
        guard !(attachStdin && detached) else {
            throw RunnerError.invalidGuestCommand("Attached stdin conflicts with a detached process.")
        }
        guard !(pty && detached) else {
            throw RunnerError.invalidGuestCommand("PTY execution conflicts with a detached process.")
        }
        guard !(pty && guestStdinPath != nil),
              !(pty && guestStdoutPath != nil),
              !(pty && guestStderrPath != nil)
        else {
            throw RunnerError.invalidGuestCommand("PTY execution conflicts with guest file redirection.")
        }
        try PommeAgentCLIModelSupport.payloadFitsFrame(agentPayload(detached: detached))
    }

    /// Payload fields consumed by the PommeAgent `process.start` operation.
    /// File redirections are guest paths, not host transport selectors.
    func agentPayload(detached: Bool = false) -> [String: Any] {
        var payload: [String: Any] = [
            "path": path,
            "arguments": arguments,
            "timeout": timeout,
            "detached": detached
        ]
        if let inputData { payload["stdinDataBase64"] = inputData.base64EncodedString() }
        if attachStdin { payload["attachStdin"] = true }
        if pty { payload["pty"] = true }
        if let cwd { payload["cwd"] = cwd }
        if !environment.isEmpty { payload["environment"] = environment }
        if let user { payload["user"] = user }
        if let uid { payload["uid"] = uid }
        if let group { payload["group"] = group }
        if let gid { payload["gid"] = gid }
        if let guestStdinPath { payload["stdinPath"] = guestStdinPath }
        if let guestStdoutPath { payload["stdoutPath"] = guestStdoutPath }
        if let guestStderrPath { payload["stderrPath"] = guestStderrPath }
        return payload
    }

    var controlPayload: [String: Any] {
        PommeAgentCLIModelSupport.controlPayload(operation: "process.start", payload: agentPayload())
    }

    /// Payload for the durable terminal-session service.  Terminal sessions
    /// deliberately omit the bounded process timeout and file redirections;
    /// their PTY and replay spool are owned by the guest terminal service.
    func terminalPayload(shell: Bool = false) -> [String: Any] {
        var payload: [String: Any] = [
            "path": path,
            "arguments": arguments,
            "shell": shell
        ]
        if let cwd { payload["cwd"] = cwd }
        if !environment.isEmpty { payload["environment"] = environment }
        if let user { payload["user"] = user }
        if let uid { payload["uid"] = uid }
        if let group { payload["group"] = group }
        if let gid { payload["gid"] = gid }
        return payload
    }

    func validatedControlPayload(detached: Bool = false) throws -> [String: Any] {
        try validate(detached: detached)
        return PommeAgentCLIModelSupport.controlPayload(operation: "process.start", payload: agentPayload(detached: detached))
    }

    static func direct(_ arguments: [String], timeout: TimeInterval, flagName: String = "--exec") throws -> Self {
        guard let path = arguments.first, !path.isEmpty else {
            throw RunnerError.invalidGuestCommand("\(flagName) requires an executable path after --.")
        }
        let request = Self(path: path, arguments: Array(arguments.dropFirst()), timeout: timeout)
        try request.validate()
        return request
    }

    static func parse(from object: [String: Any]) throws -> Self {
        let payload = try PommeAgentCLIModelSupport.operation(from: object, expected: "process.start")
        try PommeAgentCLIModelSupport.exactKeys(
            payload,
            allowed: ["path", "arguments", "timeout", "stdinDataBase64", "attachStdin", "pty", "cwd", "environment", "user", "uid", "group", "gid", "stdinPath", "stdoutPath", "stderrPath", "detached"],
            error: "Pomme process.start payload contains an unknown field."
        )
        guard let path = payload["path"] as? String,
              let arguments = payload["arguments"] as? [String]
        else {
            throw RunnerError.invalidGuestCommand("Pomme process.start requires an executable path and string arguments.")
        }
        let timeout: TimeInterval
        if let value = payload["timeout"] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID() {
            timeout = value.doubleValue
        } else {
            throw RunnerError.invalidGuestCommand("Pomme process.start requires a timeout.")
        }
        let inputData: Data?
        if let encodedValue = payload["stdinDataBase64"] {
            guard let encoded = encodedValue as? String,
                  let data = Data(base64Encoded: encoded), data.count <= PommeAgentCLIModelLimits.maximumStreamChunkBytes else {
                throw RunnerError.invalidGuestCommand("Pomme process.start has invalid initial stdin.")
            }
            inputData = data
        } else {
            inputData = nil
        }
        let environment: [String: String]
        if let supplied = payload["environment"] {
            guard let supplied = supplied as? [String: String] else {
                throw RunnerError.invalidGuestCommand("Pomme process.start has an invalid environment.")
            }
            environment = supplied
        } else {
            environment = [:]
        }
        let request = Self(
            path: path,
            arguments: arguments,
            timeout: timeout,
            inputData: inputData,
            attachStdin: try suppliedBool(payload["attachStdin"], label: "attachStdin"),
            pty: try suppliedBool(payload["pty"], label: "pty"),
            cwd: try PommeAgentCLIModelSupport.optionalString(payload, "cwd", label: "cwd"),
            environment: environment,
            user: try PommeAgentCLIModelSupport.optionalString(payload, "user", label: "user"),
            uid: try suppliedUInt32(payload["uid"], label: "uid"),
            group: try PommeAgentCLIModelSupport.optionalString(payload, "group", label: "group"),
            gid: try suppliedUInt32(payload["gid"], label: "gid"),
            guestStdinPath: try PommeAgentCLIModelSupport.optionalString(payload, "stdinPath", label: "stdinPath"),
            guestStdoutPath: try PommeAgentCLIModelSupport.optionalString(payload, "stdoutPath", label: "stdoutPath"),
            guestStderrPath: try PommeAgentCLIModelSupport.optionalString(payload, "stderrPath", label: "stderrPath")
        )
        try request.validate(detached: try suppliedBool(payload["detached"], label: "detached"))
        return request
    }

    private static func suppliedBool(_ value: Any?, label: String) throws -> Bool {
        guard let value else { return false }
        return try PommeAgentCLIModelSupport.bool(value, label: label)
    }

    private static func suppliedUInt32(_ value: Any?, label: String) throws -> UInt32? {
        guard let value else { return nil }
        let integer = try PommeAgentCLIModelSupport.integer(value, label: label)
        guard let result = UInt32(exactly: integer) else {
            throw RunnerError.invalidGuestCommand("\(label) is outside the supported range.")
        }
        return result
    }
}

/// Public CLI operations mapped to closed PommeAgentProtocol operation names.
enum GuestCLIRequest: Sendable {
    case foreground(GuestCommandRequest)
    case startBackground(GuestCommandRequest)
    case jobList
    case jobStatus(String)
    case jobWait(jobID: String, timeout: TimeInterval)
    case jobOutput(String)
    case inspect
    case health
    case capabilities
    case jobKill(jobID: String, signal: GuestSignal)
    case copy(CopyRequest)
    case cat(CatRequest)
    case remoteLogin(RemoteLoginRequest)
    case screenSharing(ScreenSharingRequest)

    func validate() throws {
        switch self {
        case .foreground(let request): try request.validate()
        case .startBackground(let request): try request.validate(detached: true)
        case .jobList, .inspect, .health, .capabilities: break
        case .jobStatus(let jobID), .jobOutput(let jobID): _ = try PommeAgentCLIModelSupport.validateJobID(jobID)
        case .jobWait(let jobID, let timeout):
            _ = try PommeAgentCLIModelSupport.validateJobID(jobID)
            try PommeAgentCLIModelSupport.validateTimeout(timeout)
        case .jobKill(let jobID, _): _ = try PommeAgentCLIModelSupport.validateJobID(jobID)
        case .copy(let request): try request.validate()
        case .cat(let request): try request.validate()
        case .remoteLogin(let request): try request.validate()
        case .screenSharing(let request): try request.validate()
        }
    }

    var controlPayload: [String: Any] {
        switch self {
        case .foreground(let request):
            return PommeAgentCLIModelSupport.controlPayload(operation: "process.start", payload: request.agentPayload())
        case .startBackground(let request):
            return PommeAgentCLIModelSupport.controlPayload(operation: "process.start", payload: request.agentPayload(detached: true))
        case .jobList:
            return PommeAgentCLIModelSupport.controlPayload(operation: "process.list", payload: [:])
        case .jobStatus(let jobID):
            return PommeAgentCLIModelSupport.controlPayload(operation: "process.status", payload: ["jobID": jobID])
        case .jobWait(let jobID, let timeout):
            return PommeAgentCLIModelSupport.controlPayload(operation: "process.wait", payload: ["jobID": jobID, "timeout": timeout])
        case .jobOutput(let jobID):
            return PommeAgentCLIModelSupport.controlPayload(operation: "process.output", payload: ["jobID": jobID])
        case .inspect, .capabilities:
            return PommeAgentCLIModelSupport.controlPayload(operation: "agent.describe", payload: [:])
        case .health:
            return PommeAgentCLIModelSupport.controlPayload(operation: "agent.health", payload: [:])
        case .jobKill(let jobID, let signal):
            return PommeAgentCLIModelSupport.controlPayload(operation: "process.signal", payload: ["jobID": jobID, "signal": signal.posixNumber])
        case .copy(let request): return request.controlPayload
        case .cat(let request): return request.controlPayload
        case .remoteLogin(let request): return request.controlPayload
        case .screenSharing(let request): return request.controlPayload
        }
    }

    func validatedControlPayload() throws -> [String: Any] {
        try validate()
        return controlPayload
    }
}

/// A host/guest endpoint used by a bounded file transfer.
enum CopyEndpoint: Sendable {
    case host(URL)
    case guest(String)

    var payload: [String: Any] {
        switch self {
        case .host(let url): ["kind": "host", "path": url.path]
        case .guest(let path): ["kind": "guest", "path": path]
        }
    }

    static func parse(_ value: String) throws -> Self {
        if value.hasPrefix("guest:") {
            let path = String(value.dropFirst("guest:".count))
            return .guest(try PommeAgentCLIModelSupport.guestPath(path, label: "Guest endpoint"))
        }
        guard !value.contains(":") || value.hasPrefix("/") else {
            throw RunnerError.invalidCopyEndpoint(value)
        }
        let url: URL
        if value.hasPrefix("/") {
            url = URL(fileURLWithPath: value)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(value)
        }
        return .host(try PommeAgentCLIModelSupport.hostURL(url, label: "Host endpoint"))
    }

    static func parse(from object: [String: Any]) throws -> Self {
        guard Set(object.keys).isSubset(of: ["kind", "path"]),
              let kind = object["kind"] as? String,
              let path = object["path"] as? String
        else {
            throw RunnerError.invalidCopyEndpoint(String(describing: object))
        }
        switch kind {
        case "guest": return .guest(try PommeAgentCLIModelSupport.guestPath(path, label: "Guest endpoint"))
        case "host": return .host(try PommeAgentCLIModelSupport.hostURL(URL(fileURLWithPath: path), label: "Host endpoint"))
        default: throw RunnerError.invalidCopyEndpoint(String(describing: object))
        }
    }
}

struct CopyRequest: Sendable {
    let source: CopyEndpoint
    let destination: CopyEndpoint

    init(source: CopyEndpoint, destination: CopyEndpoint) {
        self.source = source
        self.destination = destination
    }

    func validate() throws {
        switch (source, destination) {
        case (.host, .guest), (.guest, .host): break
        default: throw RunnerError.unsupportedCopy("Copy requires exactly one host path and one guest endpoint.")
        }
        _ = try validatedEndpoint(source, label: "Source")
        _ = try validatedEndpoint(destination, label: "Destination")
    }

    var agentPayload: [String: Any] {
        ["source": source.payload, "destination": destination.payload]
    }

    var controlPayload: [String: Any] {
        PommeAgentCLIModelSupport.controlPayload(operation: "file.transfer", payload: agentPayload)
    }

    func validatedControlPayload() throws -> [String: Any] {
        try validate()
        return controlPayload
    }

    static func parse(source: String, destination: String) throws -> Self {
        let parsedSource = try CopyEndpoint.parse(source)
        let request = Self(
            source: parsedSource,
            destination: try .parse(directoryDestinationExpanded(destination, source: parsedSource))
        )
        try request.validate()
        try request.checkHostPaths()
        return request
    }

    /// Names a host path the transfer could not use before any agent
    /// traffic. The transfer's own opens stay the authoritative checks.
    func checkHostPaths() throws {
        if case .host(let url) = source, let problem = Self.sourceProblem(url) {
            throw RunnerError.hostFileUnavailable(path: url.path, reason: problem)
        }
        if case .host(let url) = destination, let problem = Self.destinationProblem(url) {
            throw RunnerError.hostFileUnavailable(path: url.deletingLastPathComponent().path, reason: problem)
        }
    }

    /// A host source must be a readable regular file reached without a final
    /// symbolic link, matching the transfer's O_NOFOLLOW open.
    static func sourceProblem(_ url: URL) -> HostFileProblem? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        switch value.st_mode & S_IFMT {
        case S_IFLNK: return .symbolicLink
        case S_IFDIR: return .directory
        case S_IFREG: return access(url.path, R_OK) == 0 ? nil : .unreadable
        default: return .notRegular
        }
    }

    static func destinationProblem(_ url: URL) -> HostFileProblem? {
        var isDirectory: ObjCBool = false
        let parent = url.deletingLastPathComponent().path
        return FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory) && isDirectory.boolValue
            ? nil : .missingDirectory
    }

    /// Follows cp(1) for a destination that names a directory: the file keeps
    /// the source's base name inside it. A guest directory is recognisable
    /// only by its trailing slash, because the host cannot stat a guest path;
    /// a host directory is recognised whether or not the slash was typed.
    /// This runs before any agent traffic, so a bad path fails on the host.
    static func directoryDestinationExpanded(_ destination: String, source: CopyEndpoint) -> String {
        let baseName: String
        switch source {
        case .host(let url): baseName = url.lastPathComponent
        case .guest(let path): baseName = URL(fileURLWithPath: path).lastPathComponent
        }
        guard !baseName.isEmpty, baseName != "/" else { return destination }

        if destination.hasPrefix("guest:") {
            return destination.hasSuffix("/") ? destination + baseName : destination
        }
        if destination.hasSuffix("/") {
            return destination + baseName
        }
        let hostPath = destination.hasPrefix("/")
            ? destination
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(destination).path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory), isDirectory.boolValue {
            return destination + "/" + baseName
        }
        return destination
    }

    static func parse(from object: [String: Any]) throws -> Self {
        let payload = try PommeAgentCLIModelSupport.operation(from: object, expected: "file.transfer")
        try PommeAgentCLIModelSupport.exactKeys(payload, allowed: ["source", "destination"], error: "Pomme file.transfer payload contains an unknown field.")
        guard let source = payload["source"] as? [String: Any],
              let destination = payload["destination"] as? [String: Any]
        else { throw RunnerError.invalidCopyEndpoint(String(describing: payload)) }
        let request = Self(source: try .parse(from: source), destination: try .parse(from: destination))
        try request.validate()
        return request
    }

    private func validatedEndpoint(_ endpoint: CopyEndpoint, label: String) throws -> CopyEndpoint {
        switch endpoint {
        case .host(let url): return .host(try PommeAgentCLIModelSupport.hostURL(url, label: label))
        case .guest(let path): return .guest(try PommeAgentCLIModelSupport.guestPath(path, label: label))
        }
    }
}

struct CatRequest: Sendable {
    let guestPath: String
    let offset: Int
    let count: Int?

    init(guestPath: String, offset: Int, count: Int?) {
        self.guestPath = guestPath
        self.offset = offset
        self.count = count
    }

    func validate() throws {
        _ = try PommeAgentCLIModelSupport.guestPath(guestPath, label: "Guest file path")
        guard offset >= 0 else { throw RunnerError.invalidGuestCommand("File offset must not be negative.") }
        if let count {
            guard count >= 0, count <= PommeAgentCLIModelLimits.maximumFileChunkBytes else {
                throw RunnerError.invalidGuestCommand("File read count must be between zero and 32 KiB.")
            }
        }
    }

    var agentPayload: [String: Any] {
        var payload: [String: Any] = ["path": guestPath, "offset": offset]
        payload["count"] = count ?? PommeAgentCLIModelLimits.maximumFileChunkBytes
        return payload
    }

    var controlPayload: [String: Any] {
        PommeAgentCLIModelSupport.controlPayload(operation: "file.read", payload: agentPayload)
    }

    func validatedControlPayload() throws -> [String: Any] {
        try validate()
        return controlPayload
    }

    static func parse(path: String, offset: Int, count: Int?) throws -> Self {
        let endpoint = try CopyEndpoint.parse(path)
        guard case .guest(let guestPath) = endpoint else { throw RunnerError.invalidCopyEndpoint(path) }
        let request = Self(guestPath: guestPath, offset: offset, count: count)
        try request.validate()
        return request
    }

    static func parse(from object: [String: Any]) throws -> Self {
        let payload = try PommeAgentCLIModelSupport.operation(from: object, expected: "file.read")
        try PommeAgentCLIModelSupport.exactKeys(payload, allowed: ["path", "offset", "count"], error: "Pomme file.read payload contains an unknown field.")
        guard let path = payload["path"] as? String else {
            throw RunnerError.invalidGuestCommand("Pomme file.read requires an absolute guest path.")
        }
        let offset = try PommeAgentCLIModelSupport.integer(payload["offset"], label: "File offset")
        let count: Int?
        if payload["count"] == nil {
            count = nil
        } else {
            count = try PommeAgentCLIModelSupport.integer(payload["count"], label: "File read count")
        }
        let request = Self(guestPath: path, offset: offset, count: count)
        try request.validate()
        return request
    }
}

struct RemoteLoginRequest: Sendable {
    let enabled: Bool

    init(enabled: Bool) { self.enabled = enabled }

    func validate() throws {}

    var agentPayload: [String: Any] { ["enabled": enabled] }

    var controlPayload: [String: Any] {
        PommeAgentCLIModelSupport.controlPayload(operation: "remoteLogin.set", payload: agentPayload)
    }

    func validatedControlPayload() throws -> [String: Any] {
        try validate()
        return controlPayload
    }

    static func parse(from object: [String: Any]) throws -> Self {
        let payload = try PommeAgentCLIModelSupport.operation(from: object, expected: "remoteLogin.set")
        try PommeAgentCLIModelSupport.exactKeys(payload, allowed: ["enabled"], error: "Pomme remoteLogin.set payload contains an unknown field.")
        return Self(enabled: try PommeAgentCLIModelSupport.bool(payload["enabled"], label: "enabled"))
    }
}

enum ScreenSharingAction: String, CaseIterable, Sendable {
    case status
    case enable
    case disable
}

struct ScreenSharingRequest: Sendable {
    let action: ScreenSharingAction

    init(action: ScreenSharingAction) { self.action = action }

    func validate() throws {}

    var agentPayload: [String: Any] { ["action": action.rawValue] }

    var controlPayload: [String: Any] {
        PommeAgentCLIModelSupport.controlPayload(operation: "ui.screenSharing", payload: agentPayload)
    }

    func validatedControlPayload() throws -> [String: Any] {
        try validate()
        return controlPayload
    }

    static func parse(from object: [String: Any]) throws -> Self {
        let payload = try PommeAgentCLIModelSupport.operation(from: object, expected: "ui.screenSharing")
        try PommeAgentCLIModelSupport.exactKeys(payload, allowed: ["action"], error: "Pomme ui.screenSharing payload contains an unknown field.")
        guard let raw = payload["action"] as? String,
              let action = ScreenSharingAction(rawValue: raw)
        else { throw RunnerError.invalidGuestCommand("Screen sharing action must be status, enable, or disable.") }
        return Self(action: action)
    }
}

/// Screen Sharing is dispatched only after a fresh, authenticated persistent
/// agent receipt declares the exact capability. A status projection cannot
/// establish either the authenticated role or the guest implementation.
enum ScreenSharingAgentCapabilityGate {
    static let capability = "ui.screenSharing"

    static func verifyAuthenticatedDescribe(_ value: JSONValue) throws {
        guard let object = value.objectValue,
              Set(object.keys).isSubset(of: Set(["role", "protocol", "version", "executableSHA256", "capabilities", "terminalSessionVersion"])),
              Set(["role", "protocol", "version", "executableSHA256", "capabilities"]).isSubset(of: Set(object.keys)),
              object["role"]?.stringValue == "persistent",
              object["protocol"]?.stringValue == PommeAgentProtocol.name,
              object["version"] == .integer(Int64(PommeAgentProtocol.version)),
              let digest = object["executableSHA256"]?.stringValue,
              digest.utf8.count == 64,
              digest.utf8.allSatisfy({
                  ($0 >= 0x30 && $0 <= 0x39)
                      || ($0 >= 0x41 && $0 <= 0x46)
                      || ($0 >= 0x61 && $0 <= 0x66)
              }),
              let values = object["capabilities"]?.arrayValue,
              values.allSatisfy({ $0.stringValue != nil }),
              values.compactMap(\.stringValue).contains(capability)
        else { throw RunnerError.guestScreenSharingUnavailable }
    }

    static func perform<T>(
        describe: () throws -> JSONValue,
        dispatch: () throws -> T
    ) throws -> T {
        try verifyAuthenticatedDescribe(describe())
        return try dispatch()
    }
}

/// A process result. Stream frames are folded into this value by the operation
/// layer; each individual frame remains at most one stream chunk.
struct GuestCommandResult: Sendable {
    let jobID: UUID?
    let pid: Int32?
    let detached: Bool
    let exited: Bool
    let exitCode: Int?
    let signal: Int?
    let stdout: Data
    let stderr: Data
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let timedOut: Bool
    let cleanupEvidence: [String]

    init(
        exitCode: Int?,
        signal: Int?,
        stdout: Data,
        stderr: Data,
        stdoutTruncated: Bool,
        stderrTruncated: Bool,
        timedOut: Bool = false,
        cleanupEvidence: [String] = [],
        jobID: UUID? = nil,
        pid: Int32? = nil,
        detached: Bool = false,
        exited: Bool? = nil
    ) {
        self.jobID = jobID
        self.pid = pid
        self.detached = detached
        self.exited = exited ?? (exitCode != nil || signal != nil || timedOut)
        self.exitCode = exitCode
        self.signal = signal
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.timedOut = timedOut
        self.cleanupEvidence = cleanupEvidence
    }

    var hostExitCode: Int32 {
        if timedOut { return 124 }
        let code: Int
        if let exitCode {
            code = exitCode
        } else if let signal {
            code = 128 + signal
        } else if jobID != nil, !exited {
            code = 0
        } else {
            code = 1
        }
        return Int32(max(0, min(255, code)))
    }

    func validate() throws {
        if let jobID, jobID.uuidString.isEmpty {
            throw RunnerError.invalidControlResponse("Pomme process result has an invalid job ID.")
        }
        if let pid { guard pid > 0 else { throw RunnerError.invalidControlResponse("Pomme process result has an invalid process ID.") } }
        if let exitCode { guard (0...255).contains(exitCode) else { throw RunnerError.invalidControlResponse("Pomme process result has an invalid exit code.") } }
        if let signal { guard signal > 0 && signal <= 255 else { throw RunnerError.invalidControlResponse("Pomme process result has an invalid signal.") } }
        guard !(exitCode != nil && signal != nil) else {
            throw RunnerError.invalidControlResponse("Pomme process result cannot contain both an exit code and a signal.")
        }
        guard !(timedOut && (exitCode != nil || signal != nil)) else {
            throw RunnerError.invalidControlResponse("A timed-out Pomme process cannot contain a terminal status.")
        }
        for evidence in cleanupEvidence { try PommeAgentCLIModelSupport.validateString(evidence, label: "Cleanup evidence", maxBytes: 1024) }
        try PommeAgentCLIModelSupport.payloadFitsFrame(agentPayload)
    }

    var agentPayload: [String: Any] {
        var payload: [String: Any] = [
            "stdoutDataBase64": stdout.base64EncodedString(),
            "stderrDataBase64": stderr.base64EncodedString(),
            "stdoutTruncated": stdoutTruncated,
            "stderrTruncated": stderrTruncated,
            "detached": detached,
            "exited": exited
        ]
        if let jobID { payload["jobID"] = jobID.uuidString.lowercased() }
        if let pid { payload["pid"] = pid }
        if let exitCode { payload["exitCode"] = exitCode }
        if let signal { payload["signal"] = signal }
        if timedOut { payload["timedOut"] = true }
        if !cleanupEvidence.isEmpty { payload["cleanupEvidence"] = cleanupEvidence }
        return payload
    }

    var controlPayload: [String: Any] {
        ["ok": true, "result": agentPayload]
    }

    var jsonPayload: [String: Any] {
        var payload = agentPayload
        payload["stdout"] = String(decoding: stdout, as: UTF8.self)
        payload["stderr"] = String(decoding: stderr, as: UTF8.self)
        payload.removeValue(forKey: "stdoutDataBase64")
        payload.removeValue(forKey: "stderrDataBase64")
        return payload
    }

    static func parse(from object: [String: Any]) throws -> Self {
        guard object["ok"] as? Bool == true else {
            let message: String
            if let error = object["error"] as? [String: Any] {
                message = (error["message"] as? String) ?? "The Pomme agent rejected the process request."
            } else {
                message = object["error"] as? String ?? "The Pomme agent rejected the process request."
            }
            throw RunnerError.guestAgentError(String(message.prefix(512)))
        }

        var values = object
        if let result = object["result"] as? [String: Any] {
            values = result.merging(object) { resultValue, _ in resultValue }
        }
        try PommeAgentCLIModelSupport.exactKeys(
            values,
            allowed: ["ok", "result", "requestID", "streamFrames", "jobID", "pid", "detached", "exited", "exitCode", "signal", "stdoutDataBase64", "stderrDataBase64", "stdout", "stderr", "stdoutTruncated", "stderrTruncated", "timedOut", "cleanupEvidence", "hostExitCode", "operation"],
            error: "Pomme process result contains an unknown field."
        )
        if let requestID = values["requestID"] {
            guard let requestID = requestID as? String, UUID(uuidString: requestID) != nil else {
                throw RunnerError.invalidControlResponse("Pomme process result has an invalid request ID.")
            }
        }
        let jobID: UUID?
        if let raw = values["jobID"] {
            guard let raw = raw as? String, let parsed = UUID(uuidString: raw) else {
                throw RunnerError.invalidControlResponse("Pomme process result has an invalid job ID.")
            }
            jobID = parsed
        } else { jobID = nil }
        let pid: Int32?
        if let raw = values["pid"] {
            let parsed = try PommeAgentCLIModelSupport.integer(raw, label: "Process ID")
            guard let parsed = Int32(exactly: parsed), parsed > 0 else {
                throw RunnerError.invalidControlResponse("Pomme process result has an invalid process ID.")
            }
            pid = parsed
        } else { pid = nil }
        let exitCode = try optionalInteger(values["exitCode"], label: "Exit code")
        let signal = try optionalInteger(values["signal"], label: "Signal")
        if let signal { guard signal > 0 && signal <= 255 else { throw RunnerError.invalidControlResponse("Pomme process result has an invalid signal.") } }
        _ = try optionalInteger(values["hostExitCode"], label: "Host exit code")
        let hasDirectOutput = values["stdoutDataBase64"] != nil || values["stderrDataBase64"] != nil
            || values["stdout"] != nil || values["stderr"] != nil
        let streamOutput = try streamOutputData(from: values["streamFrames"])
        guard !hasDirectOutput || streamOutput == nil else {
            throw RunnerError.invalidControlResponse("Pomme process result contains both direct output and stream output.")
        }
        let stdout = hasDirectOutput
            ? try PommeAgentCLIModelSupport.data(from: values, base64Key: "stdoutDataBase64", textKey: "stdout")
            : streamOutput?.stdout ?? Data()
        let stderr = hasDirectOutput
            ? try PommeAgentCLIModelSupport.data(from: values, base64Key: "stderrDataBase64", textKey: "stderr")
            : streamOutput?.stderr ?? Data()
        let detached = try optionalBool(values["detached"], label: "detached") ?? false
        let exited = try optionalBool(values["exited"], label: "exited") ?? (exitCode != nil || signal != nil || streamOutput?.exited == true)
        let stdoutTruncated = try optionalBool(values["stdoutTruncated"], label: "stdoutTruncated") ?? false
        let stderrTruncated = try optionalBool(values["stderrTruncated"], label: "stderrTruncated") ?? false
        let timedOut = try optionalBool(values["timedOut"], label: "timedOut") ?? false
        let cleanupEvidence: [String]
        if let supplied = values["cleanupEvidence"] {
            guard let supplied = supplied as? [String] else {
                throw RunnerError.invalidControlResponse("Pomme process result has invalid cleanup evidence.")
            }
            cleanupEvidence = supplied
        } else {
            cleanupEvidence = []
        }
        let result = Self(
            exitCode: exitCode,
            signal: signal,
            stdout: stdout,
            stderr: stderr,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated,
            timedOut: timedOut,
            cleanupEvidence: cleanupEvidence,
            jobID: jobID,
            pid: pid,
            detached: detached,
            exited: exited
        )
        try result.validate()
        return result
    }

    private static func streamOutputData(from value: Any?) throws -> (stdout: Data, stderr: Data, exited: Bool)? {
        guard let value else { return nil }
        guard let frames = value as? [[String: Any]] else {
            throw RunnerError.invalidControlResponse("Pomme process result has invalid stream frames.")
        }
        var stdout = Data()
        var stderr = Data()
        var exited = false
        for frame in frames {
            try PommeAgentCLIModelSupport.exactKeys(
                frame,
                allowed: ["jobID", "requestID", "stream", "dataBase64", "columns", "rows", "signal"],
                error: "Pomme process result has an invalid stream frame."
            )
            guard let stream = frame["stream"] as? String,
                  ["stdout", "stderr", "stdin", "eof", "resize", "signal", "exit"].contains(stream)
            else { throw RunnerError.invalidControlResponse("Pomme process result has an invalid stream kind.") }
            if let requestID = frame["requestID"] {
                guard let requestID = requestID as? String, UUID(uuidString: requestID) != nil else {
                    throw RunnerError.invalidControlResponse("Pomme process result has an invalid stream request ID.")
                }
            }
            if let jobID = frame["jobID"] {
                guard let jobID = jobID as? String, UUID(uuidString: jobID) != nil else {
                    throw RunnerError.invalidControlResponse("Pomme process result has an invalid stream job ID.")
                }
            }
            if stream == "exit" { exited = true }
            guard let encoded = frame["dataBase64"] as? String else {
                guard stream != "stdout", stream != "stderr" else {
                    throw RunnerError.invalidControlResponse("Pomme output stream frame is missing data.")
                }
                continue
            }
            guard let data = Data(base64Encoded: encoded), data.count <= PommeAgentCLIModelLimits.maximumStreamChunkBytes else {
                throw RunnerError.invalidControlResponse("Pomme output stream data is invalid or oversized.")
            }
            switch stream {
            case "stdout": stdout.append(data)
            case "stderr": stderr.append(data)
            default: break
            }
        }
        return (stdout, stderr, exited)
    }

    private static func optionalInteger(_ value: Any?, label: String) throws -> Int? {
        guard let value else { return nil }
        return try PommeAgentCLIModelSupport.integer(value, label: label)
    }

    private static func optionalBool(_ value: Any?, label: String) throws -> Bool? {
        guard let value else { return nil }
        return try PommeAgentCLIModelSupport.bool(value, label: label)
    }
}
