@testable import CodexKit
import XCTest

extension CodexResponsesBackendTests {
    func testResponsesImageReferencesExternalizeAndRestoreEveryImageBody() throws {
        let requestImage = AgentImageAttachment.png(
            Data("REQUEST_IMAGE_BYTES".utf8),
            id: "request-image"
        )
        let generatedImage = AgentImageAttachment.png(
            Data("GENERATED_IMAGE_BYTES".utf8),
            id: "generated-image"
        )
        let original: [JSONValue] = [
            WorkingHistoryItem.userMessage(AgentMessage(
                threadID: "image-reference-thread",
                role: .user,
                text: "Inspect this image",
                images: [requestImage]
            )).jsonValue,
            .object([
                "type": .string("image_generation_call"),
                "result": .string(generatedImage.data.base64EncodedString()),
            ]),
        ]

        let externalized = try CodexResponsesImageReferences.externalize(original)
        let persistedText = String(
            decoding: try JSONEncoder().encode(externalized),
            as: UTF8.self
        )
        XCTAssertFalse(persistedText.contains("data:image"))
        XCTAssertFalse(persistedText.contains(requestImage.data.base64EncodedString()))
        XCTAssertFalse(persistedText.contains(generatedImage.data.base64EncodedString()))

        let restored = try CodexResponsesImageReferences.restore(
            externalized,
            using: [requestImage, generatedImage]
        )
        XCTAssertEqual(restored, original)
    }

    func testResumableBackgroundModeReconnectsStoredResponseWithoutRepostingHistory() async throws {
        let backend = CodexResponsesBackend(
            configuration: CodexResponsesBackendConfiguration(
                executionMode: .resumableBackground,
                requestRetryPolicy: .init(
                    maxAttempts: 2,
                    initialBackoff: 0,
                    maxBackoff: 0,
                    jitterFactor: 0
                )
            ),
            urlSession: makeTestURLSession()
        )
        let session = recoveryTestSession()

        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.created
            data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_background"}}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","sequence_number":1,"delta":"Hel"}

            """.utf8),
            inspect: { request in
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try XCTUnwrap(requestBodyData(for: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["background"] as? Bool, true)
                XCTAssertEqual(json["store"] as? Bool, true)
                XCTAssertNil(json["previous_response_id"])
                XCTAssertEqual((json["input"] as? [Any])?.count, 2)
            }
        ))
        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","sequence_number":2,"delta":"lo"}

            event: response.output_item.done
            data: {"type":"response.output_item.done","sequence_number":3,"output_index":0,"item":{"id":"msg_background","type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}

            event: response.completed
            data: {"type":"response.completed","sequence_number":4,"response":{"id":"resp_background","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

            """.utf8),
            inspect: { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/backend-api/codex/responses/resp_background")
                let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
                XCTAssertEqual(query["stream"] ?? nil, "true")
                XCTAssertEqual(query["starting_after"] ?? nil, "1")
            }
        ))

        let stream = try await backend.beginTurn(
            thread: AgentThread(id: "thread-background"),
            history: [AgentMessage(threadID: "thread-background", role: .user, text: "Earlier")],
            message: Request(text: "Continue"),
            instructions: "Resolved instructions",
            responseFormat: nil,
            streamedStructuredOutput: nil,
            tools: [],
            session: session
        )

        var deltas: [String] = []
        var checkpoint: AgentTurnRecoveryCheckpoint?
        var assistantMessage: AgentMessage?
        for try await event in stream.events {
            switch event {
            case let .assistantMessageDelta(_, _, delta):
                deltas.append(delta)
            case let .turnRecoveryCheckpointUpdated(value):
                checkpoint = value
            case let .assistantMessageCompleted(message):
                assistantMessage = message
            default:
                break
            }
        }

        XCTAssertEqual(deltas, ["Hel", "lo"])
        XCTAssertEqual(checkpoint?.payload.objectValue?["response_id"]?.stringValue, "resp_background")
        XCTAssertEqual(assistantMessage?.id, "msg_background")
        XCTAssertEqual(assistantMessage?.text, "Hello")
    }

    func testRuntimePersistsAndRecoversInterruptedBackgroundTurn() async throws {
        let backendConfiguration = CodexResponsesBackendConfiguration(
            executionMode: .resumableBackground,
            requestRetryPolicy: .init(
                maxAttempts: 1,
                initialBackoff: 0,
                maxBackoff: 0,
                jitterFactor: 0
            )
        )
        let secureStore = KeychainSessionSecureStore(
            service: "CodexKitTests.ChatGPTSession",
            account: UUID().uuidString
        )
        let stateStore = InMemoryRuntimeStateStore()
        let makeRuntime = {
            try AgentRuntime(configuration: .init(
                authProvider: DemoChatGPTAuthProvider(),
                secureStore: secureStore,
                backend: CodexResponsesBackend(
                    configuration: backendConfiguration,
                    urlSession: makeTestURLSession()
                ),
                approvalPresenter: AutoApprovalPresenter(),
                stateStore: stateStore
            ))
        }

        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.created
            data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_restore"}}

            """.utf8)
        ))

        let threadID: String
        do {
            let initialRuntime = try makeRuntime()
            _ = try await initialRuntime.restore()
            _ = try await initialRuntime.useSession(recoveryTestSession())
            let thread = try await initialRuntime.createThread()
            threadID = thread.id

            let interruptedStream = try await initialRuntime.stream(
                Request(text: "Finish this later"),
                in: threadID
            )
            await XCTAssertThrowsErrorAsync(try await drainAgentEvents(interruptedStream))
        }

        let restoredRuntime = try makeRuntime()
        _ = try await restoredRuntime.restore()
        let restoredSession = await restoredRuntime.currentSession()
        XCTAssertEqual(restoredSession?.account.id, "workspace-123")

        let storedCheckpoint = try await restoredRuntime.pendingTurnRecoveryCheckpoint(in: threadID)
        XCTAssertEqual(storedCheckpoint?.payload.objectValue?["response_id"]?.stringValue, "resp_restore")
        let interruptedStatus = await restoredRuntime.activeThreads().first?.status
        XCTAssertEqual(interruptedStatus, .streaming)

        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.output_item.done
            data: {"type":"response.output_item.done","sequence_number":1,"output_index":0,"item":{"id":"msg_restore","type":"message","role":"assistant","content":[{"type":"output_text","text":"Recovered without restarting"}]}}

            event: response.completed
            data: {"type":"response.completed","sequence_number":2,"response":{"id":"resp_restore","usage":{"input_tokens":6,"input_tokens_details":{"cached_tokens":0},"output_tokens":3}}}

            """.utf8),
            inspect: { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertTrue(request.url?.absoluteString.contains("starting_after=0") == true)
            }
        ))

        let pendingStream = try await restoredRuntime.resumePendingTurn(in: threadID)
        let recoveredStream = try XCTUnwrap(pendingStream)
        try await drainAgentEvents(recoveredStream)

        let messages = await restoredRuntime.messages(for: threadID)
        XCTAssertEqual(messages.filter { $0.id == "msg_restore" }.count, 1)
        XCTAssertEqual(messages.last?.text, "Recovered without restarting")
        let remainingCheckpoint = try await restoredRuntime.pendingTurnRecoveryCheckpoint(in: threadID)
        let recoveredStatus = await restoredRuntime.activeThreads().first?.status
        XCTAssertNil(remainingCheckpoint)
        XCTAssertEqual(recoveredStatus, .idle)
    }

    func testRecoveredTurnReusesPersistedToolResultWithoutRepeatingSideEffect() async throws {
        let backendConfiguration = CodexResponsesBackendConfiguration(
            executionMode: .resumableBackground,
            requestRetryPolicy: .init(
                maxAttempts: 1,
                initialBackoff: 0,
                maxBackoff: 0,
                jitterFactor: 0
            )
        )
        let secureStore = KeychainSessionSecureStore(
            service: "CodexKitTests.ChatGPTSession",
            account: UUID().uuidString
        )
        let stateStore = InMemoryRuntimeStateStore()
        let toolCounter = RecoveryToolInvocationCounter()
        let tool = ToolDefinition(
            name: "lookup_recovery_value",
            description: "Returns a stable recovery value.",
            inputSchema: .object(["type": .string("object")])
        )
        let makeRuntime = {
            try AgentRuntime(configuration: .init(
                authProvider: DemoChatGPTAuthProvider(),
                secureStore: secureStore,
                backend: CodexResponsesBackend(
                    configuration: backendConfiguration,
                    urlSession: makeTestURLSession()
                ),
                approvalPresenter: AutoApprovalPresenter(),
                stateStore: stateStore,
                tools: [.init(
                    definition: tool,
                    executor: AnyToolExecutor { invocation, _ in
                        await toolCounter.increment()
                        return .success(invocation: invocation, text: "stable-value")
                    }
                )]
            ))
        }

        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.created
            data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_tool_restore"}}

            event: response.output_item.done
            data: {"type":"response.output_item.done","sequence_number":1,"output_index":0,"item":{"id":"fc_restore","type":"function_call","name":"lookup_recovery_value","arguments":"{}","call_id":"call_restore","status":"completed"}}

            """.utf8)
        ))

        let threadID: String
        do {
            let initialRuntime = try makeRuntime()
            _ = try await initialRuntime.restore()
            _ = try await initialRuntime.useSession(recoveryTestSession())
            threadID = try await initialRuntime.createThread().id
            let interruptedStream = try await initialRuntime.stream(
                Request(text: "Use the recovery tool"),
                in: threadID
            )
            await XCTAssertThrowsErrorAsync(try await drainAgentEvents(interruptedStream))
        }
        let initialToolCount = await toolCounter.value
        XCTAssertEqual(initialToolCount, 1)

        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.output_item.done
            data: {"type":"response.output_item.done","sequence_number":1,"output_index":0,"item":{"id":"fc_restore","type":"function_call","name":"lookup_recovery_value","arguments":"{}","call_id":"call_restore","status":"completed"}}

            event: response.completed
            data: {"type":"response.completed","sequence_number":2,"response":{"id":"resp_tool_restore","usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens":1}}}

            """.utf8),
            inspect: { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertTrue(request.url?.absoluteString.contains("starting_after=0") == true)
            }
        ))
        await TestURLProtocol.enqueue(.init(
            headers: ["Content-Type": "text/event-stream"],
            body: Data("""
            event: response.created
            data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_tool_final"}}

            event: response.output_item.done
            data: {"type":"response.output_item.done","sequence_number":1,"output_index":0,"item":{"id":"msg_tool_final","type":"message","role":"assistant","content":[{"type":"output_text","text":"Used the saved tool result"}]}}

            event: response.completed
            data: {"type":"response.completed","sequence_number":2,"response":{"id":"resp_tool_final","usage":{"input_tokens":3,"input_tokens_details":{"cached_tokens":0},"output_tokens":2}}}

            """.utf8),
            inspect: { request in
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try XCTUnwrap(requestBodyData(for: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let input = try XCTUnwrap(json["input"] as? [[String: Any]])
                let outputs = input.filter { $0["type"] as? String == "function_call_output" }
                XCTAssertEqual(outputs.count, 1)
                XCTAssertEqual(outputs.first?["call_id"] as? String, "call_restore")
                XCTAssertEqual(outputs.first?["output"] as? String, "stable-value")
            }
        ))

        let restoredRuntime = try makeRuntime()
        _ = try await restoredRuntime.restore()
        let pendingRecoveryStream = try await restoredRuntime.resumePendingTurn(in: threadID)
        let recoveryStream = try XCTUnwrap(pendingRecoveryStream)
        try await drainAgentEvents(recoveryStream)

        let recoveredToolCount = await toolCounter.value
        XCTAssertEqual(recoveredToolCount, 1)
        let messages = await restoredRuntime.messages(for: threadID)
        XCTAssertEqual(messages.last?.text, "Used the saved tool result")
    }
}

private func recoveryTestSession() -> ChatGPTSession {
    ChatGPTSession(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        account: ChatGPTAccount(
            id: "workspace-123",
            email: "taylor@example.com",
            plan: .plus
        )
    )
}

private func drainAgentEvents(
    _ events: AsyncThrowingStream<AgentEvent, Error>
) async throws {
    for try await _ in events {}
}

private actor RecoveryToolInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
