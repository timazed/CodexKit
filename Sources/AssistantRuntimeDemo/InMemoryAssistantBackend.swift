import AssistantRuntimeKit
import Foundation

public actor InMemoryAssistantBackend: AssistantBackend {
    private var threads: [String: AssistantThread] = [:]

    public init() {}

    public func createThread(session _: ChatGPTSession) async throws -> AssistantThread {
        let thread = AssistantThread(id: UUID().uuidString)
        threads[thread.id] = thread
        return thread
    }

    public func resumeThread(id: String, session _: ChatGPTSession) async throws -> AssistantThread {
        if let existing = threads[id] {
            return existing
        }

        let thread = AssistantThread(id: id)
        threads[id] = thread
        return thread
    }

    public func beginTurn(
        thread: AssistantThread,
        history _: [AssistantMessage],
        message: UserMessageRequest,
        tools: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AssistantTurnStreaming {
        let updatedThread = AssistantThread(
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

        return MockAssistantTurnSession(
            thread: updatedThread,
            message: message,
            selectedTool: selectedTool
        )
    }
}

public final class MockAssistantTurnSession: AssistantTurnStreaming, @unchecked Sendable {
    public let events: AsyncThrowingStream<BackendTurnEvent, Error>
    private let pendingResults: PendingToolResults

    public init(
        thread: AssistantThread,
        message: UserMessageRequest,
        selectedTool: ToolDefinition?
    ) {
        let pendingResults = PendingToolResults()
        self.pendingResults = pendingResults
        let turn = AssistantTurn(id: UUID().uuidString, threadID: thread.id)

        events = AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.turnStarted(turn))

                if let selectedTool {
                    for chunk in MockAssistantTurnSession.chunks(
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

                    let fullMessage = AssistantMessage(
                        threadID: thread.id,
                        role: .assistant,
                        text: "Tool result from \(selectedTool.name): \(responseText)"
                    )

                    continuation.yield(.assistantMessageCompleted(fullMessage))
                } else {
                    let response = "Echo: \(message.text)"
                    for chunk in MockAssistantTurnSession.chunks(for: response) {
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
                            AssistantMessage(
                                threadID: thread.id,
                                role: .assistant,
                                text: response
                            )
                        )
                    )
                }

                continuation.yield(
                    .turnCompleted(
                        AssistantTurnSummary(
                            threadID: thread.id,
                            turnID: turn.id,
                            usage: AssistantUsage(
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
