import Foundation

extension AgentRuntime: AgentRuntimeQueryable, AgentRuntimeThreadInspecting {
    public func execute<Query: AgentQuerySpec>(_ query: Query) async throws -> Query.Result {
        if let queryableStore = stateStore as? any AgentRuntimeQueryableStore {
            return try await queryableStore.execute(query)
        }

        let loadedState = try await stateStore.loadState()
        return try query.execute(in: loadedState)
    }

    public func fetchThreadSummary(id: String) async throws -> AgentThreadSummary {
        if let inspectingStore = stateStore as? any RuntimeStateInspecting {
            return try await inspectingStore.fetchThreadSummary(id: id)
        }

        let snapshots = try await execute(
            ThreadSnapshotQuery(
                threadIDs: [id],
                limit: 1
            )
        )
        guard let snapshot = snapshots.first else {
            throw AgentRuntimeError.threadNotFound(id)
        }
        return snapshot.summary
    }

    public func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage {
        if let inspectingStore = stateStore as? any RuntimeStateInspecting {
            return try await inspectingStore.fetchThreadHistory(id: id, query: query)
        }

        let result = try await execute(
            HistoryItemsQuery(
                threadID: id,
                kinds: query.filter?.includedKinds,
                includeRedacted: true,
                sort: query.direction == .forward ? .sequence(.ascending) : .sequence(.descending),
                page: AgentQueryPage(limit: query.limit, cursor: query.cursor)
            )
        )

        return AgentThreadHistoryPage(
            threadID: id,
            items: result.records.map(\.item),
            nextCursor: result.nextCursor,
            previousCursor: result.previousCursor,
            hasMoreBefore: result.hasMoreBefore,
            hasMoreAfter: result.hasMoreAfter
        )
    }

    public func fetchLatestStructuredOutputMetadata(id: String) async throws -> AgentStructuredOutputMetadata? {
        if let inspectingStore = stateStore as? any RuntimeStateInspecting {
            return try await inspectingStore.fetchLatestStructuredOutputMetadata(id: id)
        }

        let records = try await execute(
            StructuredOutputQuery(
                threadIDs: [id],
                latestOnly: true,
                limit: 1
            )
        )
        return records.first?.metadata
    }

    public func fetchLatestStructuredOutput<Output: Decodable & Sendable>(
        id: String,
        as outputType: Output.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Output? {
        guard let metadata = try await fetchLatestStructuredOutputMetadata(id: id) else {
            return nil
        }

        return try decodeStructuredValue(
            metadata.payload,
            as: outputType,
            decoder: decoder
        )
    }

    public func storeMetadata() async throws -> AgentStoreMetadata {
        try await stateStore.readMetadata()
    }

    @discardableResult
    public func prepareStore() async throws -> AgentStoreMetadata {
        try await stateStore.prepare()
    }
}

extension AgentRuntime {
    public func deleteThread(id: String) async throws {
        if !pendingStoreOperations.isEmpty {
            try await persistState()
        }
        state = try state.applying([.deleteThread(threadID: id)])
        try await stateStore.apply([.deleteThread(threadID: id)])
    }

    public func redactHistoryItems(
        _ itemIDs: [String],
        in threadID: String,
        reason: AgentRedactionReason? = nil
    ) async throws {
        guard !itemIDs.isEmpty else {
            return
        }
        if !pendingStoreOperations.isEmpty {
            try await persistState()
        }

        let operation = AgentStoreWriteOperation.redactHistoryItems(
            threadID: threadID,
            itemIDs: itemIDs,
            reason: reason
        )
        state = try state.applying([operation])
        try await stateStore.apply([operation])
    }

    func appendHistoryItem(
        _ item: AgentHistoryItem,
        threadID: String,
        createdAt: Date
    ) {
        let nextSequence = state.nextHistorySequenceByThread[threadID]
            ?? ((state.historyByThread[threadID]?.last?.sequenceNumber ?? 0) + 1)
        let record = AgentHistoryRecord(
            sequenceNumber: nextSequence,
            createdAt: createdAt,
            item: item
        )
        state.historyByThread[threadID, default: []].append(record)
        state.nextHistorySequenceByThread[threadID] = nextSequence + 1
        enqueueStoreOperation(
            .appendHistoryItems(threadID: threadID, items: [record])
        )
    }

    func updateThreadTimestamp(
        _ timestamp: Date,
        for threadID: String
    ) {
        guard let index = state.threads.firstIndex(where: { $0.id == threadID }) else {
            return
        }

        state.threads[index].updatedAt = max(state.threads[index].updatedAt, timestamp)
        enqueueStoreOperation(.upsertThread(state.threads[index]))
    }

    func updateSummary(
        for threadID: String,
        _ mutate: (AgentThreadSummary) -> AgentThreadSummary
    ) throws {
        guard let thread = thread(for: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }

        let current = state.summariesByThread[threadID]
            ?? state.threadSummaryFallback(for: thread)
        let updated = mutate(current)
        state.summariesByThread[threadID] = updated
        enqueueStoreOperation(.upsertSummary(threadID: threadID, summary: updated))
    }

    func setPendingState(
        _ pendingState: AgentThreadPendingState?,
        for threadID: String
    ) throws {
        try updateSummary(for: threadID) { summary in
            AgentThreadSummary(
                threadID: summary.threadID,
                createdAt: summary.createdAt,
                updatedAt: summary.updatedAt,
                latestItemAt: summary.latestItemAt,
                itemCount: summary.itemCount,
                latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                latestToolState: summary.latestToolState,
                latestTurnStatus: summary.latestTurnStatus,
                pendingState: pendingState
            )
        }
    }

    func setLatestPartialStructuredOutput(
        _ snapshot: AgentPartialStructuredOutputSnapshot?,
        for threadID: String
    ) throws {
        try updateSummary(for: threadID) { summary in
            AgentThreadSummary(
                threadID: summary.threadID,
                createdAt: summary.createdAt,
                updatedAt: summary.updatedAt,
                latestItemAt: summary.latestItemAt,
                itemCount: summary.itemCount,
                latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                latestPartialStructuredOutput: snapshot,
                latestToolState: summary.latestToolState,
                latestTurnStatus: summary.latestTurnStatus,
                pendingState: summary.pendingState
            )
        }
    }

    func setLatestStructuredOutputMetadata(
        _ metadata: AgentStructuredOutputMetadata?,
        for threadID: String
    ) throws {
        try updateSummary(for: threadID) { summary in
            AgentThreadSummary(
                threadID: summary.threadID,
                createdAt: summary.createdAt,
                updatedAt: summary.updatedAt,
                latestItemAt: summary.latestItemAt,
                itemCount: summary.itemCount,
                latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                latestStructuredOutputMetadata: metadata,
                latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                latestToolState: summary.latestToolState,
                latestTurnStatus: summary.latestTurnStatus,
                pendingState: summary.pendingState
            )
        }
    }

    func setLatestToolState(
        _ latestToolState: AgentLatestToolState?,
        for threadID: String
    ) throws {
        try updateSummary(for: threadID) { summary in
            AgentThreadSummary(
                threadID: summary.threadID,
                createdAt: summary.createdAt,
                updatedAt: summary.updatedAt,
                latestItemAt: summary.latestItemAt,
                itemCount: summary.itemCount,
                latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                latestToolState: latestToolState,
                latestTurnStatus: summary.latestTurnStatus,
                pendingState: summary.pendingState
            )
        }
    }

    func setLatestTurnStatus(
        _ latestTurnStatus: AgentTurnStatus?,
        for threadID: String
    ) throws {
        try updateSummary(for: threadID) { summary in
            AgentThreadSummary(
                threadID: summary.threadID,
                createdAt: summary.createdAt,
                updatedAt: summary.updatedAt,
                latestItemAt: summary.latestItemAt,
                itemCount: summary.itemCount,
                latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                latestToolState: summary.latestToolState,
                latestTurnStatus: latestTurnStatus,
                pendingState: summary.pendingState
            )
        }
    }

    func latestToolState(
        for invocation: ToolInvocation,
        result: ToolResultEnvelope?,
        updatedAt: Date
    ) -> AgentLatestToolState {
        let status: AgentToolSessionStatus
        if let result {
            if result.errorMessage == "Tool execution was denied by the user." {
                status = .denied
            } else if let session = result.session, !session.isTerminal {
                status = .running
            } else if result.success {
                status = .completed
            } else {
                status = .failed
            }
        } else {
            status = .waiting
        }

        return AgentLatestToolState(
            invocationID: invocation.id,
            turnID: invocation.turnID,
            toolName: invocation.toolName,
            status: status,
            success: result?.success,
            sessionID: result?.session?.sessionID,
            sessionStatus: result?.session?.status,
            metadata: result?.session?.metadata,
            resumable: result?.session?.resumable ?? false,
            updatedAt: updatedAt,
            resultPreview: result?.primaryText
        )
    }
}

private extension AgentHistoryFilter {
    var includedKinds: Set<AgentHistoryItemKind> {
        var kinds: Set<AgentHistoryItemKind> = []
        if includeMessages { kinds.insert(.message) }
        if includeToolCalls { kinds.insert(.toolCall) }
        if includeToolResults { kinds.insert(.toolResult) }
        if includeStructuredOutputs { kinds.insert(.structuredOutput) }
        if includeApprovals { kinds.insert(.approval) }
        if includeSystemEvents { kinds.insert(.systemEvent) }
        return kinds
    }
}

private extension AgentThreadSnapshot {
    var summary: AgentThreadSummary {
        AgentThreadSummary(
            threadID: threadID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            latestItemAt: latestItemAt,
            itemCount: itemCount,
            latestAssistantMessagePreview: latestAssistantMessagePreview,
            latestStructuredOutputMetadata: latestStructuredOutputMetadata,
            latestPartialStructuredOutput: latestPartialStructuredOutput,
            latestToolState: latestToolState,
            latestTurnStatus: latestTurnStatus,
            pendingState: pendingState
        )
    }
}
