import Foundation

extension StoredRuntimeState {
    func execute(_ query: HistoryItemsQuery) throws -> AgentHistoryQueryResult {
        guard threads.contains(where: { $0.id == query.threadID }) else {
            return AgentHistoryQueryResult(
                threadID: query.threadID,
                records: [],
                nextCursor: nil,
                previousCursor: nil,
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        var records = historyByThread[query.threadID] ?? []
        if let kinds = query.kinds {
            records = records.filter { kinds.contains($0.item.kind) }
        }
        if let createdAtRange = query.createdAtRange {
            records = records.filter { createdAtRange.contains($0.createdAt) }
        }
        if let turnID = query.turnID {
            records = records.filter { $0.item.turnID == turnID }
        }
        if !query.includeRedacted {
            records = records.filter { $0.redaction == nil }
        }
        if !query.includeCompactionEvents {
            records = records.filter { !$0.item.isCompactionMarker }
        }

        records = sort(records, using: query.sort)
        return try page(records, threadID: query.threadID, with: query.page, sort: query.sort)
    }

    func execute(_ query: ThreadMetadataQuery) -> [AgentThread] {
        var filtered = threads
        if let threadIDs = query.threadIDs {
            filtered = filtered.filter { threadIDs.contains($0.id) }
        }
        if let statuses = query.statuses {
            filtered = filtered.filter { statuses.contains($0.status) }
        }
        if let updatedAtRange = query.updatedAtRange {
            filtered = filtered.filter { updatedAtRange.contains($0.updatedAt) }
        }
        filtered = sort(filtered, using: query.sort)
        if let limit = query.limit {
            filtered = Array(filtered.prefix(max(0, limit)))
        }
        return filtered
    }

    func execute(_ query: PendingStateQuery) -> [AgentPendingStateRecord] {
        var records = summariesByThread.compactMap { threadID, summary -> AgentPendingStateRecord? in
            guard let pendingState = summary.pendingState else {
                return nil
            }
            return AgentPendingStateRecord(
                threadID: threadID,
                pendingState: pendingState,
                updatedAt: summary.updatedAt
            )
        }

        if let threadIDs = query.threadIDs {
            records = records.filter { threadIDs.contains($0.threadID) }
        }
        if let kinds = query.kinds {
            records = records.filter { kinds.contains($0.pendingState.kind) }
        }
        records = sort(records, using: query.sort)
        if let limit = query.limit {
            records = Array(records.prefix(max(0, limit)))
        }
        return records
    }

    func execute(_ query: StructuredOutputQuery) -> [AgentStructuredOutputRecord] {
        var records = historyByThread.values
            .flatMap { $0 }
            .compactMap { record -> AgentStructuredOutputRecord? in
                switch record.item {
                case let .structuredOutput(structuredOutput):
                    return structuredOutput

                case let .message(message):
                    guard let metadata = message.structuredOutput else {
                        return nil
                    }
                    return AgentStructuredOutputRecord(
                        threadID: message.threadID,
                        turnID: "",
                        messageID: message.id,
                        metadata: metadata,
                        committedAt: message.createdAt
                    )

                default:
                    return nil
                }
            }

        if let threadIDs = query.threadIDs {
            records = records.filter { threadIDs.contains($0.threadID) }
        }
        if let formatNames = query.formatNames {
            records = records.filter { formatNames.contains($0.metadata.formatName) }
        }

        records = sort(records, using: query.sort)

        if query.latestOnly {
            var seen = Set<String>()
            records = records.filter { record in
                seen.insert(record.threadID).inserted
            }
        }

        if let limit = query.limit {
            records = Array(records.prefix(max(0, limit)))
        }
        return records
    }

    func execute(_ query: ThreadSnapshotQuery) -> [AgentThreadSnapshot] {
        var snapshots = threads.compactMap { thread -> AgentThreadSnapshot? in
            guard query.threadIDs?.contains(thread.id) ?? true else {
                return nil
            }
            let summary = summariesByThread[thread.id] ?? threadSummaryFallback(for: thread)
            return summary.snapshot
        }
        snapshots = sort(snapshots, using: query.sort)
        if let limit = query.limit {
            snapshots = Array(snapshots.prefix(max(0, limit)))
        }
        return snapshots
    }

    func execute(_ query: ThreadContextStateQuery) -> [AgentThreadContextState] {
        var records = Array(contextStateByThread.values)
        if let threadIDs = query.threadIDs {
            records = records.filter { threadIDs.contains($0.threadID) }
        }
        records.sort { lhs, rhs in
            if lhs.generation == rhs.generation {
                return lhs.threadID < rhs.threadID
            }
            return lhs.generation > rhs.generation
        }
        if let limit = query.limit {
            records = Array(records.prefix(max(0, limit)))
        }
        return records
    }
}

extension Array where Element == AgentHistoryRecord {
    func endIndexForBackward(anchor: Int?) -> Int {
        guard let anchor else {
            return count
        }

        return firstIndex(where: { $0.sequenceNumber >= anchor }) ?? count
    }

    func startIndexForForward(anchor: Int?) -> Int {
        guard let anchor else {
            return 0
        }

        return firstIndex(where: { $0.sequenceNumber > anchor }) ?? count
    }
}

private extension StoredRuntimeState {
    func sort(
        _ records: [AgentHistoryRecord],
        using sort: AgentHistorySort
    ) -> [AgentHistoryRecord] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .sequence(order):
                if lhs.sequenceNumber == rhs.sequenceNumber {
                    return lhs.createdAt < rhs.createdAt
                }
                return order == .ascending
                    ? lhs.sequenceNumber < rhs.sequenceNumber
                    : lhs.sequenceNumber > rhs.sequenceNumber

            case let .createdAt(order):
                if lhs.createdAt == rhs.createdAt {
                    return lhs.sequenceNumber < rhs.sequenceNumber
                }
                return order == .ascending
                    ? lhs.createdAt < rhs.createdAt
                    : lhs.createdAt > rhs.createdAt
            }
        }
    }

    func page(
        _ records: [AgentHistoryRecord],
        threadID: String,
        with page: AgentQueryPage?,
        sort: AgentHistorySort
    ) throws -> AgentHistoryQueryResult {
        guard let page else {
            let ordered = normalizePageRecords(records, sort: sort)
            return AgentHistoryQueryResult(
                threadID: threadID,
                records: ordered,
                nextCursor: nil,
                previousCursor: nil,
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        let limit = max(1, page.limit)
        let anchor = try page.cursor?.decodedSequenceNumber(expectedThreadID: threadID)
        let ascending = normalizePageRecords(records, sort: sort)
        let endIndex = if let anchor {
            ascending.firstIndex(where: { $0.sequenceNumber >= anchor }) ?? ascending.count
        } else {
            ascending.count
        }
        let startIndex = max(0, endIndex - limit)
        let sliced = Array(ascending[startIndex ..< endIndex])
        return AgentHistoryQueryResult(
            threadID: threadID,
            records: sliced,
            nextCursor: startIndex > 0 ? AgentHistoryCursor(threadID: threadID, sequenceNumber: sliced.first?.sequenceNumber) : nil,
            previousCursor: endIndex < ascending.count ? AgentHistoryCursor(threadID: threadID, sequenceNumber: sliced.last?.sequenceNumber) : nil,
            hasMoreBefore: startIndex > 0,
            hasMoreAfter: endIndex < ascending.count
        )
    }

    func normalizePageRecords(
        _ records: [AgentHistoryRecord],
        sort: AgentHistorySort
    ) -> [AgentHistoryRecord] {
        switch sort {
        case .sequence(.ascending), .createdAt(.ascending):
            return records
        case .sequence(.descending), .createdAt(.descending):
            return records.reversed()
        }
    }

    func sort(
        _ threads: [AgentThread],
        using sort: AgentThreadMetadataSort
    ) -> [AgentThread] {
        threads.sorted { lhs, rhs in
            switch sort {
            case let .updatedAt(order):
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return order == .ascending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
            case let .createdAt(order):
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id < rhs.id
                }
                return order == .ascending ? lhs.createdAt < rhs.createdAt : lhs.createdAt > rhs.createdAt
            }
        }
    }

    func sort(
        _ records: [AgentPendingStateRecord],
        using sort: AgentPendingStateSort
    ) -> [AgentPendingStateRecord] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .updatedAt(order):
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    func sort(
        _ records: [AgentStructuredOutputRecord],
        using sort: AgentStructuredOutputSort
    ) -> [AgentStructuredOutputRecord] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .committedAt(order):
                if lhs.committedAt == rhs.committedAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.committedAt < rhs.committedAt : lhs.committedAt > rhs.committedAt
            }
        }
    }

    func sort(
        _ records: [AgentThreadSnapshot],
        using sort: AgentThreadSnapshotSort
    ) -> [AgentThreadSnapshot] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .updatedAt(order):
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
            case let .createdAt(order):
                if lhs.createdAt == rhs.createdAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.createdAt < rhs.createdAt : lhs.createdAt > rhs.createdAt
            }
        }
    }
}

struct AgentHistoryCursorPayload: Codable {
    let version: Int
    let threadID: String
    let sequenceNumber: Int
}

extension AgentHistoryCursor {
    init(threadID: String, sequenceNumber: Int?) {
        guard let sequenceNumber else {
            self.init(rawValue: "")
            return
        }

        let payload = AgentHistoryCursorPayload(
            version: 1,
            threadID: threadID,
            sequenceNumber: sequenceNumber
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        self.init(rawValue: base64)
    }

    func decodedSequenceNumber(expectedThreadID: String) throws -> Int {
        let padded = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        let adjusted = padded + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)

        guard let data = Data(base64Encoded: adjusted) else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }

        let payload = try JSONDecoder().decode(AgentHistoryCursorPayload.self, from: data)
        guard payload.threadID == expectedThreadID else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }
        return payload.sequenceNumber
    }
}
