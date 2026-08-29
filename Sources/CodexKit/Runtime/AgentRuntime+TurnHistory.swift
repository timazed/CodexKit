import Foundation

extension AgentRuntime {
    func validateClientRequestID(_ clientRequestID: String?) throws {
        guard let clientRequestID else { return }
        guard !clientRequestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              clientRequestID.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount
        else {
            throw AgentRuntimeError.invalidClientRequestID()
        }
    }

    func validateTurnCompletion(
        _ summary: AgentTurnSummary,
        expectedThreadID: String,
        currentTurnID: String?
    ) throws {
        guard summary.threadID == expectedThreadID,
              let currentTurnID,
              summary.turnID == currentTurnID else {
            throw AgentRuntimeError.invalidTurnCompletion()
        }
    }

    func validateTurnStart(
        _ turn: AgentTurn,
        expectedThreadID: String,
        currentTurnID: String?
    ) throws {
        guard turn.threadID == expectedThreadID,
              currentTurnID == nil,
              !turn.id.isEmpty,
              turn.id.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
            throw AgentRuntimeError.invalidTurnStart()
        }
    }

    @discardableResult
    func validateActiveTurn(
        expectedThreadID: String,
        currentTurnID: String?
    ) throws -> String {
        guard !expectedThreadID.isEmpty, let currentTurnID else {
            throw AgentRuntimeError.invalidBackendTurnEvent()
        }
        return currentTurnID
    }

    func validateBackendTurnEvent(
        threadID eventThreadID: String,
        turnID eventTurnID: String,
        expectedThreadID: String,
        currentTurnID: String?
    ) throws {
        let activeTurnID = try validateActiveTurn(
            expectedThreadID: expectedThreadID,
            currentTurnID: currentTurnID
        )
        guard eventThreadID == expectedThreadID,
              eventTurnID == activeTurnID else {
            throw AgentRuntimeError.invalidBackendTurnEvent()
        }
    }

    func validateAssistantMessageEvent(
        _ message: AgentMessage,
        expectedThreadID: String,
        currentTurnID: String?
    ) throws {
        try validateActiveTurn(
            expectedThreadID: expectedThreadID,
            currentTurnID: currentTurnID
        )
        guard message.threadID == expectedThreadID,
              message.role == .assistant else {
            throw AgentRuntimeError.invalidBackendTurnEvent()
        }
    }

    func validateProviderContextEvent(
        threadID eventThreadID: String,
        expectedThreadID: String,
        currentTurnID: String?
    ) throws {
        try validateActiveTurn(
            expectedThreadID: expectedThreadID,
            currentTurnID: currentTurnID
        )
        guard eventThreadID == expectedThreadID else {
            throw AgentRuntimeError.invalidBackendTurnEvent()
        }
    }

    /// Runtime state already contains the visible pending user message before
    /// backend startup. It must remain available for future history without
    /// also being sent as both history and the current request.
    func historyBeforePendingMessage(
        in threadID: String,
        pendingUserMessage: AgentMessage?
    ) -> [AgentMessage] {
        var history = effectiveHistory(for: threadID)
        if let pendingUserMessage,
           history.last?.id == pendingUserMessage.id {
            history.removeLast()
        }
        return history
    }
}
