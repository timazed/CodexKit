import Foundation

extension AgentRuntime {
    func hasCommittedMessage(id: String, in threadID: String) async throws -> Bool {
        try await findHistoryRecord(in: threadID, kinds: [.message], relationship: .message(id: id)) {
            guard case let .message(message) = $0.item else { return false }
            return message.id == id
        } != nil
    }

    func hasStoredTurnStart(turnID: String, in threadID: String) async throws -> Bool {
        try await findHistoryRecord(in: threadID, kinds: [.systemEvent], turnID: turnID) {
            guard case let .systemEvent(event) = $0.item else { return false }
            return event.type == .turnStarted && event.turnID == turnID
        } != nil
    }

    func hasStoredToolCall(invocationID: String, in threadID: String) async throws -> Bool {
        try await findHistoryRecord(in: threadID, kinds: [.toolCall], relationship: .toolInvocation(id: invocationID)) {
            guard case let .toolCall(call) = $0.item else { return false }
            return call.invocation.id == invocationID
        } != nil
    }

    func hasStoredStructuredOutput(turnID: String, formatName: String, in threadID: String) async throws -> Bool {
        try await findHistoryRecord(in: threadID, kinds: [.structuredOutput], turnID: turnID) {
            guard case let .structuredOutput(output) = $0.item else { return false }
            return output.turnID == turnID && output.metadata.formatName == formatName
        } != nil
    }

    func storedToolResult(invocationID: String, in threadID: String) async throws -> ToolResultEnvelope? {
        let record = try await findHistoryRecord(in: threadID, kinds: [.toolResult], relationship: .toolInvocation(id: invocationID)) {
            guard case let .toolResult(result) = $0.item else { return false }
            return result.result.invocationID == invocationID
        }
        guard let record, case let .toolResult(result) = record.item else { return nil }
        return result.result
    }

    /// Live history is a cache. Flush evicted writes before consulting the
    /// durable relationship/turn indexes; lookup failures must never run a tool.
    private func findHistoryRecord(
        in threadID: String, kinds: Set<AgentHistoryItemKind>, turnID: String? = nil,
        relationship: AgentHistoryRelationship? = nil,
        matching predicate: @Sendable (AgentHistoryRecord) -> Bool
    ) async throws -> AgentHistoryRecord? {
        if let record = state.historyByThread[threadID]?.last(where: predicate) { return record }
        guard state.partiallyLoadedThreadIDs.contains(threadID) else { return nil }
        if let active = activePersistenceTask { try await active.task.value }
        try await persistState()
        var query = HistoryItemsQuery(threadID: threadID, kinds: kinds, turnID: turnID,
            relationship: relationship, sort: .sequence(.descending),
            page: .init(limit: relationship == nil ? 128 : 2, direction: .backward))
        while true {
            try Task.checkCancellation()
            let page = try await execute(query)
            if let record = page.records.first(where: predicate) { return record }
            guard let cursor = page.nextCursor else { return nil }
            query.page?.cursor = cursor
        }
    }
}
