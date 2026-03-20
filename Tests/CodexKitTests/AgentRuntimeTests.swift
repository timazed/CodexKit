import CodexKit
import XCTest

private struct AutoApprovalPresenter: ApprovalPresenting {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        XCTAssertEqual(request.toolInvocation.toolName, "demo_lookup_profile")
        return .approved
    }
}

final class AgentRuntimeTests: XCTestCase {
    func testThreadPersonaUsesBackendBaseInstructionsWhenRuntimeBaseIsUnset() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
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

        let supportPersona = AgentPersonaStack(layers: [
            .init(
                name: "domain",
                instructions: "You are an expert customer support agent for a shipping app."
            ),
            .init(
                name: "style",
                instructions: "Be concise, calm, and action-oriented."
            ),
        ])

        let thread = try await runtime.createThread(
            title: "Support Chat",
            personaStack: supportPersona
        )
        let stream = try await runtime.sendMessage(
            UserMessageRequest(text: "How do I track my order?"),
            in: thread.id
        )

        for try await _ in stream {}

        let receivedInstructions = await backend.receivedInstructions()
        let resolvedInstructions = try XCTUnwrap(receivedInstructions.last)
        XCTAssertTrue(resolvedInstructions.contains("Base host instructions."))
        XCTAssertTrue(resolvedInstructions.contains("Thread Persona Layers:"))
        XCTAssertTrue(resolvedInstructions.contains("[domain]"))
        XCTAssertTrue(resolvedInstructions.contains("[style]"))
        XCTAssertLessThan(
            try XCTUnwrap(resolvedInstructions.range(of: "Base host instructions.")?.lowerBound),
            try XCTUnwrap(resolvedInstructions.range(of: "Thread Persona Layers:")?.lowerBound)
        )
    }

    func testTurnPersonaOverrideAppliesOnlyToCurrentTurn() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
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

        let supportPersona = AgentPersonaStack(layers: [
            .init(
                name: "support",
                instructions: "Act as a calm support specialist."
            ),
        ])
        let reviewerOverride = AgentPersonaStack(layers: [
            .init(
                name: "reviewer",
                instructions: "For this reply only, act as a strict reviewer and call out risks first."
            ),
        ])

        let thread = try await runtime.createThread(personaStack: supportPersona)

        let firstStream = try await runtime.sendMessage(
            UserMessageRequest(
                text: "Review this architecture.",
                personaOverride: reviewerOverride
            ),
            in: thread.id
        )
        for try await _ in firstStream {}

        let secondStream = try await runtime.sendMessage(
            UserMessageRequest(text: "Now just answer normally."),
            in: thread.id
        )
        for try await _ in secondStream {}

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("Turn Persona Override:"))
        XCTAssertTrue(instructions[0].contains("[reviewer]"))
        XCTAssertFalse(instructions[1].contains("Turn Persona Override:"))
        XCTAssertFalse(instructions[1].contains("[reviewer]"))
        XCTAssertTrue(instructions[1].contains("[support]"))
    }

    func testSetPersonaStackAffectsFutureTurnsOnly() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
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

        let supportPersona = AgentPersonaStack(layers: [
            .init(name: "support", instructions: "Act as a support agent.")
        ])
        let plannerPersona = AgentPersonaStack(layers: [
            .init(name: "planner", instructions: "Act as a careful technical planner.")
        ])

        let thread = try await runtime.createThread(personaStack: supportPersona)

        let firstStream = try await runtime.sendMessage(
            UserMessageRequest(text: "Help me with support."),
            in: thread.id
        )
        for try await _ in firstStream {}

        try await runtime.setPersonaStack(plannerPersona, for: thread.id)

        let secondStream = try await runtime.sendMessage(
            UserMessageRequest(text: "Plan the migration."),
            in: thread.id
        )
        for try await _ in secondStream {}

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("[support]"))
        XCTAssertFalse(instructions[0].contains("[planner]"))
        XCTAssertTrue(instructions[1].contains("[planner]"))
        XCTAssertFalse(instructions[1].contains("[support]"))
    }

    func testThreadPersonaStackPersistsAcrossRestore() async throws {
        let stateStore = InMemoryRuntimeStateStore()
        let secureStore = KeychainSessionSecureStore(
            service: "CodexKitTests.ChatGPTSession",
            account: UUID().uuidString
        )
        let personaStack = AgentPersonaStack(layers: [
            .init(name: "planner", instructions: "Act as a careful technical planner.")
        ])

        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: secureStore,
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()
        let thread = try await runtime.createThread(
            title: "Planning",
            personaStack: personaStack
        )

        let restoredRuntime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: secureStore,
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))

        _ = try await restoredRuntime.restore()

        let restoredStack = try await restoredRuntime.personaStack(for: thread.id)
        let restoredThreads = await restoredRuntime.threads()
        XCTAssertEqual(restoredStack, personaStack)
        XCTAssertEqual(restoredThreads.first?.personaStack, personaStack)
    }

    func testSetPersonaStackThrowsForMissingThread() async throws {
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

        await XCTAssertThrowsErrorAsync(
            try await runtime.setPersonaStack(
                AgentPersonaStack(layers: [
                    .init(name: "planner", instructions: "Act as a planner.")
                ]),
                for: "missing-thread"
            )
        ) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .threadNotFound("missing-thread"))
        }
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

        let thread = try await runtime.createThread()
        let image = AgentImageAttachment.png(Data([0x89, 0x50, 0x4E, 0x47]))

        let stream = try await runtime.sendMessage(
            UserMessageRequest(
                text: "",
                images: [image]
            ),
            in: thread.id
        )
        for try await _ in stream {}

        let messages = await runtime.messages(for: thread.id)
        let userMessage = try XCTUnwrap(messages.first(where: { $0.role == .user }))
        XCTAssertEqual(userMessage.images, [image])
        XCTAssertEqual(userMessage.text, "")
        XCTAssertEqual(userMessage.displayText, "Attached 1 image")

        let threads = await runtime.threads()
        let updatedThread = try XCTUnwrap(threads.first(where: { $0.id == thread.id }))
        XCTAssertEqual(updatedThread.title, "Image message")
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

        let thread = try await runtime.createThread()
        let stream = try await runtime.sendMessage(
            UserMessageRequest(text: "Generate an image"),
            in: thread.id
        )
        for try await _ in stream {}

        let messages = await runtime.messages(for: thread.id)
        let assistantMessage = try XCTUnwrap(messages.first(where: { $0.role == .assistant }))
        XCTAssertEqual(assistantMessage.images.count, 1)
        XCTAssertEqual(assistantMessage.images.first?.mimeType, "image/png")
    }

    func testRestoreDecodesLegacyStateWithoutPersonaOrImages() async throws {
        let legacyStateJSON = """
        {
          "threads": [
            {
              "id": "thread-1",
              "title": "Legacy Thread",
              "createdAt": "2026-03-20T00:00:00Z",
              "updatedAt": "2026-03-20T00:00:00Z",
              "status": "idle"
            }
          ],
          "messagesByThread": {
            "thread-1": [
              {
                "id": "message-1",
                "threadID": "thread-1",
                "role": "assistant",
                "text": "Hello from legacy state",
                "createdAt": "2026-03-20T00:00:00Z"
              }
            ]
          }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(StoredRuntimeState.self, from: Data(legacyStateJSON.utf8))

        XCTAssertEqual(state.threads.count, 1)
        XCTAssertEqual(state.threads.first?.personaStack, nil)
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.images, [])
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.text, "Hello from legacy state")
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
            stateStore: InMemoryRuntimeStateStore()
        ))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        try await runtime.replaceTool(
            ToolDefinition(
                name: "demo_lookup_profile",
                description: "Lookup profile",
                inputSchema: .object([:]),
                approvalPolicy: .requiresApproval
            ),
            executor: AnyToolExecutor { invocation, _ in
                .success(invocation: invocation, text: "demo-result")
            }
        )

        let thread = try await runtime.createThread()
        let stream = try await runtime.sendMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )

        var sawApproval = false
        var sawToolResult = false
        var sawTurnCompleted = false

        for try await event in stream {
            switch event {
            case .approvalRequested:
                sawApproval = true
            case let .toolCallFinished(result):
                sawToolResult = true
                XCTAssertEqual(result.primaryText, "demo-result")
            case .turnCompleted:
                sawTurnCompleted = true
            default:
                break
            }
        }

        XCTAssertTrue(sawApproval)
        XCTAssertTrue(sawToolResult)
        XCTAssertTrue(sawTurnCompleted)

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(messages.filter { $0.role == .assistant }.count, 1)
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
        let stream = try await runtime.sendMessage(
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

private actor ImageReplyAgentBackend: AgentBackend {
    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: UserMessageRequest,
        instructions _: String,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        ImageReplyTurn(threadID: thread.id)
    }
}

private final class ImageReplyTurn: AgentTurnStreaming, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentBackendEvent, Error>

    init(threadID: String) {
        let image = AgentImageAttachment.png(Data([0x89, 0x50, 0x4E, 0x47]))
        let turn = AgentTurn(id: UUID().uuidString, threadID: threadID)

        events = AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(turn))
            continuation.yield(
                .assistantMessageCompleted(
                    AgentMessage(
                        threadID: threadID,
                        role: .assistant,
                        text: "",
                        images: [image]
                    )
                )
            )
            continuation.yield(
                .turnCompleted(
                    AgentTurnSummary(
                        threadID: threadID,
                        turnID: turn.id,
                        usage: AgentUsage(inputTokens: 1, outputTokens: 1)
                    )
                )
            )
            continuation.finish()
        }
    }

    func submitToolResult(
        _: ToolResultEnvelope,
        for _: String
    ) async throws {}
}
