import CodexKit
import XCTest

// MARK: - Shared Fixtures

struct AutoApprovalPresenter: ApprovalPresenting {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        XCTAssertEqual(request.toolInvocation.toolName, "demo_lookup_profile")
        return .approved
    }
}

struct ShippingReplyDraft: AgentStructuredOutput, Equatable {
    let reply: String
    let priority: String

    static let responseFormat = AgentStructuredOutputFormat(
        name: "shipping_reply_draft",
        description: "A concise shipping support reply draft.",
        schema: .object(
            properties: [
                "reply": .string(),
                "priority": .string(),
            ],
            required: ["reply", "priority"],
            additionalProperties: false
        )
    )
}

final class AgentRuntimeTests: XCTestCase {
    // MARK: Legacy State

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
        XCTAssertEqual(state.threads.first?.memoryContext, nil)
        XCTAssertEqual(state.threads.first?.configuration, nil)
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.images, [])
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.structuredOutput, nil)
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.toolInteraction, nil)
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.text, "Hello from legacy state")
    }

    func testThreadConfigurationCanBeUpdatedAndRestored() async throws {
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())

        let thread = try await runtime.createThread(
            title: "Configurable",
            configuration: AgentThreadConfiguration(
                model: "gpt-5",
                reasoningEffort: .medium
            )
        )
        let updated = try await runtime.updateThreadConfiguration(
            for: thread.id,
            reasoningEffort: .high
        )

        XCTAssertEqual(updated.model, "gpt-5")
        XCTAssertEqual(updated.reasoningEffort, .high)

        let restoredRuntime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.ChatGPTSession", account: UUID().uuidString),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))
        _ = try await restoredRuntime.restore()

        let restoredThreads = await restoredRuntime.activeThreads()
        let restoredThread = try XCTUnwrap(restoredThreads.first(where: { $0.id == thread.id }))
        XCTAssertEqual(restoredThread.configuration?.model, "gpt-5")
        XCTAssertEqual(restoredThread.configuration?.reasoningEffort, .high)
    }

    func temporaryFile(
        with content: String,
        pathExtension: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Backend/Test Doubles

actor UnauthorizedThenSuccessBackend: AgentBackend {
    private var didThrowUnauthorized = false
    private var accessTokensByAttempt: [String] = []
    private let secureStore: KeychainSessionSecureStore?
    private let replacementSession: ChatGPTSession?

    init(
        secureStore: KeychainSessionSecureStore? = nil,
        replacementSession: ChatGPTSession? = nil
    ) {
        self.secureStore = secureStore
        self.replacementSession = replacementSession
    }

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> AgentTurnStream {
        accessTokensByAttempt.append(session.accessToken)
        if !didThrowUnauthorized {
            didThrowUnauthorized = true
            if let secureStore, let replacementSession {
                try secureStore.saveSession(replacementSession)
            }
            throw AgentRuntimeError.unauthorized("Simulated unauthorized")
        }

        return MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil,
            streamedStructuredOutput: nil
        ).stream
    }

    func attemptedAccessTokens() -> [String] {
        accessTokensByAttempt
    }
}

actor UnauthorizedOnCreateThenSuccessBackend: AgentBackend {
    private var didThrowUnauthorized = false
    private var accessTokensByAttempt: [String] = []
    private let secureStore: KeychainSessionSecureStore?
    private let replacementSession: ChatGPTSession?

    init(
        secureStore: KeychainSessionSecureStore? = nil,
        replacementSession: ChatGPTSession? = nil
    ) {
        self.secureStore = secureStore
        self.replacementSession = replacementSession
    }

    func createThread(session: ChatGPTSession) async throws -> AgentThread {
        accessTokensByAttempt.append(session.accessToken)
        if !didThrowUnauthorized {
            didThrowUnauthorized = true
            if let secureStore, let replacementSession {
                try secureStore.saveSession(replacementSession)
            }
            throw AgentRuntimeError.unauthorized("Simulated unauthorized during createThread")
        }

        return AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        MockAgentTurnSession(
            thread: thread,
            message: .init(text: ""),
            selectedTool: nil,
            structuredResponseText: nil,
            streamedStructuredOutput: nil
        ).stream
    }

    func attemptedAccessTokens() -> [String] {
        accessTokensByAttempt
    }
}

actor ImageReplyAgentBackend: AgentBackend {
    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        ImageReplyTurn(threadID: thread.id).stream
    }
}

actor OptionalStructuredMissingBackend: AgentBackend {
    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil,
            streamedStructuredOutput: nil
        ).stream
    }
}

final class ImageReplyTurn {
    let stream: AgentTurnStream

    init(threadID: String) {
        let image = AgentImageAttachment.png(Data([0x89, 0x50, 0x4E, 0x47]))
        let turn = AgentTurn(id: UUID().uuidString, threadID: threadID)

        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
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
        stream = AgentTurnStream(events: events)
    }
}

actor ThrowingMemoryStore: MemoryStoring {
    func put(_ record: MemoryRecord) async throws {}

    func putMany(_ records: [MemoryRecord]) async throws {}

    func upsert(_ record: MemoryRecord, dedupeKey: String) async throws {}

    func query(_ query: MemoryQuery) async throws -> MemoryQueryResult {
        throw NSError(
            domain: "CodexKitTests.ThrowingMemoryStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Simulated memory failure"]
        )
    }

    func record(id: String, namespace: String) async throws -> MemoryRecord? {
        nil
    }

    func list(_ query: MemoryRecordListQuery) async throws -> [MemoryRecord] {
        []
    }

    func diagnostics(namespace: String) async throws -> MemoryStoreDiagnostics {
        .init(
            namespace: namespace,
            implementation: "throwing",
            schemaVersion: nil,
            totalRecords: 0,
            activeRecords: 0,
            archivedRecords: 0,
            countsByScope: [:],
            countsByCategory: [:]
        )
    }

    func compact(_ request: MemoryCompactionRequest) async throws {}

    func archive(ids: [String], namespace: String) async throws {}

    func delete(ids: [String], namespace: String) async throws {}

    func pruneExpired(now: Date, namespace: String) async throws -> Int {
        0
    }
}

actor RecordingMemoryObserver: MemoryObserving {
    private var observedEvents: [MemoryObservationEvent] = []

    func handle(event: MemoryObservationEvent) async {
        observedEvents.append(event)
    }

    func events() -> [MemoryObservationEvent] {
        observedEvents
    }
}
