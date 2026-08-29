import Foundation

extension AgentRuntime {
    /// Returns the newest durable memory-attribution snapshots for completed
    /// threaded turns. Observer delivery is not required to recover these.
    public func fetchMemoryApplicationSnapshots(
        id threadID: String,
        limit: Int = 100
    ) async throws -> [MemoryApplicationSnapshot] {
        try await fetchMemoryAttribution(
            id: threadID,
            limit: limit,
            includesCompactionEvents: false
        ).compactMap(\.memoryApplication)
    }

    /// Returns the newest durable memory-attribution snapshots for successful
    /// context compactions.
    public func fetchMemoryCompactionApplicationSnapshots(
        id threadID: String,
        limit: Int = 100
    ) async throws -> [MemoryCompactionApplicationSnapshot] {
        try await fetchMemoryAttribution(
            id: threadID,
            limit: limit,
            includesCompactionEvents: true
        ).compactMap(\.memoryCompactionApplication)
    }

    private func fetchMemoryAttribution(
        id threadID: String,
        limit: Int,
        includesCompactionEvents: Bool
    ) async throws -> [AgentSystemEventRecord] {
        guard (1 ... AgentStoreLimits.maximumQueryResultCount).contains(limit) else {
            throw AgentStoreError.invalidInput(
                "memory application limit must be between 1 and \(AgentStoreLimits.maximumQueryResultCount)"
            )
        }

        var cursor: AgentHistoryCursor?
        var seenCursors: Set<AgentHistoryCursor> = []
        var remainingScanCount = AgentStoreLimits.maximumMemoryAttributionScanCount
        var materializedByteCount = 0
        var records: [AgentSystemEventRecord] = []

        while records.count < limit, remainingScanCount > 0 {
            try Task.checkCancellation()
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw AgentStoreError.invalidInput(
                    "memory attribution history returned a repeated cursor"
                )
            }

            let pageLimit = min(
                AgentStoreLimits.memoryAttributionHistoryPageSize,
                remainingScanCount
            )
            remainingScanCount -= pageLimit
            let page = try await fetchThreadHistory(
                id: threadID,
                query: AgentHistoryQuery(
                    limit: pageLimit,
                    cursor: cursor,
                    direction: .backward,
                    filter: AgentHistoryFilter(
                        includeMessages: false,
                        includeToolCalls: false,
                        includeToolResults: false,
                        includeStructuredOutputs: false,
                        includeApprovals: false,
                        includeSystemEvents: true,
                        includeCompactionEvents: includesCompactionEvents
                    )
                )
            )
            try Task.checkCancellation()
            guard page.threadID == threadID, page.items.count <= pageLimit else {
                throw AgentStoreError.invalidInput(
                    "memory attribution history returned an invalid page"
                )
            }

            // Backward history pages contain the newest window in chronological
            // order. Read each page in reverse so the public result is newest-first.
            for item in page.items.reversed() {
                guard case let .systemEvent(event) = item else { continue }
                guard event.threadID == threadID else {
                    throw AgentStoreError.invalidInput(
                        "memory attribution history returned a cross-thread event"
                    )
                }
                try AgentStoredPayloadValidator.validateHistoryItem(
                    item,
                    expectedThreadID: threadID
                )
                let payload: Data?
                if includesCompactionEvents {
                    payload = try event.memoryCompactionApplication.map { try JSONEncoder().encode($0) }
                } else {
                    payload = try event.memoryApplication.map { try JSONEncoder().encode($0) }
                }
                guard let payload else { continue }
                try AgentStoreLimitValidator.accumulateMaterializedPayload(
                    payload,
                    name: "memory attribution snapshot",
                    total: &materializedByteCount
                )
                records.append(event)
                if records.count == limit { break }
            }

            cursor = page.nextCursor
            if cursor == nil { break }
        }

        if records.count < limit, cursor != nil {
            throw AgentStoreError.invalidInput(
                "memory attribution history exceeds the \(AgentStoreLimits.maximumMemoryAttributionScanCount)-record scan limit"
            )
        }
        return records
    }
}
