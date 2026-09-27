import Darwin
import Foundation

/// Errors from the guest-side native profile observation boundary. Native
/// output is never included in these errors.
enum GuestMDMObservationError: Error, Equatable, LocalizedError {
    case invalidTimeout
    case invalidOutputLimit
    case commandFailed
    case timedOut
    case outputTooLarge
    case terminationUnproven

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            "The guest MDM observation timeout is invalid."
        case .invalidOutputLimit:
            "The guest MDM observation output limit is invalid."
        case .commandFailed:
            "The guest MDM profile observation command failed."
        case .timedOut:
            "The guest MDM profile observation command timed out."
        case .outputTooLarge:
            "The guest MDM profile observation output is too large."
        case .terminationUnproven:
            "The guest MDM profile observation process could not be terminated and verified."
        }
    }
}

/// The guest-side structured profile observation seam.
///
/// The default runner invokes the native `profiles` tool and bounds both
/// output streams. Tests can inject a runner without invoking native tools.
struct GuestMDMObservation {
    typealias ProfilesShowRunner = (_ timeout: TimeInterval, _ maximumOutputBytes: Int) throws -> Data

    static let profilesExecutable = "/usr/bin/profiles"
    static let defaultMaximumOutputBytes = 16 * 1024 * 1024

    private let profilesShowRunner: ProfilesShowRunner

    init(profilesShowRunner: @escaping ProfilesShowRunner = GuestMDMObservation.runProfilesShow) {
        self.profilesShowRunner = profilesShowRunner
    }

    /// Runs the bounded native probe and parses only device-level profile
    /// identity. No installed MDM profile is represented by `nil`.
    func installedProfileIdentity(
        timeout: TimeInterval,
        maximumOutputBytes: Int = GuestMDMObservation.defaultMaximumOutputBytes
    ) throws -> MDMInstalledProfileIdentity? {
        guard timeout.isFinite, timeout >= 1, timeout <= 300 else {
            throw GuestMDMObservationError.invalidTimeout
        }
        guard maximumOutputBytes > 0, maximumOutputBytes <= Self.defaultMaximumOutputBytes else {
            throw GuestMDMObservationError.invalidOutputLimit
        }
        GuestMDMDiagnostics.record(.profilesCommand)
        let output = try profilesShowRunner(timeout, maximumOutputBytes)
        guard output.count <= maximumOutputBytes else {
            throw GuestMDMObservationError.outputTooLarge
        }
        GuestMDMDiagnostics.record(.profilesParse)
        do {
            return try MDMEnrollmentEvidenceParser.parseInstalledProfileIdentity(
                fromProfilesShow: output
            )
        } catch MDMEnrollmentEvidenceError.missingEvidence {
            return nil
        }
    }

    /// The production observation closure used by `GuestMDMEnrollment`.
    static func liveInstalledProfileIdentity(
        expected _: MDMEnrollmentProfileIdentity,
        timeout: TimeInterval
    ) throws -> MDMInstalledProfileIdentity? {
        try Self().installedProfileIdentity(timeout: timeout)
    }

    private static func runProfilesShow(
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> Data {
        guard timeout.isFinite, timeout >= 1, timeout <= 300 else {
            throw GuestMDMObservationError.invalidTimeout
        }
        guard maximumOutputBytes > 0, maximumOutputBytes <= defaultMaximumOutputBytes else {
            throw GuestMDMObservationError.invalidOutputLimit
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: profilesExecutable)
        process.arguments = ["show", "-output", "stdout-xml"]
        process.environment = [:]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw GuestMDMObservationError.commandFailed
        }

        let outputDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        let errorDescriptor = errorPipe.fileHandleForReading.fileDescriptor
        guard Self.makeNonBlocking(outputDescriptor), Self.makeNonBlocking(errorDescriptor) else {
            guard Self.terminateAndProve(process) else {
                throw GuestMDMObservationError.terminationUnproven
            }
            throw GuestMDMObservationError.commandFailed
        }

        var output = Data()
        var errorOutput = Data()
        var outputEOF = false
        var errorEOF = false
        let deadline = Date().addingTimeInterval(timeout)

        while process.isRunning || !outputEOF || !errorEOF {
            Self.drain(
                outputDescriptor,
                into: &output,
                eof: &outputEOF,
                maximumBytes: maximumOutputBytes
            )
            Self.drain(
                errorDescriptor,
                into: &errorOutput,
                eof: &errorEOF,
                maximumBytes: maximumOutputBytes
            )

            if output.count > maximumOutputBytes || errorOutput.count > maximumOutputBytes {
                guard Self.terminateAndProve(process) else {
                    throw GuestMDMObservationError.terminationUnproven
                }
                throw GuestMDMObservationError.outputTooLarge
            }
            if Date() >= deadline {
                guard Self.terminateAndProve(process) else {
                    throw GuestMDMObservationError.terminationUnproven
                }
                throw GuestMDMObservationError.timedOut
            }
            if !process.isRunning && outputEOF && errorEOF {
                break
            }
            usleep(10_000)
        }

        // The loop has proved process termination and both pipes reached EOF.
        // Reap the child without introducing an unbounded wait.
        process.waitUntilExit()
        GuestMDMDiagnostics.record(.profilesCommand, status: Int64(process.terminationStatus), flags: errorOutput.isEmpty ? 0 : 1)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw GuestMDMObservationError.commandFailed
        }
        guard errorOutput.isEmpty else {
            throw GuestMDMObservationError.commandFailed
        }
        return output
    }

    private static func makeNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func drain(
        _ descriptor: Int32,
        into data: inout Data,
        eof: inout Bool,
        maximumBytes: Int
    ) {
        guard !eof else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let available = max(0, maximumBytes - data.count)
                if available > 0 {
                    data.append(contentsOf: buffer.prefix(min(count, available)))
                }
                if count > available {
                    // Retain one byte beyond the limit as a bounded overflow
                    // marker for the caller; the process is terminated on the
                    // next loop iteration.
                    if data.count == maximumBytes {
                        data.append(0)
                    }
                    return
                }
            } else if count == 0 {
                eof = true
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                eof = true
                return
            }
        }
    }

    private static func terminateAndProve(_ process: Process) -> Bool {
        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }
        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < gracefulDeadline {
            usleep(10_000)
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            let forcedDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < forcedDeadline {
                usleep(10_000)
            }
        }
        guard !process.isRunning else { return false }
        process.waitUntilExit()
        return true
    }
}
