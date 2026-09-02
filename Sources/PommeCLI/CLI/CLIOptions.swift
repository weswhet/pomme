import Foundation

enum OutputMode: String {
    case text
    case json
    case jsonl
    case raw

    var jsonOutput: Bool {
        switch self {
        case .json, .jsonl:
            return true
        case .text, .raw:
            return false
        }
    }

    static func parse(_ value: String) throws -> OutputMode {
        guard let mode = OutputMode(rawValue: value.lowercased()) else {
            throw RunnerError.usage
        }
        return mode
    }
}

struct CLIOptions {
    var vmName: String?
    var bundlePath: String?
    var createConfigPath: String?
    var createConfig: VMCreationConfigV1?
    var configBuildRequest: ConfigBuildRequest?
    var restoreImagePath: String?
    var ipswDeviceIdentifier: String?
    var ipswList = false
    var ipswLimit: Int?
    var ipswDownloadSelection: String?
    var restoreImageVersionSelection: String?
    var resumeDownload = false
    var sizeOptions = VMSizeOptions.default
    var hasCustomSizeOptions = false
    var create = false
    var start = false
    var bootMode: BootMode = .normal
    var stop = false
    var pause = false
    var destroy = false
    var destroyConfirmation: String?
    var showTUI = false
    var shellCommand: String?
    var execArguments: [String]?
    var backgroundShellCommand: String?
    var backgroundExecArguments: [String]?
    var enableRemoteLogin = false
    var jobList = false
    var jobStatusID: String?
    var jobWaitID: String?
    var jobOutputID: String?
    var uiRequest: GuestUIRequest?
    var mdmEnrollmentRequest: MDMEnrollmentRequest?
    var sipAction: SIPAction?
    var amfiAction: AMFIAction?
    var sipUser: String?
    var sipPassword: String?
    var sipBootstrap = SIPBootstrapOptions()
    var timeout = Constants.defaultGuestCommandTimeout
    var debug = false
    var outputMode: OutputMode = .text
    var jsonOutput = false
    var argsJSONObject: [String: Any]?
    var listVMs = false
    var showAgentHelp = false
    var showTools = false

    var hasConfigOperation: Bool {
        createConfigPath != nil || createConfig != nil || configBuildRequest != nil
    }

    var hasGuestControlOperation: Bool {
        guestControlOperationCount > 0
    }

    var hasSIPOperation: Bool {
        sipAction != nil || amfiAction != nil
    }

    var guestControlOperationCount: Int {
        [
            shellCommand != nil,
            execArguments != nil,
            backgroundShellCommand != nil,
            backgroundExecArguments != nil,
            enableRemoteLogin,
            jobList,
            jobStatusID != nil,
            jobWaitID != nil,
            jobOutputID != nil
        ].filter { $0 }.count
    }
}

struct ConfigBuildRequest {
    var outputPath: String?
    var overwrite: Bool
}

extension MDMEnrollmentMethod: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try MDMEnrollmentMethod.parse(try container.decode(String.self), flag: "mdm.method")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
