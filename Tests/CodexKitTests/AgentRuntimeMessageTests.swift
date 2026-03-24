import CodexKit
import XCTest

// MARK: - Messaging

extension AgentRuntimeTests {
    func testSendMessageReturnsFinalAssistantMessageText() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Complete")
        let reply = try await runtime.sendMessage(
            UserMessageRequest(text: "Hello there"),
            in: thread.id
        )

        XCTAssertEqual(reply, "Echo: Hello there")
    }

    func testSendMessageExpectingStructuredTypeDecodesTypedResponse() async throws {
        let backend = InMemoryAgentBackend(
            structuredResponseText: #"{"reply":"Your order is already in transit.","priority":"high"}"#
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured")
        let reply = try await runtime.sendMessage(
            UserMessageRequest(text: "Draft a shipping reply."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        XCTAssertEqual(
            reply,
            ShippingReplyDraft(
                reply: "Your order is already in transit.",
                priority: "high"
            )
        )

        let formats = await backend.receivedResponseFormats()
        XCTAssertEqual(formats.last??.name, "shipping_reply_draft")

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(
            messages.last?.structuredOutput,
            AgentStructuredOutputMetadata(
                formatName: "shipping_reply_draft",
                payload: .object([
                    "reply": .string("Your order is already in transit."),
                    "priority": .string("high"),
                ])
            )
        )
    }

    func testStructuredStreamYieldsVisibleTextAndCommittedPayload() async throws {
        let backend = InMemoryAgentBackend(
            structuredResponseText: #"{"reply":"Your order is already in transit.","priority":"high"}"#
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured Stream")
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Draft a shipping reply."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        var visibleText = ""
        var partials: [ShippingReplyDraft] = []
        var committed: ShippingReplyDraft?
        var sawTurnCompleted = false

        for try await event in stream {
            switch event {
            case let .assistantMessageDelta(_, _, delta):
                visibleText += delta
            case let .structuredOutputPartial(snapshot):
                partials.append(snapshot)
            case let .structuredOutputCommitted(snapshot):
                committed = snapshot
            case .turnCompleted:
                sawTurnCompleted = true
                XCTAssertNotNil(committed)
            default:
                break
            }
        }

        XCTAssertEqual(visibleText, "Echo: Draft a shipping reply.")
        XCTAssertFalse(visibleText.contains("codexkit-structured-output"))
        XCTAssertFalse(partials.isEmpty)
        XCTAssertEqual(
            committed,
            ShippingReplyDraft(
                reply: "Your order is already in transit.",
                priority: "high"
            )
        )
        XCTAssertTrue(sawTurnCompleted)

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.last?.text, "Echo: Draft a shipping reply.")
        XCTAssertEqual(
            messages.last?.structuredOutput,
            AgentStructuredOutputMetadata(
                formatName: "shipping_reply_draft",
                payload: .object([
                    "reply": .string("Your order is already in transit."),
                    "priority": .string("high"),
                ])
            )
        )
    }

    func testStructuredStreamPersistsFinalPayloadMetadataAcrossRestore() async throws {
        let backend = InMemoryAgentBackend(
            structuredResponseText: #"{"reply":"Your order is already in transit.","priority":"high"}"#
        )
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured Stream Restore")
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Draft a shipping reply."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )
        try await drainStructuredStream(stream)

        let restoredRuntime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))
        _ = try await restoredRuntime.restore()

        let messages = await restoredRuntime.messages(for: thread.id)
        XCTAssertEqual(
            messages.last?.structuredOutput,
            AgentStructuredOutputMetadata(
                formatName: "shipping_reply_draft",
                payload: .object([
                    "reply": .string("Your order is already in transit."),
                    "priority": .string("high"),
                ])
            )
        )
    }

    func testStructuredStreamRequiredFailsWhenNoPayloadIsProduced() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: OptionalStructuredMissingBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured Required")
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Draft a shipping reply."),
            in: thread.id,
            expecting: ShippingReplyDraft.self,
            options: .init(required: true)
        )

        await XCTAssertThrowsErrorAsync(
            try await drainStructuredStream(stream)
        ) { error in
            let runtimeError = error as? AgentRuntimeError
            XCTAssertEqual(runtimeError?.code, "structured_output_missing")
        }
    }

    func testStructuredStreamOptionalSucceedsWithoutPayload() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: OptionalStructuredMissingBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured Optional")
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Draft a shipping reply."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        var sawCommitted = false
        var visibleText = ""

        for try await event in stream {
            switch event {
            case let .assistantMessageDelta(_, _, delta):
                visibleText += delta
            case .structuredOutputCommitted:
                sawCommitted = true
            default:
                break
            }
        }

        XCTAssertFalse(sawCommitted)
        XCTAssertEqual(visibleText, "Echo: Draft a shipping reply.")
    }

    func testStructuredDecodeFailureThrowsRuntimeError() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(
                structuredResponseText: #"{"unexpected":"value"}"#
            ),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured Failure")

        await XCTAssertThrowsErrorAsync(
            try await runtime.sendMessage(
                UserMessageRequest(text: "Draft a shipping reply."),
                in: thread.id,
                expecting: ShippingReplyDraft.self
            )
        ) { error in
            let runtimeError = error as? AgentRuntimeError
            XCTAssertEqual(runtimeError?.code, "structured_output_decoding_failed")
            XCTAssertTrue(runtimeError?.message.contains("ShippingReplyDraft") == true)
        }
    }

    func testStructuredStreamValidationFailureSurfacesAndFailsTurn() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(
                structuredResponseText: #"{"unexpected":"value"}"#
            ),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured Stream Failure")
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Draft a shipping reply."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        var validationFailures: [AgentStructuredOutputValidationFailure] = []

        await XCTAssertThrowsErrorAsync(
            try await collectStructuredStreamFailures(
                from: stream,
                into: &validationFailures
            )
        ) { error in
            let runtimeError = error as? AgentRuntimeError
            XCTAssertEqual(runtimeError?.code, "structured_output_invalid")
        }

        XCTAssertFalse(validationFailures.isEmpty)
        XCTAssertEqual(validationFailures.last?.stage, .committed)
    }

}
