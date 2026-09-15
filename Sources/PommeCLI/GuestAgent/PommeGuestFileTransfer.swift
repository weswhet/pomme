import CryptoKit
import Darwin
import Foundation

/// Host-side orchestration over the existing authenticated file-handle protocol.
/// Host paths never cross the guest boundary; only bounded file chunks do.
struct PommeGuestFileTransfer {
    let perform: (String, JSONValue) throws -> JSONValue

    struct Receipt {
        let bytes: UInt64
        let sha256: String

        var payload: [String: Any] {
            ["ok": true, "operation": "file.transfer", "bytes": bytes,
             "sha256": sha256, "hostExitCode": 0]
        }
    }

    func copy(_ request: CopyRequest) throws -> Receipt {
        try request.validate()
        switch (request.source, request.destination) {
        case (.host(let source), .guest(let destination)):
            return try upload(source: source, destination: destination)
        case (.guest(let source), .host(let destination)):
            return try download(source: source, destination: destination)
        default:
            throw RunnerError.unsupportedCopy("Copy requires one host path and one guest endpoint.")
        }
    }

    func cat(_ request: CatRequest) throws -> [String: Any] {
        try request.validate()
        let fileID = try open(request.guestPath, mode: "read")
        var transferred: UInt64 = 0
        do {
            try seek(fileID, offset: Int64(request.offset), whence: "set")
            let chunk = try read(fileID, count: request.count ?? PommeAgentProtocol.maximumFileChunkBytes)
            transferred = UInt64(chunk.data.count)
            try close(fileID)
            return ["ok": true, "operation": "file.read", "hostExitCode": 0,
                    "dataBase64": chunk.data.base64EncodedString(), "bytes": chunk.data.count,
                    "offset": request.offset, "eof": chunk.eof]
        } catch {
            throw failure(error, bytes: transferred, cleanup: cleanup(fileID, operation: "file.close"))
        }
    }

    private func upload(source: URL, destination: String) throws -> Receipt {
        let descriptor: Int32
        do {
            descriptor = try PommeAgentFileTransaction.openRegular(source, flags: O_RDONLY)
        } catch {
            // The source changed after the request was parsed; name it rather
            // than reporting a protocol failure.
            if let problem = CopyRequest.sourceProblem(source) {
                throw RunnerError.hostFileUnavailable(path: source.path, reason: problem)
            }
            throw error
        }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_size >= 0 else { throw invalid("Invalid source file size.") }
        let fileID = try open(destination, mode: "stageWrite")
        var transferred: UInt64 = 0
        var commitAttempted = false
        do {
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: PommeAgentProtocol.maximumFileChunkBytes)
            while transferred < UInt64(before.st_size) {
                let requested = Int(min(UInt64(buffer.count), UInt64(before.st_size) - transferred))
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, requested) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw invalid("Source file changed or could not be read.") }
                let data = Data(buffer.prefix(count))
                let written = try perform("file.write", .object([
                    "fileID": .string(fileID), "dataBase64": .string(data.base64EncodedString())
                ]))
                guard written == .object(["count": .integer(Int64(count))]) else {
                    throw invalid("Invalid file-write receipt.")
                }
                hasher.update(data: data)
                transferred += UInt64(count)
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
            else { throw invalid("Source file changed during transfer.") }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            commitAttempted = true
            let committed = try perform("file.commit", .object([
                "fileID": .string(fileID), "expectedBytes": .integer(Int64(transferred)),
                "expectedSHA256": .string(digest)
            ]))
            guard committed == .object([
                "committed": .bool(true), "bytes": .integer(Int64(transferred)), "sha256": .string(digest)
            ]) else { throw invalid("Invalid file-commit receipt; destination state is uncertain.") }
            return .init(bytes: transferred, sha256: digest)
        } catch {
            let primary: Error = commitAttempted
                ? invalid("Guest commit did not return a verified receipt; the destination may have changed. \(error.localizedDescription)")
                : error
            throw failure(primary, bytes: transferred, cleanup: cleanup(fileID, operation: "file.abort"))
        }
    }

    private func download(source: String, destination: URL) throws -> Receipt {
        let stage: (url: URL, descriptor: Int32)
        do {
            stage = try PommeAgentFileTransaction.createAdjacentStage(for: destination)
        } catch {
            if let problem = CopyRequest.destinationProblem(destination) {
                throw RunnerError.hostFileUnavailable(path: destination.deletingLastPathComponent().path, reason: problem)
            }
            throw error
        }
        var descriptorOpen = true
        var remoteID: String?
        var transferred: UInt64 = 0
        var published = false
        do {
            let fileID = try open(source, mode: "read")
            remoteID = fileID
            let length = try position(fileID, offset: 0, whence: "end")
            try seek(fileID, offset: 0, whence: "set")
            var hasher = SHA256()
            while transferred < UInt64(length) {
                let count = Int(min(UInt64(PommeAgentProtocol.maximumFileChunkBytes), UInt64(length) - transferred))
                let chunk = try read(fileID, count: count)
                guard !chunk.data.isEmpty else { throw invalid("Guest file ended before its reported size.") }
                try PommeAgentFileTransaction.writeAll(stage.descriptor, data: chunk.data)
                hasher.update(data: chunk.data)
                transferred += UInt64(chunk.data.count)
                if chunk.eof, transferred < UInt64(length) { throw invalid("Guest file changed during transfer.") }
            }
            guard try position(fileID, offset: 0, whence: "end") == length else {
                throw invalid("Guest file changed during transfer.")
            }
            try close(fileID)
            remoteID = nil
            guard fsync(stage.descriptor) == 0 else { throw invalid("Could not synchronize the host staging file.") }
            let closed = Darwin.close(stage.descriptor)
            descriptorOpen = false
            guard closed == 0 else { throw invalid("Could not close the host staging file.") }
            do {
                try PommeAgentFileTransaction.commit(stage: stage.url, destination: destination)
            } catch let error as PommeAgentFileTransaction.CommitError {
                published = true
                throw error
            }
            published = true
            try PommeAgentFileTransaction.fsyncParentDirectory(of: destination)
            return .init(bytes: transferred, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            var errors: [String] = []
            if let remoteID { errors += cleanup(remoteID, operation: "file.close") }
            if descriptorOpen, Darwin.close(stage.descriptor) != 0 { errors.append("host staging close failed") }
            if !published {
                do { try PommeAgentFileTransaction.removeAdjacentStage(stage.url, for: destination) }
                catch { errors.append("host staging removal failed") }
            }
            throw failure(error, bytes: transferred, cleanup: errors)
        }
    }

    private func open(_ path: String, mode: String) throws -> String {
        // Earlier installed agents do not recognize /etc in their no-follow
        // walker, and Foundation rewrites /private/etc back to that alias.
        // Use its normal macOS Data-volume path; every component is still
        // verified by the guest's no-follow walker.
        let guestPath: String
        if path.hasPrefix("/etc/") {
            guestPath = "/System/Volumes/Data/private" + path
        } else if path.hasPrefix("/private/etc/") {
            guestPath = "/System/Volumes/Data" + path
        } else {
            guestPath = path
        }
        let result = try perform("file.open", .object(["path": .string(guestPath), "mode": .string(mode)]))
        guard let object = result.objectValue,
              let fileID = object["fileID"]?.stringValue, UUID(uuidString: fileID) != nil
        else { throw invalid("Invalid file-open receipt; guest handle cleanup cannot be verified.") }
        guard Set(object.keys) == (mode == "read" ? ["fileID"] : ["fileID", "staged"]),
              mode == "read" || object["staged"] == .bool(true) else {
            throw failure(invalid("Invalid file-open receipt."), bytes: 0,
                          cleanup: cleanup(fileID, operation: mode == "read" ? "file.close" : "file.abort"))
        }
        return fileID
    }

    private func read(_ fileID: String, count: Int) throws -> (data: Data, eof: Bool) {
        let result = try perform("file.read", .object(["fileID": .string(fileID), "count": .integer(Int64(count))]))
        guard let object = result.objectValue, Set(object.keys) == ["dataBase64", "eof"],
              let encoded = object["dataBase64"]?.stringValue,
              let data = Data(base64Encoded: encoded), data.count <= count,
              case .bool(let eof) = object["eof"],
              !data.isEmpty || eof || count == 0
        else { throw invalid("Invalid file-read receipt.") }
        return (data, eof)
    }

    private func position(_ fileID: String, offset: Int64, whence: String) throws -> Int64 {
        let result = try perform("file.seek", .object([
            "fileID": .string(fileID), "offset": .integer(offset), "whence": .string(whence)
        ]))
        guard let object = result.objectValue, Set(object.keys) == ["position"],
              case .integer(let position) = object["position"], position >= 0 else {
            throw invalid("Invalid file-seek receipt.")
        }
        return position
    }

    private func seek(_ fileID: String, offset: Int64, whence: String) throws {
        guard try position(fileID, offset: offset, whence: whence) == offset else {
            throw invalid("Guest file seek did not reach the requested offset.")
        }
    }

    private func close(_ fileID: String) throws {
        guard try perform("file.close", .object(["fileID": .string(fileID)])) == .object([:]) else {
            throw invalid("Invalid file-close receipt.")
        }
    }

    private func cleanup(_ fileID: String, operation: String) -> [String] {
        do {
            let result = try perform(operation, .object(["fileID": .string(fileID)]))
            let expected: JSONValue = operation == "file.abort" ? .object(["aborted": .bool(true)]) : .object([:])
            return result == expected ? [] : ["\(operation) cleanup receipt was invalid"]
        } catch { return ["\(operation) cleanup could not be verified"] }
    }

    private func failure(_ error: Error, bytes: UInt64, cleanup: [String]) -> RunnerError {
        .guestFileTransferFailed(primary: error.localizedDescription, transferredBytes: bytes, cleanupErrors: cleanup)
    }

    private func invalid(_ message: String) -> RunnerError { .invalidControlResponse(message) }
}
