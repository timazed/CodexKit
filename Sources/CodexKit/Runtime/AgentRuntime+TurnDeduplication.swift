import Foundation

extension AgentRuntime {
    func hasCommittedMessage(
        id: String,
        in threadID: String
    ) -> Bool {
        state.messagesByThread[threadID, default: []].contains { $0.id == id }
    }

    func hasStoredTurnStart(
        turnID: String,
        in threadID: String
    ) -> Bool {
        (state.historyByThread[threadID] ?? []).contains { record in
            guard case let .systemEvent(event) = record.item else { return false }
            return event.type == .turnStarted && event.turnID == turnID
        }
    }

    func hasStoredToolCall(
        invocationID: String,
        in threadID: String
    ) -> Bool {
        (state.historyByThread[threadID] ?? []).contains { record in
            guard case let .toolCall(call) = record.item else { return false }
            return call.invocation.id == invocationID
        }
    }

    func hasStoredStructuredOutput(
        turnID: String,
        formatName: String,
        in threadID: String
    ) -> Bool {
        (state.historyByThread[threadID] ?? []).contains { record in
            guard case let .structuredOutput(output) = record.item else { return false }
            return output.turnID == turnID && output.metadata.formatName == formatName
        }
    }

    func storedToolResult(
        invocationID: String,
        in threadID: String
    ) -> ToolResultEnvelope? {
        for record in (state.historyByThread[threadID] ?? []).reversed() {
            guard case let .toolResult(result) = record.item,
                  result.result.invocationID == invocationID else {
                continue
            }
            return result.result
        }
        return nil
    }
}
