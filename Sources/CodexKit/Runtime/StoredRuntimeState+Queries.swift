import Foundation

extension StoredRuntimeState {
    func normalized() -> StoredRuntimeState {
        let projections = StoredRuntimeStateProjectionBuilder()
        let sortedThreads = threads.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id < rhs.id
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        var normalizedHistory = historyByThread
            .mapValues { records in
                records.sorted { lhs, rhs in
                    if lhs.sequenceNumber == rhs.sequenceNumber {
                        return lhs.createdAt < rhs.createdAt
                    }
                    return lhs.sequenceNumber < rhs.sequenceNumber
                }
            }

        for (threadID, messages) in messagesByThread where normalizedHistory[threadID]?.isEmpty != false {
            normalizedHistory[threadID] = projections.syntheticHistory(from: messages)
        }

        let normalizedMessages: [String: [AgentMessage]] = normalizedHistory.mapValues { records in
            records.compactMap { record -> AgentMessage? in
                guard case let .message(message) = record.item else {
                    return nil
                }
                return message
            }
        }

        var normalizedNextSequence = nextHistorySequenceByThread
        for thread in sortedThreads {
            let history = normalizedHistory[thread.id] ?? []
            let nextSequence = (history.last?.sequenceNumber ?? 0) + 1
            normalizedNextSequence[thread.id] = max(normalizedNextSequence[thread.id] ?? 0, nextSequence)
        }

        var normalizedSummaries: [String: AgentThreadSummary] = [:]
        var normalizedContextState = contextStateByThread
        for thread in sortedThreads {
            let history = normalizedHistory[thread.id] ?? []
            normalizedSummaries[thread.id] = projections.rebuildSummary(
                for: thread,
                history: history,
                existing: summariesByThread[thread.id]
            )
            if let existing = normalizedContextState[thread.id] {
                normalizedContextState[thread.id] = AgentThreadContextState(
                    threadID: thread.id,
                    effectiveMessages: existing.effectiveMessages,
                    generation: existing.generation,
                    lastCompactedAt: existing.lastCompactedAt,
                    lastCompactionReason: existing.lastCompactionReason,
                    latestMarkerID: existing.latestMarkerID
                )
            }
        }

        return StoredRuntimeState(
            threads: sortedThreads,
            messagesByThread: normalizedMessages,
            historyByThread: normalizedHistory,
            summariesByThread: normalizedSummaries,
            contextStateByThread: normalizedContextState,
            nextHistorySequenceByThread: normalizedNextSequence,
            normalizeState: false
        )
    }

    func threadSummary(id: String) throws -> AgentThreadSummary {
        guard let thread = threads.first(where: { $0.id == id }) else {
            throw AgentRuntimeError.threadNotFound(id)
        }

        return summariesByThread[id] ?? threadSummaryFallback(for: thread)
    }

    func threadSummaryFallback(for thread: AgentThread) -> AgentThreadSummary {
        StoredRuntimeStateProjectionBuilder().rebuildSummary(
            for: thread,
            history: historyByThread[thread.id] ?? [],
            existing: summariesByThread[thread.id]
        )
    }

    func threadHistoryPage(
        id: String,
        query: AgentHistoryQuery
    ) throws -> AgentThreadHistoryPage {
        guard threads.contains(where: { $0.id == id }) else {
            throw AgentRuntimeError.threadNotFound(id)
        }

        let limit = max(1, query.limit)
        let filter = query.filter ?? AgentHistoryFilter()
        let records = (historyByThread[id] ?? []).filter { filter.matches($0.item) }
        let anchor = try query.cursor?.decodedSequenceNumber(expectedThreadID: id)

        switch query.direction {
        case .backward:
            let endIndex = records.endIndexForBackward(anchor: anchor)
            let startIndex = max(0, endIndex - limit)
            let pageRecords = Array(records[startIndex ..< endIndex])
            let hasMoreBefore = startIndex > 0
            let hasMoreAfter = endIndex < records.count
            return AgentThreadHistoryPage(
                threadID: id,
                items: pageRecords.map { $0.item },
                nextCursor: hasMoreBefore ? AgentHistoryCursor(threadID: id, sequenceNumber: pageRecords.first?.sequenceNumber) : nil,
                previousCursor: hasMoreAfter ? AgentHistoryCursor(threadID: id, sequenceNumber: pageRecords.last?.sequenceNumber) : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: hasMoreAfter
            )

        case .forward:
            let startIndex = records.startIndexForForward(anchor: anchor)
            let endIndex = min(records.count, startIndex + limit)
            let pageRecords = Array(records[startIndex ..< endIndex])
            let hasMoreBefore = startIndex > 0
            let hasMoreAfter = endIndex < records.count
            return AgentThreadHistoryPage(
                threadID: id,
                items: pageRecords.map { $0.item },
                nextCursor: hasMoreAfter ? AgentHistoryCursor(threadID: id, sequenceNumber: pageRecords.last?.sequenceNumber) : nil,
                previousCursor: hasMoreBefore ? AgentHistoryCursor(threadID: id, sequenceNumber: pageRecords.first?.sequenceNumber) : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: hasMoreAfter
            )
        }
    }

    func applying(_ operations: [AgentStoreWriteOperation]) throws -> StoredRuntimeState {
        var updated = self

        for operation in operations {
            switch operation {
            case let .upsertThread(thread):
                if let index = updated.threads.firstIndex(where: { $0.id == thread.id }) {
                    updated.threads[index] = thread
                } else {
                    updated.threads.append(thread)
                }

            case let .upsertSummary(threadID, summary):
                updated.summariesByThread[threadID] = summary

            case let .appendHistoryItems(threadID, items):
                updated.historyByThread[threadID, default: []].append(contentsOf: items)
                let nextSequence = (updated.historyByThread[threadID]?.last?.sequenceNumber ?? 0) + 1
                updated.nextHistorySequenceByThread[threadID] = nextSequence

            case let .appendCompactionMarker(threadID, marker):
                updated.historyByThread[threadID, default: []].append(marker)
                let nextSequence = (updated.historyByThread[threadID]?.last?.sequenceNumber ?? 0) + 1
                updated.nextHistorySequenceByThread[threadID] = nextSequence

            case let .upsertThreadContextState(threadID, state):
                updated.contextStateByThread[threadID] = state

            case let .deleteThreadContextState(threadID):
                updated.contextStateByThread.removeValue(forKey: threadID)

            case let .setPendingState(threadID, state):
                if let thread = updated.threads.first(where: { $0.id == threadID }) {
                    let current = updated.summariesByThread[threadID] ?? updated.threadSummaryFallback(for: thread)
                    updated.summariesByThread[threadID] = AgentThreadSummary(
                        threadID: current.threadID,
                        createdAt: current.createdAt,
                        updatedAt: current.updatedAt,
                        latestItemAt: current.latestItemAt,
                        itemCount: current.itemCount,
                        latestAssistantMessagePreview: current.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: current.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: current.latestPartialStructuredOutput,
                        latestToolState: current.latestToolState,
                        latestTurnStatus: current.latestTurnStatus,
                        pendingState: state
                    )
                }

            case let .setPartialStructuredSnapshot(threadID, snapshot):
                if let thread = updated.threads.first(where: { $0.id == threadID }) {
                    let current = updated.summariesByThread[threadID] ?? updated.threadSummaryFallback(for: thread)
                    updated.summariesByThread[threadID] = AgentThreadSummary(
                        threadID: current.threadID,
                        createdAt: current.createdAt,
                        updatedAt: current.updatedAt,
                        latestItemAt: current.latestItemAt,
                        itemCount: current.itemCount,
                        latestAssistantMessagePreview: current.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: current.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: snapshot,
                        latestToolState: current.latestToolState,
                        latestTurnStatus: current.latestTurnStatus,
                        pendingState: current.pendingState
                    )
                }

            case let .upsertToolSession(threadID, session):
                if let thread = updated.threads.first(where: { $0.id == threadID }) {
                    let current = updated.summariesByThread[threadID] ?? updated.threadSummaryFallback(for: thread)
                    let latestToolState = AgentLatestToolState(
                        invocationID: session.invocationID,
                        turnID: session.turnID,
                        toolName: session.toolName,
                        status: .running,
                        success: nil,
                        sessionID: session.sessionID,
                        sessionStatus: session.sessionStatus,
                        metadata: session.metadata,
                        resumable: session.resumable,
                        updatedAt: session.updatedAt,
                        resultPreview: nil
                    )
                    updated.summariesByThread[threadID] = AgentThreadSummary(
                        threadID: current.threadID,
                        createdAt: current.createdAt,
                        updatedAt: current.updatedAt,
                        latestItemAt: current.latestItemAt,
                        itemCount: current.itemCount,
                        latestAssistantMessagePreview: current.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: current.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: current.latestPartialStructuredOutput,
                        latestToolState: latestToolState,
                        latestTurnStatus: current.latestTurnStatus,
                        pendingState: .toolWait(
                            AgentPendingToolWaitState(
                                invocationID: session.invocationID,
                                turnID: session.turnID,
                                toolName: session.toolName,
                                startedAt: session.updatedAt,
                                sessionID: session.sessionID,
                                sessionStatus: session.sessionStatus,
                                metadata: session.metadata,
                                resumable: session.resumable
                            )
                        )
                    )
                }

            case let .redactHistoryItems(threadID, itemIDs, reason):
                guard !itemIDs.isEmpty else {
                    continue
                }
                updated.historyByThread[threadID] = updated.historyByThread[threadID]?.map { record in
                    guard itemIDs.contains(record.id) else {
                        return record
                    }
                    return record.redacted(reason: reason)
                }

            case let .deleteThread(threadID):
                updated.threads.removeAll { $0.id == threadID }
                updated.messagesByThread.removeValue(forKey: threadID)
                updated.historyByThread.removeValue(forKey: threadID)
                updated.summariesByThread.removeValue(forKey: threadID)
                updated.contextStateByThread.removeValue(forKey: threadID)
                updated.nextHistorySequenceByThread.removeValue(forKey: threadID)
            }
        }

        return updated.normalized()
    }
}

struct StoredRuntimeStateProjectionBuilder: Sendable {
    func syntheticHistory(from messages: [AgentMessage]) -> [AgentHistoryRecord] {
        let orderedMessages = messages.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            if left.createdAt == right.createdAt {
                return lhs.offset < rhs.offset
            }
            return left.createdAt < right.createdAt
        }

        return orderedMessages.enumerated().map { index, pair in
            AgentHistoryRecord(
                sequenceNumber: index + 1,
                createdAt: pair.element.createdAt,
                item: .message(pair.element)
            )
        }
    }

    func rebuildSummary(
        for thread: AgentThread,
        history: [AgentHistoryRecord],
        existing: AgentThreadSummary?
    ) -> AgentThreadSummary {
        var latestAssistantMessagePreview = existing?.latestAssistantMessagePreview
        var latestStructuredOutputMetadata = existing?.latestStructuredOutputMetadata
        var latestToolState = existing?.latestToolState
        var latestTurnStatus = existing?.latestTurnStatus
        let latestPartialStructuredOutput = existing?.latestPartialStructuredOutput
        let pendingState = existing?.pendingState

        for record in history {
            switch record.item {
            case let .message(message):
                if message.role == .assistant {
                    latestAssistantMessagePreview = message.displayText
                    if let structuredOutput = message.structuredOutput {
                        latestStructuredOutputMetadata = structuredOutput
                    }
                }
            case let .toolCall(toolCall):
                latestToolState = AgentLatestToolState(
                    invocationID: toolCall.invocation.id,
                    turnID: toolCall.invocation.turnID,
                    toolName: toolCall.invocation.toolName,
                    status: .waiting,
                    updatedAt: toolCall.requestedAt
                )
            case let .toolResult(toolResult):
                latestToolState = self.latestToolState(from: toolResult)
            case let .structuredOutput(structuredOutput):
                latestStructuredOutputMetadata = structuredOutput.metadata
            case .approval:
                break
            case let .systemEvent(systemEvent):
                switch systemEvent.type {
                case .turnStarted:
                    latestTurnStatus = .running
                case .turnCompleted:
                    latestTurnStatus = .completed
                case .turnFailed:
                    latestTurnStatus = .failed
                case .threadCreated, .threadResumed, .threadStatusChanged, .contextCompacted:
                    break
                }
            }
        }

        return AgentThreadSummary(
            threadID: thread.id,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            latestItemAt: history.last?.createdAt,
            itemCount: history.count,
            latestAssistantMessagePreview: latestAssistantMessagePreview,
            latestStructuredOutputMetadata: latestStructuredOutputMetadata,
            latestPartialStructuredOutput: latestPartialStructuredOutput,
            latestToolState: latestToolState,
            latestTurnStatus: latestTurnStatus,
            pendingState: pendingState
        )
    }

    func latestToolState(from toolResult: AgentToolResultRecord) -> AgentLatestToolState {
        let preview = toolResult.result.primaryText
        let session = toolResult.result.session
        let status: AgentToolSessionStatus
        if toolResult.result.errorMessage == "Tool execution was denied by the user." {
            status = .denied
        } else if let session, !session.isTerminal {
            status = .running
        } else if toolResult.result.success {
            status = .completed
        } else {
            status = .failed
        }

        return AgentLatestToolState(
            invocationID: toolResult.result.invocationID,
            turnID: toolResult.turnID,
            toolName: toolResult.result.toolName,
            status: status,
            success: toolResult.result.success,
            sessionID: session?.sessionID,
            sessionStatus: session?.status,
            metadata: session?.metadata,
            resumable: session?.resumable ?? false,
            updatedAt: toolResult.completedAt,
            resultPreview: preview
        )
    }
}
