import Combine
import CodexKit
import XCTest

extension AgentRuntimeTests {
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
