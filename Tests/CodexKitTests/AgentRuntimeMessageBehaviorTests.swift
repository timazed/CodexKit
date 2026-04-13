import Combine
import CodexKit
import XCTest

extension AgentRuntimeTests {
    func testTypedStructuredInputRequestResolvesSeparatelyFromVisiblePrompt() async throws {
        struct PlannerContext: Codable, Sendable {
            let objective: String
            let customerTier: String
        }

        let backend = InMemoryAgentBackend(
            structuredResponseText: #"{"reply":"Your order is already in transit.","priority":"high"}"#
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured Input")
        let reply = try await runtime.sendMessage(
            AgentMessageRequest(
                text: "Draft a shipping reply.",
                structuredInput: PlannerContext(
                    objective: "Resolve a delayed shipment complaint.",
                    customerTier: "plus"
                ),
                structuredInputSchemaName: "PlannerContext",
                structuredSections: [
                    AgentStructuredSection(
                        name: "browser_snapshot",
                        schemaName: "BrowserSnapshot",
                        payload: .object([
                            "pageTitle": .string("Order #1234"),
                            "status": .string("In transit"),
                        ])
                    ),
                ]
            ),
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

        let receivedMessage = await backend.receivedMessages().last
        XCTAssertEqual(receivedMessage?.text, "Draft a shipping reply.")
        XCTAssertEqual(receivedMessage?.structuredInput?.schemaName, "PlannerContext")
        XCTAssertEqual(receivedMessage?.structuredSections.count, 1)
        XCTAssertEqual(
            receivedMessage?.structuredInput?.payload,
            .object([
                "objective": .string("Resolve a delayed shipment complaint."),
                "customerTier": .string("plus"),
            ])
        )

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.text, "Draft a shipping reply.")
        XCTAssertFalse(messages.first?.text.contains("Resolve a delayed shipment complaint.") ?? true)
    }

    func testStructuredInputOnlyRequestDoesNotCreateVisibleUserTranscriptMessage() async throws {
        struct PlannerContext: Codable, Sendable {
            let objective: String
            let customerTier: String
        }

        let backend = InMemoryAgentBackend(
            structuredResponseText: #"{"reply":"I can work from the machine context alone.","priority":"normal"}"#
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured Input Only")
        let reply = try await runtime.sendMessage(
            AgentMessageRequest(
                text: "",
                structuredInput: PlannerContext(
                    objective: "Answer with a shipping status summary.",
                    customerTier: "pro"
                ),
                structuredInputSchemaName: "PlannerContext"
            ),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        XCTAssertEqual(
            reply,
            ShippingReplyDraft(
                reply: "I can work from the machine context alone.",
                priority: "normal"
            )
        )

        let receivedMessage = await backend.receivedMessages().last
        XCTAssertEqual(receivedMessage?.text, "")
        XCTAssertEqual(receivedMessage?.structuredInput?.schemaName, "PlannerContext")

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
    }

    func testImportedContentInitializerBuildsMessageWithSharedURLs() async throws {
        let importedContent = AgentImportedContent(textSnippets: ["Customer says the package arrived damaged."], urls: [URL(string: "https://example.com/delivery-update")!])
        let request = UserMessageRequest(prompt: "Summarize and draft a reply.", importedContent: importedContent)
        XCTAssertTrue(request.text.contains("Summarize and draft a reply."))
        XCTAssertTrue(request.text.contains("https://example.com/delivery-update"))
        XCTAssertTrue(request.text.contains("Customer says the package arrived damaged."))
    }

    func testImageOnlyMessageIsAcceptedAndPersisted() async throws {
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(), secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString), backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Images")
        let image = AgentImageAttachment.png(Data([0x89, 0x50, 0x4E, 0x47]))
        _ = try await runtime.sendMessage(UserMessageRequest(text: "", images: [image]), in: thread.id)

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.first?.images.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
    }

    func testAssistantImagesAreCommittedToThreadHistory() async throws {
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(), secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString), backend: ImageReplyAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Assistant Images")
        let reply = try await runtime.sendMessage(UserMessageRequest(text: "show me an image"), in: thread.id)

        XCTAssertEqual(reply, "Attached 1 image")
        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.images.count, 1)
    }

    func testRuntimeStreamsToolApprovalAndCompletion() async throws {
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(), secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString), backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(), tools: [.init(definition: ToolDefinition(name: "demo_lookup_profile", description: "Lookup profile", inputSchema: .object([:]), approvalPolicy: .requiresApproval), executor: AnyToolExecutor { invocation, _ in .success(invocation: invocation, text: "demo-result") })]))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let stream = try await runtime.streamMessage(UserMessageRequest(text: "please use the tool"), in: thread.id)

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
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(), secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString), backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(), tools: [.init(definition: ToolDefinition(name: "demo_lookup_profile", description: "Lookup profile", inputSchema: .object([:]), approvalPolicy: .requiresApproval), executor: AnyToolExecutor { invocation, _ in .success(invocation: invocation, text: "demo-result") })]))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let stream = try await runtime.streamMessage(UserMessageRequest(text: "please use the tool"), in: thread.id, expecting: ShippingReplyDraft.self)

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
        let runtime = try AgentRuntime(configuration: .init(authProvider: authProvider, secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString), backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Recovered Thread")
        _ = try await runtime.sendMessage(UserMessageRequest(text: "Hello after refresh"), in: thread.id)

        let refreshCount = await authProvider.refreshCount()
        let attemptedTokens = await backend.attemptedAccessTokens()
        let assistantCount = await runtime.messages(for: thread.id)
            .filter { $0.role == .assistant }
            .count

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(attemptedTokens.count, 2)
        XCTAssertEqual(attemptedTokens[0], "demo-access-token-initial")
        XCTAssertEqual(attemptedTokens[1], "demo-access-token-refreshed-1")
        XCTAssertEqual(assistantCount, 1)
    }

    func testCreateThreadRetriesUnauthorizedByRefreshingSession() async throws {
        let authProvider = RotatingDemoAuthProvider()
        let backend = UnauthorizedOnCreateThenSuccessBackend()
        let runtime = try AgentRuntime(configuration: .init(authProvider: authProvider, secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString), backend: backend, approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore()))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Recovered Thread")
        let refreshCountBeforeAssertions = await authProvider.refreshCount()
        XCTAssertEqual(thread.title, "Recovered Thread")
        let attemptedTokens = await backend.attemptedAccessTokens()
        XCTAssertEqual(refreshCountBeforeAssertions, 1)
        XCTAssertEqual(attemptedTokens.count, 2)
        XCTAssertEqual(attemptedTokens[0], "demo-access-token-initial")
        XCTAssertEqual(attemptedTokens[1], "demo-access-token-refreshed-1")
    }

    func testConfigurationRegistersInitialTools() async throws {
        let runtime = try AgentRuntime(configuration: .init(authProvider: DemoChatGPTAuthProvider(), secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString), backend: InMemoryAgentBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(), tools: [.init(definition: ToolDefinition(name: "demo_lookup_profile", description: "Lookup profile", inputSchema: .object([:]), approvalPolicy: .requiresApproval), executor: AnyToolExecutor { invocation, _ in .success(invocation: invocation, text: "demo-result") })]))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let stream = try await runtime.streamMessage(UserMessageRequest(text: "please use the tool"), in: thread.id)

        var sawToolResult = false
        for try await event in stream {
            if case let .toolCallFinished(result) = event {
                sawToolResult = true
                XCTAssertEqual(result.primaryText, "demo-result")
            }
        }

        XCTAssertTrue(sawToolResult)
    }

    func testStreamMessageReturnsAndYieldsUserMessageBeforeTurnStartupCompletes() async throws {
        let backend = DelayedBeginTurnBackend()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Immediate Stream")
        let streamTask = Task {
            try await runtime.streamMessage(UserMessageRequest(text: "Hello there"), in: thread.id)
        }

        await backend.waitForBeginTurnStart()
        let stream = try await awaitValue {
            try await streamTask.value
        }

        var iterator = stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        let secondEvent = try await iterator.next()

        switch firstEvent {
        case let .messageCommitted(message):
            XCTAssertEqual(message.role, .user)
            XCTAssertEqual(message.text, "Hello there")
        default:
            XCTFail("Expected the committed user message to arrive first.")
        }

        switch secondEvent {
        case let .threadStatusChanged(threadID, status):
            XCTAssertEqual(threadID, thread.id)
            XCTAssertEqual(status, .streaming)
        default:
            XCTFail("Expected a streaming status update after the committed user message.")
        }

        let messagesBeforeRelease = await runtime.messages(for: thread.id)
        XCTAssertEqual(messagesBeforeRelease.count, 1)
        XCTAssertEqual(messagesBeforeRelease.first?.text, "Hello there")

        await backend.releaseBeginTurn()
        while let _ = try await iterator.next() {}
    }

    func testSendMessagePublishesUserMessageObservationBeforeFinalReplyCompletes() async throws {
        let backend = DelayedBeginTurnBackend()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Observed Send")
        let observedUserMessage = expectation(description: "Observed the local user message")
        observedUserMessage.assertForOverFulfill = false
        var cancellables = Set<AnyCancellable>()

        runtime.observations
            .sink { observation in
                guard case let .messagesChanged(threadID, messages) = observation,
                      threadID == thread.id,
                      messages.last?.role == .user,
                      messages.last?.text == "Observe me"
                else {
                    return
                }
                observedUserMessage.fulfill()
            }
            .store(in: &cancellables)

        let sendTask = Task {
            try await runtime.sendMessage(UserMessageRequest(text: "Observe me"), in: thread.id)
        }

        await backend.waitForBeginTurnStart()
        await fulfillment(of: [observedUserMessage], timeout: 0.5)

        let messagesBeforeRelease = await runtime.messages(for: thread.id)
        XCTAssertEqual(messagesBeforeRelease.map(\.text), ["Observe me"])

        await backend.releaseBeginTurn()
        let reply = try await sendTask.value
        XCTAssertEqual(reply, "Echo: Observe me")
    }

    func testObserveMessagesPublishesInitialStateAndLocalPendingMessage() async throws {
        let backend = DelayedBeginTurnBackend()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Observe Messages")
        let observedInitialState = expectation(description: "Observed the initial empty message state")
        let observedPendingMessage = expectation(description: "Observed the local pending user message")
        observedPendingMessage.assertForOverFulfill = false
        var snapshots: [[String]] = []
        var cancellables = Set<AnyCancellable>()

        let publisher = runtime.observeMessages(in: thread.id)
        publisher
            .sink { messages in
                snapshots.append(messages.map(\.text))
                if messages.isEmpty {
                    observedInitialState.fulfill()
                }
                if messages.count == 1,
                   messages.last?.role == .user,
                   messages.last?.text == "Observe messages" {
                    observedPendingMessage.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [observedInitialState], timeout: 0.5)

        let sendTask = Task {
            try await runtime.sendMessage(UserMessageRequest(text: "Observe messages"), in: thread.id)
        }

        await backend.waitForBeginTurnStart()
        await fulfillment(of: [observedPendingMessage], timeout: 0.5)
        XCTAssertTrue(snapshots.contains([]))
        XCTAssertTrue(snapshots.contains(["Observe messages"]))

        await backend.releaseBeginTurn()
        let reply = try await sendTask.value
        XCTAssertEqual(reply, "Echo: Observe messages")
    }

    func testObserveThreadContextStatePublishesInitialAndCompactedValues() async throws {
        let backend = CompactingTestBackend()
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            contextCompaction: .init(
                isEnabled: true,
                mode: .manual,
                strategy: .preferRemoteThenLocal
            )
        )
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Observe Context")
        let longMessages = [
            String(repeating: "first message context ", count: 30),
            String(repeating: "second message context ", count: 30),
            String(repeating: "third message context ", count: 30),
        ]
        for message in longMessages {
            _ = try await runtime.sendMessage(UserMessageRequest(text: message), in: thread.id)
        }

        let observedInitialState = expectation(description: "Observed the initial context state")
        let observedCompactedState = expectation(description: "Observed the compacted context state")
        observedCompactedState.assertForOverFulfill = false
        var contexts: [AgentThreadContextState?] = []
        var cancellables = Set<AnyCancellable>()

        let publisher = runtime.observeThreadContextState(id: thread.id)
        publisher
            .sink { state in
                contexts.append(state)
                if state?.generation == 0 {
                    observedInitialState.fulfill()
                }
                if let state,
                   state.generation == 1,
                   state.lastCompactionReason == .manual {
                    observedCompactedState.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [observedInitialState], timeout: 0.5)

        let compacted = try await runtime.compactThreadContext(id: thread.id)
        XCTAssertEqual(compacted.generation, 1)

        await fulfillment(of: [observedCompactedState], timeout: 0.5)
        XCTAssertTrue(contexts.contains(where: { $0?.generation == 0 }))
        XCTAssertTrue(contexts.contains(where: { $0?.generation == 1 }))
    }

    func testObserveThreadContextUsagePublishesInitialAndCompactedUsage() async throws {
        let backend = CompactingTestBackend()
        let runtime = try makeHistoryRuntime(
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            contextCompaction: .init(
                isEnabled: true,
                mode: .manual,
                strategy: .preferRemoteThenLocal
            )
        )
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Observe Usage")
        let longMessages = [
            String(repeating: "first message context ", count: 30),
            String(repeating: "second message context ", count: 30),
            String(repeating: "third message context ", count: 30),
        ]
        for message in longMessages {
            _ = try await runtime.sendMessage(UserMessageRequest(text: message), in: thread.id)
        }

        let observedInitialUsage = expectation(description: "Observed the initial context usage")
        let observedCompactedUsage = expectation(description: "Observed compacted context usage")
        observedCompactedUsage.assertForOverFulfill = false
        var usages: [AgentThreadContextUsage?] = []
        var cancellables = Set<AnyCancellable>()

        runtime.observeThreadContextUsage(id: thread.id)
            .sink { usage in
                usages.append(usage)
                if let usage,
                   usage.visibleEstimatedTokenCount == usage.effectiveEstimatedTokenCount,
                   usage.visibleEstimatedTokenCount > 0 {
                    observedInitialUsage.fulfill()
                }
                if let usage, usage.estimatedTokenSavings > 0 {
                    observedCompactedUsage.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [observedInitialUsage], timeout: 0.5)

        _ = try await runtime.compactThreadContext(id: thread.id)

        await fulfillment(of: [observedCompactedUsage], timeout: 0.5)
        XCTAssertTrue(usages.contains(where: { ($0?.estimatedTokenSavings ?? 0) > 0 }))
    }

    func testSetTitlePublishesObservedThreadUpdateAndPersists() async throws {
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Original Title")
        let observedInitialThread = expectation(description: "Observed the initial thread")
        let observedRetitledThread = expectation(description: "Observed the retitled thread")
        observedRetitledThread.assertForOverFulfill = false
        var observedTitles: [String?] = []
        var cancellables = Set<AnyCancellable>()

        runtime.observeThread(id: thread.id)
            .sink { observedThread in
                observedTitles.append(observedThread?.title)
                if observedThread?.title == "Original Title" {
                    observedInitialThread.fulfill()
                }
                if observedThread?.title == "Updated Title" {
                    observedRetitledThread.fulfill()
                }
            }
            .store(in: &cancellables)

        await fulfillment(of: [observedInitialThread], timeout: 0.5)

        try await runtime.setTitle("Updated Title", for: thread.id)

        await fulfillment(of: [observedRetitledThread], timeout: 0.5)
        XCTAssertTrue(observedTitles.contains("Original Title"))
        XCTAssertTrue(observedTitles.contains("Updated Title"))

        let restoredRuntime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))
        _ = try await restoredRuntime.restore()

        let restoredThreads = await restoredRuntime.threads()
        let restoredThread = try XCTUnwrap(restoredThreads.first(where: { $0.id == thread.id }))
        XCTAssertEqual(restoredThread.title, "Updated Title")
    }
}

func drainStructuredStream<Output: Sendable>(
    _ stream: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>
) async throws {
    for try await _ in stream {}
}

func collectStructuredStreamFailures<Output: Sendable>(
    from stream: AsyncThrowingStream<AgentStructuredStreamEvent<Output>, Error>,
    into failures: inout [AgentStructuredOutputValidationFailure]
) async throws {
    for try await event in stream {
        if case let .structuredOutputValidationFailed(validationFailure) = event {
            failures.append(validationFailure)
        }
    }
}
