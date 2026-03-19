import CodexKit
import Foundation

public actor InMemoryAgentBackend: AgentBackend {
    private var threads: [String: AgentThread] = [:]

    public init() {}

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
        tools: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        let updatedThread = AgentThread(
            id: thread.id,
            title: thread.title,
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
            selectedTool: selectedTool
        )
    }
}

public final class MockAgentTurnSession: AgentTurnStreaming, @unchecked Sendable {
    public let events: AsyncThrowingStream<AgentBackendEvent, Error>
    private let pendingResults: PendingToolResults

    public init(
        thread: AgentThread,
        message: UserMessageRequest,
        selectedTool: ToolDefinition?
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

                    let fullMessage = AgentMessage(
                        threadID: thread.id,
                        role: .assistant,
                        text: "Tool result from \(selectedTool.name): \(responseText)"
                    )

                    continuation.yield(.assistantMessageCompleted(fullMessage))
                } else {
                    let response = "Echo: \(message.text)"
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

                    continuation.yield(
                        .assistantMessageCompleted(
                            AgentMessage(
                                threadID: thread.id,
                                role: .assistant,
                                text: response
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
