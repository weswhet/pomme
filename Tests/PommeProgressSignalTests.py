#!/usr/bin/env python3
"""Synthetic renderer signal checks. Run after the signed Pomme install gate.

No VM or Pomme CLI is launched. Compilation uses native Xcode Swift tooling.
Use --preview 40 for an interactive demonstration at a chosen column width.
"""

import argparse
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import tempfile
import time


HARNESS = r'''import Darwin
import Foundation

private func existingHandler(_ number: Int32) {}

@main struct ProgressSignalHarness {
    static func address(_ handler: (@convention(c) (Int32) -> Void)?) -> UInt {
        unsafeBitCast(handler, to: UInt.self)
    }

    static func disposition(_ number: Int32) -> sigaction {
        var action = sigaction()
        precondition(sigaction(number, nil, &action) == 0)
        return action
    }

    static func main() {
        let mode = CommandLine.arguments[1]
        let width = Int(CommandLine.arguments.last ?? "80") ?? 80
        if mode == "ignored" { Darwin.signal(SIGINT, SIG_IGN) }
        if mode == "custom" { Darwin.signal(SIGINT, existingHandler) }
        if mode == "restore" {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = SIG_DFL
            action.sa_flags = SA_RESTART
            sigemptyset(&action.sa_mask)
            sigaddset(&action.sa_mask, SIGUSR1)
            precondition(sigaction(SIGINT, &action, nil) == 0)
        }
        let original = disposition(SIGINT)
        let session = PommeProgressSession(mode: .auto, structuredOutput: false, debug: false,
            environment: ["LANG": "en_US.UTF-8", "TERM": "xterm-256color"],
            terminalWidth: { width }, isTerminal: true)
        session.sink.step(vm: "synthetic", "Waiting for synthetic operation")
        if mode == "signal" {
            Thread.sleep(forTimeInterval: 30)
        } else if mode == "preview" {
            Thread.sleep(forTimeInterval: 1)
            session.sink.step(vm: "synthetic", "Launching Terminal")
            Thread.sleep(forTimeInterval: 1)
            let totalBytes: Int64 = 20 * 1_024 * 1_024 * 1_024
            let resumedBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
            for sample in 0...20 {
                let bytes = resumedBytes + Int64(sample) * 16 * 1_024 * 1_024
                session.sink.measured(vm: "synthetic", "Downloading IPSW 27.0", fraction: Double(bytes) / Double(totalBytes),
                    completedBytes: bytes, totalBytes: totalBytes)
                Thread.sleep(forTimeInterval: 0.2)
            }
            session.sink.step(vm: "synthetic", "Bootstrapping Pomme agent for normal boot")
            Thread.sleep(forTimeInterval: 1)
        } else {
            Thread.sleep(forTimeInterval: 0.3)
            if mode == "ignored" || mode == "custom" {
                precondition(address(disposition(SIGINT).__sigaction_u.__sa_handler) == address(original.__sigaction_u.__sa_handler))
            }
            if mode == "suspend" { session.sink.suspend() }
            else { session.finish() }
            let restored = disposition(SIGINT)
            precondition(address(restored.__sigaction_u.__sa_handler) == address(original.__sigaction_u.__sa_handler))
            precondition(restored.sa_mask == original.sa_mask)
            precondition(restored.sa_flags == original.sa_flags)
        }
        session.finish()
    }
}
'''


def signal_check(executable, number):
    master, slave = pty.openpty()
    process = subprocess.Popen([str(executable), "signal"], stdout=slave, stderr=slave)
    os.close(slave)
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 8
    try:
        # Keep draining while the child exits. macOS PTYs can discard their last
        # queued write if the parent waits for termination before reading it.
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 8192)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
                if not sent and b"Waiting for synthetic operation" in output:
                    process.send_signal(number)
                    sent = True
        assert sent, "renderer did not present its first frame"
        assert process.wait(timeout=2) == -number, "default signal exit changed"
        assert output.endswith(b"\r\x1b[2K"), "signal did not clear the live line"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", type=int, metavar="COLUMNS")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (root / "Sources/PommeCLI/CLI/PommeProgress.swift").read_text()
    source = source.replace("import ArgumentParser\n", "").replace(", ExpressibleByArgument", "")
    with tempfile.TemporaryDirectory(prefix="pomme-progress-signals-") as temporary:
        directory = Path(temporary)
        renderer = directory / "Progress.swift"
        harness = directory / "Harness.swift"
        executable = directory / "progress-signals"
        renderer.write_text(source)
        harness.write_text(HARNESS)
        subprocess.run(["rtk", "proxy", "xcrun", "swiftc", "-swift-version", "6",
                        str(renderer), str(harness), "-o", str(executable)], check=True)
        if args.preview:
            subprocess.run([str(executable), "preview", str(args.preview)], check=True)
            return
        for number in (signal.SIGINT, signal.SIGTERM):
            signal_check(executable, number)
            print(f"PASS {number.name}: clears line and preserves default exit")
        for mode in ("ignored", "custom", "restore", "suspend"):
            subprocess.run([str(executable), mode], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, check=True, timeout=5)
            print(f"PASS {mode}: preserves signal disposition")


if __name__ == "__main__":
    main()
