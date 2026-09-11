import Foundation
import CodexKit
import GRDB

struct SQLiteRuntimeStoreQueries: Sendable {
    private enum HistoryOrderColumn: String {
        case sequenceNumber, createdAt

        var tieBreaker: Self {
            switch self {
            case .sequenceNumber: .createdAt
            case .createdAt: .sequenceNumber
            }
        }
    }

    let attachmentStore: RuntimeAttachmentStore

    func fetchHistoryQuery(
        _ query: HistoryItemsQuery,
        in db: Database
    ) throws -> AgentHistoryQueryResult {
        if query.kinds?.isEmpty == true {
            return emptyHistoryQueryResult(threadID: query.threadID)
        }

        var (clauses, arguments) = historyFilter(query)
        let orderColumn: HistoryOrderColumn
        let requestedOrder: AgentSortOrder
        switch query.sort {
        case let .sequence(order):
            orderColumn = .sequenceNumber
            requestedOrder = order
        case let .createdAt(order):
            orderColumn = .createdAt
            requestedOrder = order
        }

        let page = query.page ?? AgentQueryPage(
            limit: AgentStoreLimits.defaultListResultCount
        )
        let limit = AgentStoreLimitValidator.boundedLimit(page.limit)
        let anchor = try page.cursor?.decodedHistoryQueryAnchor(
            expectedThreadID: query.threadID,
            sort: query.sort
        )
        if let anchor {
            let storedCreatedAt = try Double.fetchOne(
                db,
                sql: "SELECT createdAt FROM \(RuntimeHistoryRow.databaseTableName) WHERE threadID = ? AND sequenceNumber = ?",
                arguments: [query.threadID, anchor.sequenceNumber]
            )
            guard storedCreatedAt == anchor.createdAt.timeIntervalSince1970 else {
                throw AgentRuntimeError.invalidHistoryCursor()
            }
        }

        if page.direction == .forward {
            if let anchor {
                switch query.sort {
                case .sequence:
                    clauses.append("sequenceNumber > ?")
                    arguments.append(anchor.sequenceNumber)
                case .createdAt:
                    clauses.append("(createdAt > ? OR (createdAt = ? AND sequenceNumber > ?))")
                    arguments.append(anchor.createdAt.timeIntervalSince1970)
                    arguments.append(anchor.createdAt.timeIntervalSince1970)
                    arguments.append(anchor.sequenceNumber)
                }
            }
            let tieColumn = orderColumn.tieBreaker
            let fetched = try RuntimeHistoryRowsRequest(
                sql: """
                SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY \(orderColumn.rawValue) ASC, \(tieColumn.rawValue) ASC
                LIMIT \(agentOverfetchLimit(limit))
                """,
                arguments: StatementArguments(arguments)
            ).execute(in: db)
            let pageRows = Array(fetched.prefix(limit))
            let recordsAscending = try pageRows.map(decodeHistoryRecord)
            let records = requestedOrder == .ascending
                ? recordsAscending
                : Array(recordsAscending.reversed())
            let hasMoreBefore: Bool
            if let anchor {
                var (beforeClauses, beforeArguments) = historyFilter(query)
                switch query.sort {
                case .sequence:
                    beforeClauses.append("sequenceNumber <= ?")
                    beforeArguments.append(anchor.sequenceNumber)
                case .createdAt:
                    beforeClauses.append("(createdAt < ? OR (createdAt = ? AND sequenceNumber <= ?))")
                    beforeArguments.append(anchor.createdAt.timeIntervalSince1970)
                    beforeArguments.append(anchor.createdAt.timeIntervalSince1970)
                    beforeArguments.append(anchor.sequenceNumber)
                }
                hasMoreBefore = try RuntimeHistoryExistenceQuery(
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM \(RuntimeHistoryRow.databaseTableName)
                        WHERE \(beforeClauses.joined(separator: " AND "))
                    )
                    """,
                    arguments: StatementArguments(beforeArguments)
                ).execute(in: db)
            } else {
                hasMoreBefore = false
            }
            return AgentHistoryQueryResult(
                threadID: query.threadID,
                records: records,
                nextCursor: fetched.count > limit
                    ? AgentHistoryCursor(
                        threadID: query.threadID,
                        record: recordsAscending.last,
                        sort: query.sort
                    )
                    : nil,
                previousCursor: hasMoreBefore
                    ? AgentHistoryCursor(
                        threadID: query.threadID,
                        record: recordsAscending.first,
                        sort: query.sort
                    )
                    : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: fetched.count > limit
            )
        }

        if let anchor {
            switch query.sort {
            case .sequence:
                clauses.append("sequenceNumber < ?")
                arguments.append(anchor.sequenceNumber)
            case .createdAt:
                clauses.append("(createdAt < ? OR (createdAt = ? AND sequenceNumber < ?))")
                arguments.append(anchor.createdAt.timeIntervalSince1970)
                arguments.append(anchor.createdAt.timeIntervalSince1970)
                arguments.append(anchor.sequenceNumber)
            }
        }

        let descendingTieColumn = orderColumn.tieBreaker
        let overfetchLimit = agentOverfetchLimit(limit)
        let fetched = try RuntimeHistoryRowsRequest(
            sql: """
            SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(orderColumn.rawValue) DESC, \(descendingTieColumn.rawValue) DESC
            LIMIT \(overfetchLimit)
            """,
            arguments: StatementArguments(arguments)
        ).execute(in: db)
        let pageRowsAscending = Array(fetched.prefix(limit).reversed())
        let recordsAscending = try pageRowsAscending.map(decodeHistoryRecord)
        let records = requestedOrder == .ascending
            ? recordsAscending
            : Array(recordsAscending.reversed())

        let hasMoreAfter: Bool
        if let anchor {
            var (afterClauses, afterArguments) = historyFilter(query)
            switch query.sort {
            case .sequence:
                afterClauses.append("sequenceNumber >= ?")
                afterArguments.append(anchor.sequenceNumber)
            case .createdAt:
                afterClauses.append("(createdAt > ? OR (createdAt = ? AND sequenceNumber >= ?))")
                afterArguments.append(anchor.createdAt.timeIntervalSince1970)
                afterArguments.append(anchor.createdAt.timeIntervalSince1970)
                afterArguments.append(anchor.sequenceNumber)
            }
            hasMoreAfter = try RuntimeHistoryExistenceQuery(
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM \(RuntimeHistoryRow.databaseTableName)
                    WHERE \(afterClauses.joined(separator: " AND "))
                )
                """,
                arguments: StatementArguments(afterArguments)
            ).execute(in: db)
        } else {
            hasMoreAfter = false
        }

        return AgentHistoryQueryResult(
            threadID: query.threadID,
            records: records,
            nextCursor: fetched.count > limit
                ? AgentHistoryCursor(
                    threadID: query.threadID,
                    record: recordsAscending.first,
                    sort: query.sort
                )
                : nil,
            previousCursor: hasMoreAfter
                ? AgentHistoryCursor(
                    threadID: query.threadID,
                    record: recordsAscending.last,
                    sort: query.sort
                )
                : nil,
            hasMoreBefore: fetched.count > limit,
            hasMoreAfter: hasMoreAfter
        )
    }

    private func historyFilter(
        _ query: HistoryItemsQuery
    ) -> ([String], [any DatabaseValueConvertible]) {
        var clauses = ["threadID = ?"]
        var arguments: [any DatabaseValueConvertible] = [query.threadID]
        if let kinds = query.kinds {
            clauses.append("kind IN \(sqlPlaceholders(count: kinds.count))")
            for kind in kinds { arguments.append(kind.rawValue) }
        }
        if let range = query.createdAtRange {
            clauses.append("createdAt >= ?")
            clauses.append("createdAt <= ?")
            arguments.append(range.lowerBound.timeIntervalSince1970)
            arguments.append(range.upperBound.timeIntervalSince1970)
        }
        if let turnID = query.turnID {
            clauses.append("turnID = ?")
            arguments.append(turnID)
        }
        if let relationship = query.relationship {
            clauses.append("relationshipKey = ?")
            arguments.append(relationship.storageKey)
        }
        if !query.includeRedacted {
            clauses.append("isRedacted = 0")
        }
        if !query.includeCompactionEvents {
            clauses.append("isCompactionMarker = 0")
        }
        return (clauses, arguments)
    }

    private func emptyHistoryQueryResult(threadID: String) -> AgentHistoryQueryResult {
        AgentHistoryQueryResult(
            threadID: threadID,
            records: [],
            nextCursor: nil,
            previousCursor: nil,
            hasMoreBefore: false,
            hasMoreAfter: false
        )
    }

    func fetchHistoryPage(
        threadID: String,
        query: AgentHistoryQuery,
        in db: Database
    ) throws -> AgentThreadHistoryPage {
        let limit = AgentStoreLimitValidator.boundedLimit(query.limit)
        let kinds = historyKinds(from: query.filter)
        let includeCompactionEvents = query.filter?.includeCompactionEvents ?? false
        let anchor = try decodeCursorSequence(query.cursor, expectedThreadID: threadID)

        if let kinds, kinds.isEmpty {
            return AgentThreadHistoryPage(
                threadID: threadID,
                items: [],
                nextCursor: nil,
                previousCursor: nil,
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        switch query.direction {
        case .backward:
            let overfetchLimit = agentOverfetchLimit(limit)
            var clauses = ["threadID = ?"]
            var arguments: [any DatabaseValueConvertible] = [threadID]
            if let kinds, !kinds.isEmpty {
                clauses.append("kind IN \(sqlPlaceholders(count: kinds.count))")
                for kind in kinds { arguments.append(kind.rawValue) }
            }
            if let anchor {
                clauses.append("sequenceNumber < ?")
                arguments.append(anchor)
            }
            if !includeCompactionEvents {
                clauses.append("isCompactionMarker = 0")
            }

            // Cursor paging is kept as raw SQL because the descending window + overfetch
            // pattern is much clearer here than trying to express it through chained requests.
            let sql = """
            SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY sequenceNumber DESC
            LIMIT \(overfetchLimit)
            """
            let fetched = try RuntimeHistoryRowsRequest(
                sql: sql,
                arguments: StatementArguments(arguments)
            ).execute(in: db)
            let hasMoreBefore = fetched.count > limit
            let pageRowsDescending = Array(fetched.prefix(limit))
            let pageRecords = try pageRowsDescending.map(decodeHistoryRecord).reversed()

            let hasMoreAfter: Bool
            if let anchor {
                hasMoreAfter = try historyRecordExists(
                    threadID: threadID,
                    kinds: kinds,
                    includeCompactionEvents: includeCompactionEvents,
                    comparator: "sequenceNumber >= ?",
                    value: anchor,
                    in: db
                )
            } else {
                hasMoreAfter = false
            }

            return AgentThreadHistoryPage(
                threadID: threadID,
                items: pageRecords.map(\.item),
                nextCursor: hasMoreBefore ? makeCursor(threadID: threadID, sequenceNumber: pageRecords.first?.sequenceNumber) : nil,
                previousCursor: hasMoreAfter ? makeCursor(threadID: threadID, sequenceNumber: pageRecords.last?.sequenceNumber) : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: hasMoreAfter
            )

        case .forward:
            let overfetchLimit = agentOverfetchLimit(limit)
            var clauses = ["threadID = ?"]
            var arguments: [any DatabaseValueConvertible] = [threadID]
            if let kinds, !kinds.isEmpty {
                clauses.append("kind IN \(sqlPlaceholders(count: kinds.count))")
                for kind in kinds { arguments.append(kind.rawValue) }
            }
            if let anchor {
                clauses.append("sequenceNumber > ?")
                arguments.append(anchor)
            }
            if !includeCompactionEvents {
                clauses.append("isCompactionMarker = 0")
            }

            // Forward paging mirrors the backward cursor window and stays in SQL for the
            // same reason: explicit sequence bounds and overfetch are easier to verify here.
            let sql = """
            SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY sequenceNumber ASC
            LIMIT \(overfetchLimit)
            """
            let fetched = try RuntimeHistoryRowsRequest(
                sql: sql,
                arguments: StatementArguments(arguments)
            ).execute(in: db)
            let hasMoreAfter = fetched.count > limit
            let pageRows = Array(fetched.prefix(limit))
            let pageRecords = try pageRows.map(decodeHistoryRecord)

            let hasMoreBefore: Bool
            if let anchor {
                hasMoreBefore = try historyRecordExists(
                    threadID: threadID,
                    kinds: kinds,
                    includeCompactionEvents: includeCompactionEvents,
                    comparator: "sequenceNumber <= ?",
                    value: anchor,
                    in: db
                )
            } else {
                hasMoreBefore = false
            }

            return AgentThreadHistoryPage(
                threadID: threadID,
                items: pageRecords.map(\.item),
                nextCursor: hasMoreAfter ? makeCursor(threadID: threadID, sequenceNumber: pageRecords.last?.sequenceNumber) : nil,
                previousCursor: hasMoreBefore ? makeCursor(threadID: threadID, sequenceNumber: pageRecords.first?.sequenceNumber) : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: hasMoreAfter
            )
        }
    }

    private func historyRecordExists(
        threadID: String,
        kinds: Set<AgentHistoryItemKind>?,
        includeCompactionEvents: Bool,
        comparator: String,
        value: Int,
        in db: Database
    ) throws -> Bool {
        var clauses = ["threadID = ?", comparator]
        var arguments: [any DatabaseValueConvertible] = [threadID, value]
        if let kinds, !kinds.isEmpty {
            clauses.append("kind IN \(sqlPlaceholders(count: kinds.count))")
            for kind in kinds { arguments.append(kind.rawValue) }
        }
        if !includeCompactionEvents {
            clauses.append("isCompactionMarker = 0")
        }

        let sql = """
        SELECT EXISTS(
            SELECT 1 FROM \(RuntimeHistoryRow.databaseTableName)
            WHERE \(clauses.joined(separator: " AND "))
        )
        """
        return try RuntimeHistoryExistenceQuery(
            sql: sql,
            arguments: StatementArguments(arguments)
        ).execute(in: db)
    }

    private func historyKinds(from filter: AgentHistoryFilter?) -> Set<AgentHistoryItemKind>? {
        guard let filter else {
            return nil
        }

        var kinds: Set<AgentHistoryItemKind> = []
        if filter.includeMessages { kinds.insert(.message) }
        if filter.includeToolCalls { kinds.insert(.toolCall) }
        if filter.includeToolResults { kinds.insert(.toolResult) }
        if filter.includeStructuredOutputs { kinds.insert(.structuredOutput) }
        if filter.includeApprovals { kinds.insert(.approval) }
        if filter.includeSystemEvents { kinds.insert(.systemEvent) }
        return kinds
    }

    private func makeCursor(threadID: String, sequenceNumber: Int?) -> AgentHistoryCursor? {
        guard let sequenceNumber else {
            return nil
        }

        let payload = GRDBHistoryCursorPayload(
            version: 1,
            threadID: threadID,
            sequenceNumber: sequenceNumber
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return AgentHistoryCursor(rawValue: base64)
    }

    private func decodeCursorSequence(
        _ cursor: AgentHistoryCursor?,
        expectedThreadID: String
    ) throws -> Int? {
        guard let cursor else {
            return nil
        }

        let padded = cursor.rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        let adjusted = padded + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)

        guard let data = Data(base64Encoded: adjusted) else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }

        let payload = try JSONDecoder().decode(GRDBHistoryCursorPayload.self, from: data)
        guard payload.threadID == expectedThreadID else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }
        return payload.sequenceNumber
    }

    private func decodeHistoryRecord(from row: RuntimeHistoryRow) throws -> AgentHistoryRecord {
        let persistence = SQLiteRuntimeStorePersistence(attachmentStore: attachmentStore)
        return try persistence.decodeHistoryRecord(from: row)
    }

    private func sqlPlaceholders(count: Int) -> String {
        "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
    }
}

extension SQLiteRuntimeStateStore {
    static func defaultLegacyImportURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("json")
    }
}

func runtimeSQLPlaceholders(count: Int) -> String {
    "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
}
