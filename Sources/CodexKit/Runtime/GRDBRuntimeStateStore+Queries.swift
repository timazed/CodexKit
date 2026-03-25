import Foundation
import GRDB

extension GRDBRuntimeStateStore {
    func executeHistoryQuery(_ query: HistoryItemsQuery) async throws -> AgentHistoryQueryResult {
        let persistence = self.persistence
        let queries = self.queries
        return try await dbQueue.read { db in
            guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: query.threadID) else {
                return AgentHistoryQueryResult(
                    threadID: query.threadID,
                    records: [],
                    nextCursor: nil,
                    previousCursor: nil,
                    hasMoreBefore: false,
                    hasMoreAfter: false
                )
            }

            let thread = try persistence.decodeThread(from: threadRow)
            let history = try queries.fetchHistoryRows(
                threadID: query.threadID,
                kinds: query.kinds,
                createdAtRange: query.createdAtRange,
                turnID: query.turnID,
                includeRedacted: query.includeRedacted,
                includeCompactionEvents: query.includeCompactionEvents,
                in: db
            )

            let state = StoredRuntimeState(
                threads: [thread],
                historyByThread: [query.threadID: history]
            )
            return try state.execute(query)
        }
    }

    func executeThreadQuery(_ query: ThreadMetadataQuery) async throws -> [AgentThread] {
        let persistence = self.persistence
        return try await dbQueue.read { db in
            if let threadIDs = query.threadIDs, threadIDs.isEmpty {
                return []
            }
            if let statuses = query.statuses, statuses.isEmpty {
                return []
            }

            var request = RuntimeThreadRow.all()
            if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
                request = request.filter(threadIDs.contains(Column("threadID")))
            }
            if let statuses = query.statuses, !statuses.isEmpty {
                request = request.filter(statuses.map(\.rawValue).contains(Column("status")))
            }
            if let range = query.updatedAtRange {
                request = request.filter(Column("updatedAt") >= range.lowerBound.timeIntervalSince1970)
                request = request.filter(Column("updatedAt") <= range.upperBound.timeIntervalSince1970)
            }

            switch query.sort {
            case let .updatedAt(order):
                request = order == .ascending
                    ? request.order(Column("updatedAt").asc, Column("threadID").asc)
                    : request.order(Column("updatedAt").desc, Column("threadID").asc)
            case let .createdAt(order):
                request = order == .ascending
                    ? request.order(Column("createdAt").asc, Column("threadID").asc)
                    : request.order(Column("createdAt").desc, Column("threadID").asc)
            }

            if let limit = query.limit {
                request = request.limit(max(0, limit))
            }

            return try request.fetchAll(db).map { try persistence.decodeThread(from: $0) }
        }
    }

    func executeThreadContextStateQuery(_ query: ThreadContextStateQuery) async throws -> [AgentThreadContextState] {
        let persistence = self.persistence
        return try await dbQueue.read { db in
            if let threadIDs = query.threadIDs, threadIDs.isEmpty {
                return []
            }

            var request = RuntimeContextStateRow.all()
            if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
                request = request.filter(threadIDs.contains(Column("threadID")))
            }
            request = request.order(Column("generation").desc, Column("threadID").asc)
            if let limit = query.limit {
                request = request.limit(max(0, limit))
            }

            return try request.fetchAll(db).map { try persistence.decodeContextState(from: $0) }
        }
    }

    func executePendingStateQuery(_ query: PendingStateQuery) async throws -> [AgentPendingStateRecord] {
        let persistence = self.persistence
        return try await dbQueue.read { db in
            if let threadIDs = query.threadIDs, threadIDs.isEmpty {
                return []
            }
            if let kinds = query.kinds, kinds.isEmpty {
                return []
            }

            var request = RuntimeSummaryRow.filter(Column("pendingStateKind") != nil)

            if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
                request = request.filter(threadIDs.contains(Column("threadID")))
            }
            if let kinds = query.kinds, !kinds.isEmpty {
                request = request.filter(kinds.map(\.rawValue).contains(Column("pendingStateKind")))
            }

            switch query.sort {
            case let .updatedAt(order):
                request = order == .ascending
                    ? request.order(Column("updatedAt").asc)
                    : request.order(Column("updatedAt").desc)
            }

            if let limit = query.limit {
                request = request.limit(max(0, limit))
            }

            let summaries = try request.fetchAll(db)
            return try summaries.compactMap { row -> AgentPendingStateRecord? in
                let summary = try persistence.decodeSummary(from: row)
                guard let pendingState = summary.pendingState else {
                    return nil
                }
                return AgentPendingStateRecord(
                    threadID: summary.threadID,
                    pendingState: pendingState,
                    updatedAt: summary.updatedAt
                )
            }
        }
    }

    func executeStructuredOutputQuery(_ query: StructuredOutputQuery) async throws -> [AgentStructuredOutputRecord] {
        let persistence = self.persistence
        return try await dbQueue.read { db in
            if let threadIDs = query.threadIDs, threadIDs.isEmpty {
                return []
            }
            if let formatNames = query.formatNames, formatNames.isEmpty {
                return []
            }

            var request = RuntimeStructuredOutputRow.all()
            if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
                request = request.filter(threadIDs.contains(Column("threadID")))
            }
            if let formatNames = query.formatNames, !formatNames.isEmpty {
                request = request.filter(formatNames.contains(Column("formatName")))
            }

            switch query.sort {
            case let .committedAt(order):
                request = order == .ascending
                    ? request.order(Column("committedAt").asc)
                    : request.order(Column("committedAt").desc)
            }

            if let limit = query.limit, !query.latestOnly {
                request = request.limit(max(0, limit))
            }

            var records = try request.fetchAll(db)
                .map { try persistence.decodeStructuredOutputRecord(from: $0) }

            if query.latestOnly {
                var seen = Set<String>()
                records = records.filter { seen.insert($0.threadID).inserted }
            }

            if let limit = query.limit {
                records = Array(records.prefix(max(0, limit)))
            }
            return records
        }
    }

    func executeThreadSnapshotQuery(_ query: ThreadSnapshotQuery) async throws -> [AgentThreadSnapshot] {
        let persistence = self.persistence
        return try await dbQueue.read { db in
            if let threadIDs = query.threadIDs, threadIDs.isEmpty {
                return []
            }

            var request = RuntimeSummaryRow.all()
            if let threadIDs = query.threadIDs, !threadIDs.isEmpty {
                request = request.filter(threadIDs.contains(Column("threadID")))
            }

            switch query.sort {
            case let .updatedAt(order):
                request = order == .ascending
                    ? request.order(Column("updatedAt").asc, Column("threadID").asc)
                    : request.order(Column("updatedAt").desc, Column("threadID").asc)
            case let .createdAt(order):
                request = order == .ascending
                    ? request.order(Column("createdAt").asc, Column("threadID").asc)
                    : request.order(Column("createdAt").desc, Column("threadID").asc)
            }

            if let limit = query.limit {
                request = request.limit(max(0, limit))
            }

            return try request.fetchAll(db)
                .map { try persistence.decodeSummary(from: $0) }
                .map(\.snapshot)
        }
    }
}

struct GRDBRuntimeStoreQueries: Sendable {
    let attachmentStore: RuntimeAttachmentStore

    func fetchHistoryRows(
        threadID: String,
        kinds: Set<AgentHistoryItemKind>?,
        createdAtRange: ClosedRange<Date>?,
        turnID: String?,
        includeRedacted: Bool,
        includeCompactionEvents: Bool,
        in db: Database
    ) throws -> [AgentHistoryRecord] {
        if let kinds, kinds.isEmpty {
            return []
        }

        var clauses = ["threadID = ?"]
        var arguments: [any DatabaseValueConvertible] = [threadID]

        if let kinds, !kinds.isEmpty {
            clauses.append("kind IN \(sqlPlaceholders(count: kinds.count))")
            arguments.append(contentsOf: kinds.map(\.rawValue))
        }
        if let createdAtRange {
            clauses.append("createdAt >= ?")
            clauses.append("createdAt <= ?")
            arguments.append(createdAtRange.lowerBound.timeIntervalSince1970)
            arguments.append(createdAtRange.upperBound.timeIntervalSince1970)
        }
        if let turnID {
            clauses.append("turnID = ?")
            arguments.append(turnID)
        }
        if !includeRedacted {
            clauses.append("isRedacted = 0")
        }
        if !includeCompactionEvents {
            clauses.append("isCompactionMarker = 0")
        }

        let sql = """
        SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY sequenceNumber ASC
        """
        return try RuntimeHistoryRowsRequest(
            sql: sql,
            arguments: StatementArguments(arguments)
        ).execute(in: db).map(decodeHistoryRecord)
    }

    func fetchHistoryPage(
        threadID: String,
        query: AgentHistoryQuery,
        in db: Database
    ) throws -> AgentThreadHistoryPage {
        let limit = max(1, query.limit)
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
            LIMIT \(limit + 1)
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
            LIMIT \(limit + 1)
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
        let persistence = GRDBRuntimeStorePersistence(attachmentStore: attachmentStore)
        return try persistence.decodeHistoryRecord(from: row)
    }

    private func sqlPlaceholders(count: Int) -> String {
        "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
    }
}

extension GRDBRuntimeStateStore {
    static func defaultLegacyImportURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("json")
    }
}
