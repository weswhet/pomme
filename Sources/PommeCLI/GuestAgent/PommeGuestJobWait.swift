import Foundation

/// Public waits poll short requests so neither the VM mutation lease nor the
/// serial guest connection is held while a background process is running.
struct PommeGuestJobWait {
    let perform: (GuestCLIRequest, TimeInterval) throws -> [String: Any]
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    func wait(jobID: String, timeout: TimeInterval) throws -> [String: Any] {
        try GuestCLIRequest.jobWait(jobID: jobID, timeout: timeout).validate()
        let deadline = now() + timeout
        var lastResponse: [String: Any] = ["result": ["jobID": jobID]]
        while true {
            let remaining = deadline - now()
            guard remaining > 0 else { return timedOut(lastResponse) }
            do {
                let response = try perform(.jobStatus(jobID), remaining)
                guard try accepted(response) else { return response }
                lastResponse = response
                let status = try checkedStatus(response, jobID: jobID)
                guard let exited = status["exited"] as? Bool,
                      let outputPending = status["outputPending"] as? Bool else {
                    throw RunnerError.invalidControlResponse("Invalid background job status.")
                }
                if exited, !outputPending {
                    let outputBudget = deadline - now()
                    guard outputBudget > 0 else { return timedOut(lastResponse) }
                    var output = try perform(.jobOutput(jobID), outputBudget)
                    guard try accepted(output) else { return output }
                    var completed = try checkedStatus(output, jobID: jobID)
                    guard completed["exited"] as? Bool == true,
                          completed["outputComplete"] as? Bool == true else {
                        throw RunnerError.invalidControlResponse("Background job output is incomplete.")
                    }
                    let exitCode: Int
                    if let rawCode = integerValue(completed["exitCode"]),
                       (0...255).contains(rawCode),
                       let code = Int(exactly: rawCode) {
                        exitCode = code
                    } else if let rawSignal = integerValue(completed["signal"]),
                              (1...127).contains(rawSignal),
                              let signal = Int(exactly: rawSignal) {
                        exitCode = 128 + signal
                    } else {
                        throw RunnerError.invalidControlResponse("Missing background job exit status.")
                    }
                    completed["timedOut"] = false
                    output["result"] = completed
                    output["operation"] = "process.wait"
                    output["hostExitCode"] = exitCode
                    return output
                }
            } catch let error as POSIXError where error.code == .ETIMEDOUT {
                return timedOut(lastResponse)
            } catch VMBundleMutationLease.Error.activeMutation(_) {
                // Another command may be signalling the job between polls.
                // Retry contention within the same deadline, without holding
                // the lease or extending the user's wait.
            }
            let pause = min(0.05, deadline - now())
            if pause > 0 { sleep(pause) }
        }
    }

    private func timedOut(_ lastResponse: [String: Any]) -> [String: Any] {
        var response = lastResponse
        var status = response["result"] as? [String: Any] ?? [:]
        status["timedOut"] = true
        status["outputComplete"] = false
        response["result"] = status
        response["operation"] = "process.wait"
        response["ok"] = false
        response["hostExitCode"] = 124
        response["error"] = "Timed out waiting for the background job."
        // Poll output remains in the guest's retained logs. A timeout must
        // not print just the last poll as if it were the full log.
        response["streamFrames"] = [[String: Any]]()
        return response
    }

    private func checkedStatus(_ response: [String: Any], jobID: String) throws -> [String: Any] {
        guard let status = response["result"] as? [String: Any],
              let actualID = status["jobID"] as? String,
              UUID(uuidString: actualID) == UUID(uuidString: jobID) else {
            throw RunnerError.invalidControlResponse("Invalid background job response.")
        }
        return status
    }

    private func accepted(_ response: [String: Any]) throws -> Bool {
        guard let ok = response["ok"] as? Bool else {
            throw RunnerError.invalidControlResponse("Missing background job response status.")
        }
        return ok
    }

    /// `PommeCore.sendControlObject` preserves protocol integers as `Int64`
    /// through `JSONValue.publicValue`. Decode the JSON type before narrowing
    /// so completed job statuses are accepted from the real transport shape
    /// while booleans, strings, and fractional numbers remain invalid.
    private func integerValue(_ value: Any?) -> Int64? {
        guard let value, let decoded = try? JSONValue(any: value),
              case .integer(let integer) = decoded else { return nil }
        return integer
    }
}
