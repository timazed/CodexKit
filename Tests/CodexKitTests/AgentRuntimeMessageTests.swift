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

    func testImportedContentInitializerBuildsMessageWithSharedURLs() async throws {
        let importedContent = AgentImportedContent(
            textSnippets: ["Customer says the package arrived damaged."],
            urls: [URL(string: "https://example.com/delivery-update")!]
        )

        let request = UserMessageRequest(
            prompt: "Summarize and draft a reply.",
            importedContent: importedContent
        )

        XCTAssertTrue(request.text.contains("Summarize and draft a reply."))
        XCTAssertTrue(request.text.contains("https://example.com/delivery-update"))
        XCTAssertTrue(request.text.contains("Customer says the package arrived damaged."))
    }

    func testImageOnlyMessageIsAcceptedAndPersisted() async throws {
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

        let thread = try await runtime.createThread(title: "Images")
        let image = AgentImageAttachment.png(Data([0x89, 0x50, 0x4E, 0x47]))

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "", images: [image]),
            in: thread.id
        )

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.first?.images.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
    }

    func testAssistantImagesAreCommittedToThreadHistory() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: ImageReplyAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Assistant Images")
        let reply = try await runtime.sendMessage(
            UserMessageRequest(text: "show me an image"),
            in: thread.id
        )

        XCTAssertEqual(reply, "Attached 1 image")

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.images.count, 1)
    }

    func testRuntimeStreamsToolApprovalAndCompletion() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            tools: [
                .init(
                    definition: ToolDefinition(
                        name: "demo_lookup_profile",
                        description: "Lookup profile",
                        inputSchema: .object([:]),
                        approvalPolicy: .requiresApproval
                    ),
                    executor: AnyToolExecutor { invocation, _ in
                        .success(invocation: invocation, text: "demo-result")
                    }
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )

        var sawApproval = false
        var sawToolResult = false

        for try await event in stream {
            switch event {
            case .approvalRequested:
                sawApproval = true
            case let .toolCallFinished(result):
                sawToolResult = true
                XCTAssertEqual(result.primaryText, "demo-result")
            default:
                break
            }
        }

        XCTAssertTrue(sawApproval)
        XCTAssertTrue(sawToolResult)
    }

    func testStructuredStreamWorksAlongsideToolCalls() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            tools: [
                .init(
                    definition: ToolDefinition(
                        name: "demo_lookup_profile",
                        description: "Lookup profile",
                        inputSchema: .object([:]),
                        approvalPolicy: .requiresApproval
                    ),
                    executor: AnyToolExecutor { invocation, _ in
                        .success(invocation: invocation, text: "demo-result")
                    }
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        var sawToolResult = false
        var sawCommitted = false

        for try await event in stream {
            switch event {
            case .toolCallFinished:
                sawToolResult = true
            case .structuredOutputCommitted:
                sawCommitted = true
            default:
                break
            }
        }

        XCTAssertTrue(sawToolResult)
        XCTAssertTrue(sawCommitted)
    }

    func testSendMessageRetriesUnauthorizedByRefreshingSession() async throws {
        let authProvider = RotatingDemoAuthProvider()
        let backend = UnauthorizedThenSuccessBackend()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: authProvider,
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

        let thread = try await runtime.createThread(title: "Recovered Thread")
        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Hello after refresh"),
            in: thread.id
        )

        let refreshCount = await authProvider.refreshCount()
        XCTAssertEqual(refreshCount, 1)

        let attemptedTokens = await backend.attemptedAccessTokens()
        XCTAssertEqual(attemptedTokens.count, 2)
        XCTAssertEqual(attemptedTokens[0], "demo-access-token-initial")
        XCTAssertEqual(attemptedTokens[1], "demo-access-token-refreshed-1")

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.filter { $0.role == .assistant }.count, 1)
    }

    func testCreateThreadRetriesUnauthorizedByRefreshingSession() async throws {
        let authProvider = RotatingDemoAuthProvider()
        let backend = UnauthorizedOnCreateThenSuccessBackend()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: authProvider,
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

        let thread = try await runtime.createThread(title: "Recovered Thread")
        XCTAssertEqual(thread.title, "Recovered Thread")

        let refreshCount = await authProvider.refreshCount()
        XCTAssertEqual(refreshCount, 1)

        let attemptedTokens = await backend.attemptedAccessTokens()
        XCTAssertEqual(attemptedTokens.count, 2)
        XCTAssertEqual(attemptedTokens[0], "demo-access-token-initial")
        XCTAssertEqual(attemptedTokens[1], "demo-access-token-refreshed-1")
    }

    func testConfigurationRegistersInitialTools() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            tools: [
                .init(
                    definition: ToolDefinition(
                        name: "demo_lookup_profile",
                        description: "Lookup profile",
                        inputSchema: .object([:]),
                        approvalPolicy: .requiresApproval
                    ),
                    executor: AnyToolExecutor { invocation, _ in
                        .success(invocation: invocation, text: "demo-result")
                    }
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )

        var sawToolResult = false

        for try await event in stream {
            if case let .toolCallFinished(result) = event {
                sawToolResult = true
                XCTAssertEqual(result.primaryText, "demo-result")
            }
        }

        XCTAssertTrue(sawToolResult)
    }
}

private func drainStructuredStream<Output: Sendable>(
    _ stream: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>
) async throws {
    for try await _ in stream {}
}

private func collectStructuredStreamFailures<Output: Sendable>(
    from stream: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>,
    into failures: inout [AgentStructuredOutputValidationFailure]
) async throws {
    for try await event in stream {
        if case let .structuredOutputValidationFailed(validationFailure) = event {
            failures.append(validationFailure)
        }
    }
}
