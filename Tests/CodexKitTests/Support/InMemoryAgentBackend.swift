import CodexKit
import Foundation

public actor InMemoryAgentBackend: AgentBackend {
    public nonisolated let baseInstructions: String?

    private var threads: [String: AgentThread] = [:]
    private var beginTurnInstructions: [String] = []
    private var beginTurnResponseFormats: [AgentStructuredOutputFormat?] = []
    private var beginTurnMessages: [UserMessageRequest] = []
    private let structuredResponseText: String

    public init(
        baseInstructions: String? = nil,
        structuredResponseText: String = #"{"reply":"Structured echo","priority":"normal"}"#
    ) {
        self.baseInstructions = baseInstructions
        self.structuredResponseText = structuredResponseText
    }

    public func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        let thread = AgentThread(id: UUID().uuidString)
        threads[thread.id] = thread
        return thread
    }

    public func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        if let existing = threads[id] {
            return existing
        }

        let thread = AgentThread(id: id)
        threads[id] = thread
        return thread
    }

    public func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message: UserMessageRequest,
        instructions: String,
        responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        beginTurnInstructions.append(instructions)
        beginTurnResponseFormats.append(responseFormat)
        beginTurnMessages.append(message)
        let updatedThread = AgentThread(
            id: thread.id,
            title: thread.title,
            personaStack: thread.personaStack,
            skillIDs: thread.skillIDs,
            createdAt: thread.createdAt,
            updatedAt: Date(),
            status: .streaming
        )
        threads[thread.id] = updatedThread

        let selectedTool: ToolDefinition? = if message.text.localizedCaseInsensitiveContains("tool") {
            tools.first
        } else {
            nil
        }

        return MockAgentTurnSession(
            thread: updatedThread,
            message: message,
            selectedTool: selectedTool,
            structuredResponseText: (responseFormat != nil || streamedStructuredOutput != nil)
                ? structuredResponseText
                : nil,
            responseFormat: responseFormat,
            streamedStructuredOutput: streamedStructuredOutput
        )
    }

    public func receivedInstructions() -> [String] {
        beginTurnInstructions
    }

    public func receivedResponseFormats() -> [AgentStructuredOutputFormat?] {
        beginTurnResponseFormats
    }

    public func receivedMessages() -> [UserMessageRequest] {
        beginTurnMessages
    }
}

public final class MockAgentTurnSession: AgentTurnStreaming, @unchecked Sendable {
    public let events: AsyncThrowingStream<AgentBackendEvent, Error>
    private let pendingResults: PendingToolResults

    public init(
        thread: AgentThread,
        message: UserMessageRequest,
        selectedTool: ToolDefinition?,
        structuredResponseText: String?,
        responseFormat: AgentStructuredOutputFormat? = nil,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?
    ) {
        let pendingResults = PendingToolResults()
        self.pendingResults = pendingResults
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)

        events = AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.turnStarted(turn))

                if let selectedTool {
                    for chunk in MockAgentTurnSession.chunks(
                        for: "I need one host-defined tool to answer that. "
                    ) {
                        continuation.yield(
                            .assistantMessageDelta(
                                threadID: thread.id,
                                turnID: turn.id,
                                delta: chunk
                            )
                        )
                        try await Task.sleep(for: .milliseconds(40))
                    }

                    let invocation = ToolInvocation(
                        id: UUID().uuidString,
                        threadID: thread.id,
                        turnID: turn.id,
                        toolName: selectedTool.name,
                        arguments: .object([
                            "message": .string(message.text),
                            "requestedBy": .string("demo-backend"),
                        ])
                    )

                    continuation.yield(.toolCallRequested(invocation))
                    let result = try await pendingResults.wait(for: invocation.id)
                    let responseText = result.primaryText
                        ?? "The tool completed without returning display text."
                    let visibleText = "Tool result from \(selectedTool.name): \(responseText)"

                    for chunk in MockAgentTurnSession.chunks(for: visibleText) {
                        continuation.yield(
                            .assistantMessageDelta(
                                threadID: thread.id,
                                turnID: turn.id,
                                delta: chunk
                            )
                        )
                        try await Task.sleep(for: .milliseconds(30))
                    }

                    if let streamedStructuredOutput {
                        try MockAgentTurnSession.emitStructuredEvents(
                            responseText: structuredResponseText ?? #"{"reply":"Structured echo","priority":"normal"}"#,
                            request: streamedStructuredOutput,
                            into: continuation
                        )
                    }

                    let structuredMetadata = try MockAgentTurnSession.structuredMetadata(
                        responseText: structuredResponseText,
                        request: streamedStructuredOutput,
                        responseFormat: responseFormat
                    )

                    let fullMessage = AgentMessage(
                        threadID: thread.id,
                        role: .assistant,
                        text: visibleText,
                        structuredOutput: structuredMetadata
                    )

                    continuation.yield(.assistantMessageCompleted(fullMessage))
                } else {
                    let visibleText = "Echo: \(message.text)"
                    let response = streamedStructuredOutput == nil
                        ? (structuredResponseText ?? visibleText)
                        : visibleText
                    for chunk in MockAgentTurnSession.chunks(for: response) {
                        continuation.yield(
                            .assistantMessageDelta(
                                threadID: thread.id,
                                turnID: turn.id,
                                delta: chunk
                            )
                        )
                        try await Task.sleep(for: .milliseconds(35))
                    }

                    if let streamedStructuredOutput {
                        try MockAgentTurnSession.emitStructuredEvents(
                            responseText: structuredResponseText ?? #"{"reply":"Structured echo","priority":"normal"}"#,
                            request: streamedStructuredOutput,
                            into: continuation
                        )
                    }

                    let structuredMetadata = try MockAgentTurnSession.structuredMetadata(
                        responseText: structuredResponseText,
                        request: streamedStructuredOutput,
                        responseFormat: responseFormat
                    )

                    continuation.yield(
                        .assistantMessageCompleted(
                            AgentMessage(
                                threadID: thread.id,
                                role: .assistant,
                                text: response,
                                structuredOutput: structuredMetadata
                            )
                        )
                    )
                }

                continuation.yield(
                    .turnCompleted(
                        AgentTurnSummary(
                            threadID: thread.id,
                            turnID: turn.id,
                            usage: AgentUsage(
                                inputTokens: message.text.count,
                                cachedInputTokens: 0,
                                outputTokens: 32
                            )
                        )
                    )
                )
                continuation.finish()
            }
        }
    }

    public func submitToolResult(
        _ result: ToolResultEnvelope,
        for invocationID: String
    ) async throws {
        await pendingResults.resolve(result, for: invocationID)
    }

    private static func chunks(for text: String, chunkSize: Int = 16) -> [String] {
        var chunks: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if current.count >= chunkSize {
                chunks.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private static func emitStructuredEvents(
        responseText: String,
        request: AgentStreamedStructuredOutputRequest,
        into continuation: AsyncThrowingStream<AgentBackendEvent, Error>.Continuation
    ) throws {
        guard let data = responseText.data(using: .utf8) else {
            continuation.yield(
                .structuredOutputValidationFailed(
                    AgentStructuredOutputValidationFailure(
                        stage: .committed,
                        message: "The in-memory structured output was not UTF-8.",
                        rawPayload: responseText
                    )
                )
            )
            return
        }

        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        if request.options.emitPartials {
            continuation.yield(.structuredOutputPartial(value))
        }
        continuation.yield(.structuredOutputCommitted(value))
    }

    private static func structuredMetadata(
        responseText: String?,
        request: AgentStreamedStructuredOutputRequest?,
        responseFormat: AgentStructuredOutputFormat?
    ) throws -> AgentStructuredOutputMetadata? {
        guard let responseText,
              let data = responseText.data(using: .utf8)
        else {
            return nil
        }

        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return AgentStructuredOutputMetadata(
            formatName: request?.responseFormat.name ?? responseFormat?.name ?? "structured_output",
            payload: value
        )
    }
}

actor PendingToolResults {
    private var waiting: [String: CheckedContinuation<ToolResultEnvelope, Error>] = [:]
    private var resolved: [String: ToolResultEnvelope] = [:]

    func wait(for invocationID: String) async throws -> ToolResultEnvelope {
        if let resolved = resolved.removeValue(forKey: invocationID) {
            return resolved
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiting[invocationID] = continuation
        }
    }

    func resolve(_ result: ToolResultEnvelope, for invocationID: String) {
        if let continuation = waiting.removeValue(forKey: invocationID) {
            continuation.resume(returning: result)
        } else {
            resolved[invocationID] = result
        }
    }
}
