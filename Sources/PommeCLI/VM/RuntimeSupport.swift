import Foundation
import ArgumentParser
@preconcurrency import AppKit
import Security
// Virtualization reference types are confined to their documented serial VM queue below.
// Remove this when the SDK models these queue-confined APIs with Sendable-aware annotations.
@preconcurrency import Virtualization
import Darwin

actor ExitSignal {
    private var didRequestExit = false
    private var exitHoldCount = 0
    private var pendingExitRequest = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func beginExitHold() {
        guard !didRequestExit else {
            return
        }
        exitHoldCount += 1
    }

    func endExitHold() {
        guard exitHoldCount > 0 else {
            return
        }
        exitHoldCount -= 1
        if exitHoldCount == 0, pendingExitRequest {
            pendingExitRequest = false
            signalExit()
        }
    }

    func requestExit() {
        guard !didRequestExit else {
            return
        }
        guard exitHoldCount == 0 else {
            pendingExitRequest = true
            return
        }

        signalExit()
    }

    private func signalExit() {
        didRequestExit = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        if didRequestExit {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    private let exitSignal: ExitSignal

    init(exitSignal: ExitSignal) {
        self.exitSignal = exitSignal
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("[\(Date().pommeISO8601String)] Guest stopped the VM.")
        let exitSignal = self.exitSignal
        Task {
            await exitSignal.requestExit()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("[\(Date().pommeISO8601String)] VM stopped with error: \(error.localizedDescription)")
        let exitSignal = self.exitSignal
        Task {
            await exitSignal.requestExit()
        }
    }
}
