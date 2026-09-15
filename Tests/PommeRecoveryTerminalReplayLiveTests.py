#!/usr/bin/env python3
"""Opt-in byte-exact checks against an already-running disposable Recovery VM.

Uses the installed signed CLI; never boots a VM or changes its security settings.
Deletes only successfully verified sessions created here. Failed sessions remain
available for investigation. No transcript files are written on the host.
"""

import argparse
import json
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", required=True)
    parser.add_argument("--vm", required=True)
    parser.add_argument("--iterations", type=int, default=10)
    args = parser.parse_args()
    if not args.vm.startswith("pomme-agent-") or args.iterations < 1:
        parser.error("requires an explicit pomme-agent-* VM and positive iterations")

    def run(*arguments):
        result = subprocess.run(
            [args.runner, *arguments], capture_output=True, timeout=300, check=False
        )
        if result.returncode:
            # Do not copy potentially sensitive CLI diagnostics into test logs.
            raise RuntimeError(f"CLI command {arguments[0]} failed ({result.returncode})")
        return result.stdout

    def request(*arguments):
        result = json.loads(run(*arguments, "--json"))
        if not result.get("ok", False):
            raise RuntimeError("CLI returned an unsuccessful result")
        return result

    status = request("status", args.vm)
    if status.get("vmState") != "running" or status.get("bootMode") != "recovery":
        parser.error("the selected disposable VM must already be running in Recovery")

    for iteration in range(args.iterations):
        # Vary chunk boundaries, including output substantially larger than one
        # transport frame. Omit --cwd deliberately: it must default to stable /.
        size = (100000, 1048576, 65536)[iteration % 3]
        command = (
            "pwd -P; printf BEGIN; "
            f"/bin/dd if=/dev/zero bs={size} count=1 2>/dev/null; printf END"
        )
        created = json.loads(run(
            "exec", args.vm, "--pty", "--detach", "--json", "--",
            "/bin/sh", "-c", command,
        ))
        session_id = created.get("sessionID")
        if not created.get("ok") or not session_id:
            raise RuntimeError("terminal creation failed")
        print(f"Checking session {session_id} ({size} payload bytes)", flush=True)
        deadline = time.monotonic() + 60
        while True:
            record = request("sessions", "inspect", args.vm, session_id)
            if record["state"] == "exited":
                break
            if record["state"] == "lost" or time.monotonic() >= deadline:
                raise RuntimeError(f"session {session_id} did not finish; retained")
            time.sleep(0.05)

        expected = b"/\r\nBEGIN" + b"\0" * size + b"END"
        if record.get("exitCode") != 0 or record["transcriptOffset"] != len(expected):
            raise RuntimeError(
                f"session {session_id}: expected {len(expected)} bytes and exit 0, "
                f"got {record['transcriptOffset']} bytes and exit {record.get('exitCode')}; retained"
            )
        for _ in range(2):
            actual = run("sessions", "logs", args.vm, session_id)
            if actual != expected:
                raise RuntimeError(f"session {session_id}: byte-exact replay failed; retained")
        tail = run(
            "sessions", "logs", args.vm, session_id,
            "--from-offset", str(len(expected) - 3),
        )
        if tail != b"END":
            raise RuntimeError(f"session {session_id}: offset replay failed; retained")
        request("sessions", "delete", args.vm, session_id)
        print(f"PASS {iteration + 1}: stable cwd, complete output, repeat and offset replay", flush=True)


if __name__ == "__main__":
    main()
