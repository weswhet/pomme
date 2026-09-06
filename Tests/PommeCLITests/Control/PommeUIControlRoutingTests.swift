import Testing

@Suite("Pomme direct UI control routing")
struct PommeUIControlRoutingTests {
    @Test("routes a key request without a guest-agent operation")
    func keyRequestRoutesToUI() throws {
        let request = PommeControlRequest(
            command: "guest-ui",
            payload: .object([
                "operation": .string("key"),
                "agentPayload": .object([
                    "operation": .string("key"),
                    "key": .string("cmd-space")
                ]),
                "timeout": .number(2)
            ])
        )

        guard case .guestUI(let ui) = try PommeVMControlRouter.route(request) else {
            Issue.record("guest-ui key was not routed to the direct UI request")
            return
        }
        #expect(ui.operation.rawValue == "key")
        #expect(ui.agentPayload["key"] == .string("cmd-space"))
        #expect(ui.timeout == 2)
        #expect(ui.hostOutputPath == nil)
    }

    @Test("accepts flattened key-sequence payloads from the control bridge")
    func flattenedKeySequenceRoutes() throws {
        let request = PommeControlRequest(
            command: "guest-ui",
            payload: .object([
                "operation": .string("key-sequence"),
                "keys": .array([.string("tab"), .string("down"), .string("return")]),
                "timeout": .integer(5)
            ])
        )

        guard case .guestUI(let ui) = try PommeVMControlRouter.route(request) else {
            Issue.record("flattened key-sequence was not routed")
            return
        }
        #expect(ui.operation.rawValue == "key-sequence")
        #expect(ui.agentPayload["keys"]?.arrayValue?.count == 3)
    }

    @Test("rejects malformed or unsafe UI requests before dispatch")
    func rejectsUnsafeRequests() {
        let requests: [PommeControlRequest] = [
            .init(command: "guest-ui", payload: .object([
                "operation": .string("key"),
                "agentPayload": .object(["operation": .string("key"), "key": .string("")])
            ])),
            .init(command: "guest-ui", payload: .object([
                "operation": .string("key-sequence"),
                "agentPayload": .object(["operation": .string("key-sequence"), "keys": .array([])])
            ])),
            .init(command: "guest-ui", payload: .object([
                "operation": .string("click"),
                "agentPayload": .object(["operation": .string("click"), "x": .string("nan"), "y": .integer(2)])
            ])),
            .init(command: "guest-ui", payload: .object([
                "operation": .string("screenshot"),
                "agentPayload": .object(["operation": .string("screenshot")])
            ])),
            .init(command: "guest-ui", payload: .object([
                "operation": .string("settings-ai"),
                "agentPayload": .object(["operation": .string("settings-ai")])
            ]))
        ]

        for request in requests {
            #expect(throws: RunnerError.self) {
                try PommeVMControlRouter.route(request)
            }
        }
    }

    @Test("streaming is not accepted for direct UI operations")
    func uiStreamingIsRejected() {
        let request = PommeControlRequest(
            command: "guest-ui",
            payload: .object([
                "operation": .string("key"),
                "agentPayload": .object(["operation": .string("key"), "key": .string("return")])
            ]),
            streaming: true
        )
        #expect(throws: RunnerError.self) {
            try PommeVMControlRouter.route(request)
        }
    }
}
