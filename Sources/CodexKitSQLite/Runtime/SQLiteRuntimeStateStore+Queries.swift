import Foundation
import CodexKit
import GRDB

extension SQLiteRuntimeStateStore {
    func executeHistoryQuery(_ query: HistoryItemsQuery) async throws -> AgentHistoryQueryResult {
        let queries = self.queries
        let result = try await dbQueue.read { db in
            guard try RuntimeThreadRow.fetchOne(db, key: query.threadID) != nil else {
                return AgentHistoryQueryResult(
                    threadID: query.threadID,
                    records: [],
                    nextCursor: nil,
                    previousCursor: nil,
                    hasMoreBefore: false,
                    hasMoreAfter: false
                )
            }
            return try queries.fetchHistoryQuery(query, in: db)
        }
        decodedHistoryBodyCount += result.records.count
        return result
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

            if let cursor = query.cursor {
                let dateColumn: Column
                let order: AgentSortOrder
                switch query.sort {
                case let .updatedAt(sortOrder):
                    dateColumn = Column("updatedAt")
                    order = sortOrder
                case let .createdAt(sortOrder):
                    dateColumn = Column("createdAt")
                    order = sortOrder
                }
                let timestamp = cursor.date.timeIntervalSince1970
                if order == .ascending {
                    request = request.filter(
                        dateColumn > timestamp ||
                            (dateColumn == timestamp && Column("threadID") > cursor.threadID)
                    )
                } else {
                    request = request.filter(
                        dateColumn < timestamp ||
                            (dateColumn == timestamp && Column("threadID") > cursor.threadID)
                    )
                }
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

            request = request.limit(
                AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
            )

            let rows = try boundedRuntimeRows(
                request.fetchCursor(db),
                payload: \.encodedThread,
                name: "thread query"
            )
            return try rows.map { try persistence.decodeThread(from: $0) }
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
            request = request.limit(
                AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
            )

            let rows = try boundedRuntimeRows(
                request.fetchCursor(db),
                payload: \.encodedState,
                name: "context query"
            )
            return try rows.map { try persistence.decodeContextState(from: $0) }
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

            request = request.limit(
                AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
            )

            let summaries = try boundedRuntimeRows(
                request.fetchCursor(db),
                payload: \.encodedSummary,
                name: "pending-state query"
            )
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

            var clauses: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            if let threadIDs = query.threadIDs {
                clauses.append("threadID IN \(runtimeSQLPlaceholders(count: threadIDs.count))")
                for threadID in threadIDs { arguments.append(threadID) }
            }
            if let formatNames = query.formatNames {
                clauses.append("formatName IN \(runtimeSQLPlaceholders(count: formatNames.count))")
                for formatName in formatNames { arguments.append(formatName) }
            }
            let filter = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
            let direction: String
            switch query.sort {
            case .committedAt(.ascending): direction = "ASC"
            case .committedAt(.descending): direction = "DESC"
            }
            let limitClause = "LIMIT \(AgentStoreLimitValidator.boundedOptionalLimit(query.limit))"
            let sql: String
            if query.latestOnly {
                sql = """
                SELECT outputID, threadID, formatName, committedAt, encodedRecord
                FROM (
                    SELECT *, ROW_NUMBER() OVER (
                        PARTITION BY threadID
                        ORDER BY committedAt DESC, outputID ASC
                    ) AS output_rank
                    FROM \(RuntimeStructuredOutputRow.databaseTableName)
                    \(filter)
                )
                WHERE output_rank = 1
                ORDER BY committedAt \(direction), threadID ASC
                \(limitClause)
                """
            } else {
                sql = """
                SELECT * FROM \(RuntimeStructuredOutputRow.databaseTableName)
                \(filter)
                ORDER BY committedAt \(direction), threadID ASC
                \(limitClause)
                """
            }
            let request = SQLRequest<RuntimeStructuredOutputRow>(
                sql: sql,
                arguments: StatementArguments(arguments)
            )
            let rows = try boundedRuntimeRows(
                request.fetchCursor(db),
                payload: \.encodedRecord,
                name: "structured-output query"
            )
            return try rows.map(persistence.decodeStructuredOutputRecord)
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

            request = request.limit(
                AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
            )

            let rows = try boundedRuntimeRows(
                request.fetchCursor(db),
                payload: \.encodedSummary,
                name: "snapshot query"
            )
            return try rows
                .map { try persistence.decodeSummary(from: $0) }
                .map(\.snapshot)
        }
    }
}
