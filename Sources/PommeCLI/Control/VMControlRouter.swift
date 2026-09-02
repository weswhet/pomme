import Foundation

enum PommeVMControlRouter {
    static func route(_ request: PommeControlRequest) throws -> PommeVMControlRequest {
        let object: [String: Any]
        let jsonObject: [String: JSONValue]
        if let payload = request.payload {
            guard let payloadObject = payload.objectValue else { throw RunnerError.invalidControlCommand(request.command) }
            object = payloadObject.mapValues(\.publicValue)
            jsonObject = payloadObject
        } else { object = [:]; jsonObject = [:] }
        switch request.command {
        case "pause", "resume", "stop", "force-stop":
            guard let command = PommeLifecycleCommand(rawValue: request.command) else { throw RunnerError.invalidControlCommand(request.command) }
            return .lifecycle(command)
        case "snapshot-save":
            return .snapshotSave(try PommeSnapshotSaveRequest.parse(from: object))
        case "status":
            return .status
        case "inspect":
            return .inspect
        case "agent.perform":
            return .agentPerform(try PommeAgentPerformRequest.parse(from: jsonObject), streaming: request.streaming == true)
        default:
            throw RunnerError.invalidControlCommand(request.command)
        }
    }
}
