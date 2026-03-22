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
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.images, [])
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.text, "Hello from legacy state")
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

actor RotatingDemoAuthProvider: ChatGPTAuthProviding {
    private var refreshInvocationCount = 0

    func signInInteractively() async throws -> ChatGPTSession {
        ChatGPTSession(
            accessToken: "demo-access-token-initial",
            refreshToken: "demo-refresh-token",
            account: ChatGPTAccount(
                id: "demo-account",
                email: "demo@example.com",
                plan: .plus
            ),
            acquiredAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            isExternallyManaged: true
        )
    }

    func refresh(
        session: ChatGPTSession,
        reason _: ChatGPTAuthRefreshReason
    ) async throws -> ChatGPTSession {
        refreshInvocationCount += 1
        var refreshed = session
        refreshed.accessToken = "demo-access-token-refreshed-\(refreshInvocationCount)"
        refreshed.acquiredAt = Date()
        refreshed.expiresAt = Date().addingTimeInterval(3600)
        return refreshed
    }

    func signOut(session _: ChatGPTSession?) async {}

    func refreshCount() -> Int {
        refreshInvocationCount
    }
}

actor UnauthorizedThenSuccessBackend: AgentBackend {
    private var didThrowUnauthorized = false
    private var accessTokensByAttempt: [String] = []

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        tools _: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        accessTokensByAttempt.append(session.accessToken)
        if !didThrowUnauthorized {
            didThrowUnauthorized = true
            throw AgentRuntimeError.unauthorized("Simulated unauthorized")
        }

        return MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil
        )
    }

    func attemptedAccessTokens() -> [String] {
        accessTokensByAttempt
    }
}

actor UnauthorizedOnCreateThenSuccessBackend: AgentBackend {
    private var didThrowUnauthorized = false
    private var accessTokensByAttempt: [String] = []

    func createThread(session: ChatGPTSession) async throws -> AgentThread {
        accessTokensByAttempt.append(session.accessToken)
        if !didThrowUnauthorized {
            didThrowUnauthorized = true
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
        message _: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        MockAgentTurnSession(
            thread: thread,
            message: .init(text: ""),
            selectedTool: nil,
            structuredResponseText: nil
        )
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
        message _: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        ImageReplyTurn(threadID: thread.id)
    }
}

final class ImageReplyTurn: AgentTurnStreaming, @unchecked Sendable {
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
            countsByKind: [:]
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
