import Foundation

extension StoredRuntimeState {
    package func execute(_ query: HistoryItemsQuery) throws -> AgentHistoryQueryResult {
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
        if let relationship = query.relationship {
            records = records.filter { $0.item.relationshipKey == relationship.storageKey }
        }
        if !query.includeRedacted {
            records = records.filter { $0.redaction == nil }
        }
        if !query.includeCompactionEvents {
            records = records.filter { !$0.item.isCompactionMarker }
        }

        records = sort(records, using: query.sort)
        return try page(
            records,
            threadID: query.threadID,
            with: query.page ?? AgentQueryPage(limit: AgentStoreLimits.defaultListResultCount),
            sort: query.sort
        )
    }

    package func execute(_ query: ThreadMetadataQuery) -> [AgentThread] {
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
        if let cursor = query.cursor {
            filtered = filtered.filter { thread in
                let date: Date
                let order: AgentSortOrder
                switch query.sort {
                case let .updatedAt(sortOrder):
                    date = thread.updatedAt
                    order = sortOrder
                case let .createdAt(sortOrder):
                    date = thread.createdAt
                    order = sortOrder
                }
                if date == cursor.date {
                    return thread.id > cursor.threadID
                }
                return order == .ascending ? date > cursor.date : date < cursor.date
            }
        }
        filtered = sort(filtered, using: query.sort)
        filtered = Array(filtered.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
        return filtered
    }

    package func execute(_ query: PendingStateQuery) -> [AgentPendingStateRecord] {
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
        records = Array(records.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
        return records
    }

    package func execute(_ query: StructuredOutputQuery) -> [AgentStructuredOutputRecord] {
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

        if query.latestOnly {
            records = Dictionary(grouping: records, by: \.threadID).compactMap { _, values in
                values.sorted { lhs, rhs in
                    if lhs.committedAt == rhs.committedAt {
                        return (lhs.messageID ?? "") < (rhs.messageID ?? "")
                    }
                    return lhs.committedAt > rhs.committedAt
                }.first
            }
        }
        records = sort(records, using: query.sort)

        records = Array(records.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
        return records
    }

    package func execute(_ query: ThreadSnapshotQuery) -> [AgentThreadSnapshot] {
        var snapshots = threads.compactMap { thread -> AgentThreadSnapshot? in
            guard query.threadIDs?.contains(thread.id) ?? true else {
                return nil
            }
            let summary = summariesByThread[thread.id] ?? threadSummaryFallback(for: thread)
            return summary.snapshot
        }
        snapshots = sort(snapshots, using: query.sort)
        snapshots = Array(snapshots.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
        return snapshots
    }

    package func execute(_ query: ThreadContextStateQuery) -> [AgentThreadContextState] {
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
        records = Array(records.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
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
                    return order == .ascending
                        ? lhs.createdAt < rhs.createdAt
                        : lhs.createdAt > rhs.createdAt
                }
                return order == .ascending
                    ? lhs.sequenceNumber < rhs.sequenceNumber
                    : lhs.sequenceNumber > rhs.sequenceNumber

            case let .createdAt(order):
                if lhs.createdAt == rhs.createdAt {
                    return order == .ascending
                        ? lhs.sequenceNumber < rhs.sequenceNumber
                        : lhs.sequenceNumber > rhs.sequenceNumber
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
        let effectivePage = page ?? AgentQueryPage(
            limit: AgentStoreLimits.defaultListResultCount
        )
        let limit = AgentStoreLimitValidator.boundedLimit(effectivePage.limit)
        let anchor = try effectivePage.cursor?.decodedHistoryQueryAnchor(
            expectedThreadID: threadID,
            sort: sort
        )
        let ascending = normalizePageRecords(records, sort: sort)
        let startIndex: Int
        let endIndex: Int
        switch effectivePage.direction {
        case .backward:
            endIndex = if let anchor {
                ascending.firstIndex(where: { record in
                    historyRecord(record, isAtOrAfter: anchor, sort: sort)
                }) ?? ascending.count
            } else {
                ascending.count
            }
            startIndex = max(0, endIndex - limit)
        case .forward:
            startIndex = if let anchor {
                ascending.firstIndex(where: { record in
                    historyRecord(record, isAfter: anchor, sort: sort)
                }) ?? ascending.count
            } else {
                0
            }
            endIndex = min(ascending.count, startIndex + limit)
        }
        let sliced = Array(ascending[startIndex ..< endIndex])
        let orderedSlice = historySortOrder(sort) == .ascending
            ? sliced
            : Array(sliced.reversed())
        return AgentHistoryQueryResult(
            threadID: threadID,
            records: orderedSlice,
            nextCursor: effectivePage.direction == .backward
                ? startIndex > 0
                    ? AgentHistoryCursor(threadID: threadID, record: sliced.first, sort: sort)
                    : nil
                : endIndex < ascending.count
                    ? AgentHistoryCursor(threadID: threadID, record: sliced.last, sort: sort)
                    : nil,
            previousCursor: effectivePage.direction == .backward
                ? endIndex < ascending.count
                    ? AgentHistoryCursor(threadID: threadID, record: sliced.last, sort: sort)
                    : nil
                : startIndex > 0
                    ? AgentHistoryCursor(threadID: threadID, record: sliced.first, sort: sort)
                    : nil,
            hasMoreBefore: startIndex > 0,
            hasMoreAfter: endIndex < ascending.count
        )
    }

    func historyRecord(
        _ record: AgentHistoryRecord,
        isAtOrAfter anchor: AgentHistoryQueryCursorAnchor,
        sort: AgentHistorySort
    ) -> Bool {
        switch sort {
        case .sequence:
            return record.sequenceNumber >= anchor.sequenceNumber
        case .createdAt:
            if record.createdAt == anchor.createdAt {
                return record.sequenceNumber >= anchor.sequenceNumber
            }
            return record.createdAt > anchor.createdAt
        }
    }

    func historyRecord(
        _ record: AgentHistoryRecord,
        isAfter anchor: AgentHistoryQueryCursorAnchor,
        sort: AgentHistorySort
    ) -> Bool {
        switch sort {
        case .sequence:
            return record.sequenceNumber > anchor.sequenceNumber
        case .createdAt:
            if record.createdAt == anchor.createdAt {
                return record.sequenceNumber > anchor.sequenceNumber
            }
            return record.createdAt > anchor.createdAt
        }
    }

    func historySortOrder(_ sort: AgentHistorySort) -> AgentSortOrder {
        switch sort {
        case let .sequence(order), let .createdAt(order):
            order
        }
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

package struct AgentHistoryQueryCursorAnchor: Sendable {
    package let sequenceNumber: Int
    package let createdAt: Date
}

private enum AgentHistoryCursorSortField: String, Codable {
    case sequence
    case createdAt
}

private struct AgentHistoryQueryCursorPayload: Codable {
    let version: Int
    let threadID: String
    let sortField: AgentHistoryCursorSortField
    let sortOrder: AgentSortOrder
    let sequenceNumber: Int
    let createdAt: Date
}

extension AgentHistoryCursor {
    package init(threadID: String, sequenceNumber: Int?) {
        guard let sequenceNumber else {
            self.init(rawValue: "")
            return
        }

        let payload = AgentHistoryCursorPayload(
            version: 1,
            threadID: threadID,
            sequenceNumber: sequenceNumber
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(payload)) ?? Data()
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        self.init(rawValue: base64)
    }

    package func decodedSequenceNumber(expectedThreadID: String) throws -> Int {
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

    package init(
        threadID: String,
        record: AgentHistoryRecord?,
        sort: AgentHistorySort
    ) {
        guard let record else {
            self.init(rawValue: "")
            return
        }
        let (sortField, sortOrder): (AgentHistoryCursorSortField, AgentSortOrder) = switch sort {
        case let .sequence(order): (.sequence, order)
        case let .createdAt(order): (.createdAt, order)
        }
        let payload = AgentHistoryQueryCursorPayload(
            version: 2,
            threadID: threadID,
            sortField: sortField,
            sortOrder: sortOrder,
            sequenceNumber: record.sequenceNumber,
            createdAt: record.createdAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(payload)) ?? Data()
        self.init(rawValue: Self.urlSafeBase64(data))
    }

    package func decodedHistoryQueryAnchor(
        expectedThreadID: String,
        sort: AgentHistorySort
    ) throws -> AgentHistoryQueryCursorAnchor {
        let data = try decodedCursorData()
        let payload = try JSONDecoder().decode(AgentHistoryQueryCursorPayload.self, from: data)
        let (expectedField, expectedOrder): (AgentHistoryCursorSortField, AgentSortOrder) = switch sort {
        case let .sequence(order): (.sequence, order)
        case let .createdAt(order): (.createdAt, order)
        }
        guard payload.version == 2,
              payload.threadID == expectedThreadID,
              payload.sortField == expectedField,
              payload.sortOrder == expectedOrder
        else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }
        return AgentHistoryQueryCursorAnchor(
            sequenceNumber: payload.sequenceNumber,
            createdAt: payload.createdAt
        )
    }

    private static func urlSafeBase64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodedCursorData() throws -> Data {
        let padded = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        let adjusted = padded + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)
        guard let data = Data(base64Encoded: adjusted) else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }
        return data
    }
}
