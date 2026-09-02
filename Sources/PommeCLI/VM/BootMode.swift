import Foundation
import ArgumentParser
@preconcurrency import AppKit
import Security
// Virtualization reference types are confined to their documented serial VM queue below.
// Remove this when the SDK models these queue-confined APIs with Sendable-aware annotations.
@preconcurrency import Virtualization
import Darwin

enum BootMode: String, ExpressibleByArgument, Sendable {
    case normal
    case recovery

    var label: String {
        switch self {
        case .normal:
            "normal"
        case .recovery:
            "recovery"
        }
    }
}

enum VMFinalState: String, CaseIterable, ExpressibleByArgument, Sendable {
    case previous
    case stopped
    case normal
    case recovery
    case paused
}
