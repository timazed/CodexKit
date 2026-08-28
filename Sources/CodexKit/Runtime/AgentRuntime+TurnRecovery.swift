import Foundation

extension AgentRuntime {
    /// Returns the newest stored provider checkpoint that has no matching terminal turn event.
    public func pendingTurnRecoveryCheckpoint(
        in threadID: String
    ) async throws -> AgentTurnRecoveryCheckpoint? {
        if let checkpoint = activeRecoveryCheckpoint(in: threadID) {
            return checkpoint
        }
        return try await persistedRecoveryCheckpoint(in: threadID)
    }

    /// Reattaches to a stored provider response without resubmitting the original request.
    /// Returns `nil` when the thread has no recoverable turn.
    public func resumePendingTurn(
        in threadID: String
    ) async throws -> AsyncThrowingStream<AgentEvent, Error>? {
        guard let recoveryBackend = backend as? any AgentBackendTurnRecoverySupporting else {
            return nil
        }
        if thread(for: threadID) == nil {
            guard try await persistedRecoveryCheckpoint(in: threadID) != nil else {
                return nil
            }
            _ = try await resumeThread(id: threadID)
        }
        guard let thread = thread(for: threadID) else {
            return nil
        }
        let checkpoint = if let active = activeRecoveryCheckpoint(in: threadID) {
            active
        } else {
            try await persistedRecoveryCheckpoint(in: threadID)
        }
        guard let checkpoint else { return nil }

        let session = try await sessionManager.requireSession()
        let tools = await toolRegistry.allDefinitions()
        let resolvedTurnSkills = try resolveTurnSkills(
            thread: thread,
            message: checkpoint.request
        )
        let turnStream = try await recoveryBackend.resumeTurn(
            from: checkpoint,
            history: effectiveHistory(for: threadID),
            tools: tools,
            session: session
        )
        try await setThreadStatus(.streaming, for: threadID)

        return AsyncThrowingStream { continuation in
            continuation.yield(.threadStatusChanged(threadID: threadID, status: .streaming))
            let cancellationHandle = AgentTurnCancellationHandle()
            let producerTask = Task {
                let activity = await self.backgroundActivityProvider.beginActivity(
                    named: "CodexKit recovered agent turn",
                    expirationHandler: { cancellationHandle.cancel() }
                )
                defer {
                    activity.end()
                    cancellationHandle.clear()
                }
                await self.consumeTurnStream(
                    turnStream,
                    for: threadID,
                    userMessage: nil,
                    session: session,
                    resolvedTurnSkills: resolvedTurnSkills,
                    storesTurnState: true,
                    continuation: continuation
                )
            }
            cancellationHandle.install { producerTask.cancel() }
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    cancellationHandle.cancel()
                }
            }
        }
    }

    func activeRecoveryCheckpoint(
        in threadID: String,
        turnID: String? = nil
    ) -> AgentTurnRecoveryCheckpoint? {
        var terminalTurnIDs = Set<String>()
        for record in (state.historyByThread[threadID] ?? []).reversed() {
            guard case let .systemEvent(event) = record.item else { continue }
            if event.type == .turnCompleted || event.type == .turnFailed,
               let eventTurnID = event.turnID {
                terminalTurnIDs.insert(eventTurnID)
                continue
            }
            guard event.type == .turnRecoveryCheckpointUpdated,
                  let checkpoint = event.recoveryCheckpoint,
                  turnID == nil || checkpoint.turnID == turnID,
                  !terminalTurnIDs.contains(checkpoint.turnID) else {
                continue
            }
            return checkpoint
        }
        return nil
    }

    /// Lazy database activation intentionally hydrates model-facing messages,
    /// not the complete system-event history. Recovery therefore reads bounded,
    /// indexed history pages from the durable store instead of assuming the
    /// active working set contains a checkpoint written by an earlier process.
    func persistedRecoveryCheckpoint(
        in threadID: String
    ) async throws -> AgentTurnRecoveryCheckpoint? {
        var cursor: AgentHistoryCursor?
        var terminalTurnIDs = Set<String>()

        while true {
            let result = try await execute(HistoryItemsQuery(
                threadID: threadID,
                kinds: [.systemEvent],
                includeRedacted: false,
                includeCompactionEvents: true,
                sort: .sequence(.descending),
                page: AgentQueryPage(
                    limit: AgentStoreLimits.maximumQueryResultCount,
                    cursor: cursor,
                    direction: .backward
                )
            ))
            for record in result.records {
                guard case let .systemEvent(event) = record.item else { continue }
                if event.type == .turnCompleted || event.type == .turnFailed,
                   let eventTurnID = event.turnID {
                    terminalTurnIDs.insert(eventTurnID)
                    continue
                }
                guard event.type == .turnRecoveryCheckpointUpdated,
                      let checkpoint = event.recoveryCheckpoint,
                      !terminalTurnIDs.contains(checkpoint.turnID) else {
                    continue
                }
                return checkpoint
            }
            guard result.hasMoreBefore, let nextCursor = result.nextCursor else {
                return nil
            }
            cursor = nextCursor
        }
    }

    func shouldPreserveTurnForRecovery(
        error: Error,
        threadID: String,
        turnID: String?
    ) -> Bool {
        guard let turnID,
              activeRecoveryCheckpoint(in: threadID, turnID: turnID) != nil else {
            return false
        }
        if error is CancellationError {
            return true
        }
        if let runtimeError = error as? AgentRuntimeError {
            if runtimeError.code == "responses_stream_ended_early" {
                return true
            }
            if runtimeError.code.hasPrefix("responses_http_status_"),
               let status = Int(runtimeError.code.split(separator: "_").last ?? "") {
                return status == 408 || status == 425 || status == 429 || status >= 500
            }
            return false
        }
        return containsRecoverableNetworkError(error)
    }

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

    private func containsRecoverableNetworkError(
        _ error: Error
    ) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return containsRecoverableNetworkError(underlying)
        }
        return false
    }
}
