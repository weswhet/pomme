import Darwin
import Foundation
import Testing

@Suite("Pomme agent PTY safety")
struct PommeAgentPTYTests: Sendable {
    @Test("PTY input is not echoed to the output stream")
    func ptyDisablesEcho() throws {
        let spawned = try PommeProcess.spawn(
            path: "/bin/sh",
            arguments: ["-c", "printf Password:; read value; printf done"],
            identity: nil,
            pty: true
        )
        guard let master = spawned.ptyMaster else {
            Issue.record("Expected a PTY master descriptor.")
            return
        }
        defer {
            var status: Int32 = 0
            if waitpid(spawned.pid, &status, WNOHANG) == 0 {
                _ = kill(-spawned.pid, SIGKILL)
                _ = kill(spawned.pid, SIGKILL)
                _ = waitpid(spawned.pid, &status, 0)
            }
            _ = Darwin.close(master)
        }

        var output = Data()
        let promptDeadline = Date().addingTimeInterval(1)
        while Date() < promptDeadline {
            appendAvailable(from: master, to: &output)
            if output.range(of: Data("Password:".utf8)) != nil { break }
            usleep(10_000)
        }
        #expect(output.range(of: Data("Password:".utf8)) != nil)

        try writeAll(Data("pw\n".utf8), to: master)
        var status: Int32 = 0
        var finished = false
        let completionDeadline = Date().addingTimeInterval(1)
        while Date() < completionDeadline {
            appendAvailable(from: master, to: &output)
            if waitpid(spawned.pid, &status, WNOHANG) == spawned.pid {
                finished = true
                break
            }
            usleep(10_000)
        }
        appendAvailable(from: master, to: &output)

        #expect(output.range(of: Data("done".utf8)) != nil)
        #expect(output.range(of: Data("pw".utf8)) == nil)
        #expect(finished)
    }

    private func appendAvailable(from descriptor: Int32, to output: inout Data) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                output.append(contentsOf: bytes.prefix(Int(count)))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(.EIO)
                }
            }
        }
    }
}
