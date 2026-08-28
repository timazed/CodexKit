import CodexKit
import Foundation
import GRDB
import SQLite3

extension SQLiteMemoryStoreRepository {
    struct RankedQueryStatement {
        let sql: String
        let arguments: StatementArguments
    }

    /// Ranks and packs a deterministic prefix inside SQLite. A cumulative
    /// window keeps both ranking and the aggregate budget in one native query;
    /// lower-ranked rows are never searched for a smaller replacement.
    func loadRankedRecords(
        matching query: MemoryQuery,
        now: Date,
        limit: Int,
        maxCharacters: Int,
        in db: Database
    ) throws -> RankedPage {
        let queryTokens = MemoryQueryEngine.uniqueTokens(query.text)
        guard limit > 0, maxCharacters > 0 else {
            return RankedPage(records: [], truncated: false, nextCursor: nil)
        }

        let statement = makeRankedQueryStatement(
            matching: query,
            now: now,
            limit: limit,
            maxCharacters: maxCharacters
        )
        let rows = try SQLRequest<Row>(
            sql: statement.sql,
            arguments: statement.arguments
        ).fetchAll(db)
        let candidateCount: Int = rows.first?["candidate_count"] ?? 0
        let selectedIDs = rows.compactMap { $0["selected_id"] as String? }
        let records = try makeRecords(ids: selectedIDs, namespace: query.namespace, in: db)
        let matchedTokenCounts = try loadMatchedTokenCounts(
            recordIDs: selectedIDs,
            namespace: query.namespace,
            queryTokens: queryTokens,
            in: db
        )
        let ranked = records.map { record in
            RankedRecord(
                record: record,
                explanation: MemoryQueryEngine.makeMatch(
                    record: record,
                    query: query,
                    now: now,
                    matchedTokenCount: matchedTokenCounts[record.id, default: 0],
                    queryTokenCount: queryTokens.count,
                    executionMethod: .databaseNative
                ).explanation
            )
        }
        let truncated = candidateCount > selectedIDs.count
        return RankedPage(
            records: ranked,
            truncated: truncated,
            nextCursor: truncated
                ? records.last.map { MemoryQueryEngine.cursor(for: $0, query: query) }
                : nil
        )
    }

    func rankedQueryPlan(
        matching query: MemoryQuery,
        now: Date,
        limit: Int,
        maxCharacters: Int,
        in db: Database
    ) throws -> [String] {
        let statement = makeRankedQueryStatement(
            matching: query,
            now: now,
            limit: limit,
            maxCharacters: maxCharacters
        )
        return try SQLRequest<Row>(
            sql: "EXPLAIN QUERY PLAN " + statement.sql,
            arguments: statement.arguments
        ).fetchAll(db).compactMap { $0["detail"] as String? }
    }

    func rankedQueryVirtualMachineSteps(
        matching query: MemoryQuery,
        now: Date,
        limit: Int,
        maxCharacters: Int,
        in db: Database
    ) throws -> Int {
        let query = makeRankedQueryStatement(
            matching: query,
            now: now,
            limit: limit,
            maxCharacters: maxCharacters
        )
        let statement = try db.makeStatement(sql: query.sql)
        _ = try Row.fetchAll(statement, arguments: query.arguments)
        return Int(sqlite3_stmt_status(
            statement.sqliteStatement,
            SQLITE_STMTSTATUS_VM_STEP,
            0
        ))
    }

    func makeRankedQueryStatement(
        matching query: MemoryQuery,
        now: Date,
        limit: Int,
        maxCharacters: Int
    ) -> RankedQueryStatement {
        let filter = queryFilter(query: query, now: now, tableAlias: "r")
        let nativeOrder = nativeOrderSQL(for: query, tableAlias: "r")
        let queryTokens = MemoryQueryEngine.uniqueTokens(query.text)
        let text = textPredicate(
            queryTokens: queryTokens,
            minimumMatches: MemoryQueryEngine.requiredTextMatchCount(
                policy: query.textMatchPolicy,
                queryTokenCount: queryTokens.count
            ),
            tableAlias: "r"
        )
        var arguments = filter.arguments + text.arguments
        arguments.append(maxCharacters)
        arguments.append(limit + 1)
        arguments.append(limit)
        arguments.append(maxCharacters)
        let boundedOrder = nativeOrderSQL(for: query, tableAlias: "c")
        return RankedQueryStatement(
            sql: """
            WITH candidate_window AS MATERIALIZED (
                SELECT r.id, r.importance, r.effective_at, r.record_order,
                       r.rendered_character_count
                FROM memory_records r
                WHERE \(filter.sql)\(text.sql)
                  AND r.rendered_character_count <= ?
                ORDER BY \(nativeOrder)
                LIMIT ?
            ), ranked AS (
                SELECT c.id,
                       ROW_NUMBER() OVER (ORDER BY \(boundedOrder)) AS position,
                       SUM(c.rendered_character_count) OVER (
                           ORDER BY \(boundedOrder)
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                       ) AS cumulative_characters
                FROM candidate_window c
            ), selection AS (
                SELECT id AS selected_id, position
                FROM ranked
                WHERE position <= ?
                  AND cumulative_characters + position - 1 <= ?
            )
            SELECT selected_id, position,
                   (SELECT COUNT(*) FROM candidate_window) AS candidate_count
            FROM selection
            UNION ALL
            SELECT NULL, -1, (SELECT COUNT(*) FROM candidate_window)
            WHERE NOT EXISTS (SELECT 1 FROM selection)
            ORDER BY position
            """,
            arguments: StatementArguments(arguments)
        )
    }

    func hasMatchingRecord(
        query: MemoryQuery,
        now: Date,
        queryTokens: [String],
        maxCharacters: Int,
        in db: Database
    ) throws -> Bool {
        let filter = queryFilter(query: query, now: now, tableAlias: "r")
        let text = textPredicate(
            queryTokens: queryTokens,
            minimumMatches: MemoryQueryEngine.requiredTextMatchCount(
                policy: query.textMatchPolicy,
                queryTokenCount: queryTokens.count
            ),
            tableAlias: "r"
        )
        var arguments = filter.arguments + text.arguments
        arguments.append(maxCharacters)
        return try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM memory_records r
                WHERE \(filter.sql)\(text.sql)
                  AND r.rendered_character_count <= ?
                LIMIT 1
            )
            """,
            arguments: StatementArguments(arguments)
        ) ?? false
    }

    func loadMatchedTokenCounts(
        recordIDs: [String],
        namespace: String,
        queryTokens: [String],
        in db: Database
    ) throws -> [String: Int] {
        guard !recordIDs.isEmpty, !queryTokens.isEmpty else { return [:] }
        var arguments: [any DatabaseValueConvertible] = [namespace]
        arguments.append(contentsOf: recordIDs)
        arguments.append(contentsOf: queryTokens)
        let rows = try SQLRequest<Row>(
            sql: """
            SELECT record_id, COUNT(*) AS matched_token_count
            FROM memory_search_tokens
            WHERE namespace = ?
              AND record_id IN \(placeholders(recordIDs.count))
              AND value IN \(placeholders(queryTokens.count))
            GROUP BY record_id
            """,
            arguments: StatementArguments(arguments)
        ).fetchAll(db)
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["record_id"] as String, row["matched_token_count"] as Int)
        })
    }

    func textPredicate(
        queryTokens: [String],
        minimumMatches: Int,
        tableAlias: String
    ) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        guard !queryTokens.isEmpty else { return ("", []) }
        var arguments: [any DatabaseValueConvertible] = queryTokens
        arguments.append(minimumMatches)
        return (
            """

              AND (
                  SELECT COUNT(*) FROM memory_search_tokens mst
                  WHERE mst.namespace = \(tableAlias).namespace
                    AND mst.record_id = \(tableAlias).id
                    AND mst.value IN \(placeholders(queryTokens.count))
              ) >= ?
            """,
            arguments
        )
    }

    func nativeOrderSQL(for query: MemoryQuery, tableAlias: String) -> String {
        if query.ranking == .recencyThenImportance {
            return "\(tableAlias).effective_at DESC, \(tableAlias).importance DESC, \(tableAlias).record_order ASC, \(tableAlias).id ASC"
        }
        return "\(tableAlias).importance DESC, \(tableAlias).effective_at DESC, \(tableAlias).record_order ASC, \(tableAlias).id ASC"
    }

    func queryFilter(
        query: MemoryQuery,
        now: Date,
        tableAlias: String
    ) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var clauses = ["\(tableAlias).namespace = ?"]
        var arguments: [any DatabaseValueConvertible] = [query.namespace]
        if !query.includeArchived {
            clauses.append("\(tableAlias).status = ?")
            arguments.append(MemoryRecordStatus.active.rawValue)
        }
        clauses.append("(\(tableAlias).is_pinned = 1 OR \(tableAlias).expires_at IS NULL OR \(tableAlias).expires_at > ?)")
        arguments.append(now.timeIntervalSince1970)
        if !query.scopes.isEmpty {
            clauses.append("\(tableAlias).scope IN \(placeholders(query.scopes.count))")
            arguments.append(contentsOf: query.scopes.map(\.rawValue))
        }
        if !query.categories.isEmpty {
            clauses.append("\(tableAlias).category IN \(placeholders(query.categories.count))")
            arguments.append(contentsOf: query.categories)
        }
        if !query.tags.isEmpty {
            clauses.append("""
            EXISTS (
                SELECT 1 FROM memory_tags mt
                WHERE mt.namespace = \(tableAlias).namespace
                  AND mt.record_id = \(tableAlias).id
                  AND mt.value IN \(placeholders(query.tags.count))
            )
            """)
            arguments.append(contentsOf: query.tags)
        }
        if !query.relatedIDs.isEmpty {
            clauses.append("""
            EXISTS (
                SELECT 1 FROM memory_related_ids mr
                WHERE mr.namespace = \(tableAlias).namespace
                  AND mr.record_id = \(tableAlias).id
                  AND mr.value IN \(placeholders(query.relatedIDs.count))
            )
            """)
            arguments.append(contentsOf: query.relatedIDs)
        }
        if let minImportance = query.minImportance {
            clauses.append("\(tableAlias).importance >= ?")
            arguments.append(minImportance)
        }
        if let recencyWindow = query.recencyWindow {
            clauses.append("\(tableAlias).effective_at >= ?")
            arguments.append(now.addingTimeInterval(-recencyWindow).timeIntervalSince1970)
        }
        if let cursor = query.cursor {
            let importance = cursor.importance
            let effectiveAt = cursor.effectiveDate.timeIntervalSince1970
            let recordOrder = cursor.recordOrder
            switch query.ranking {
            case .importanceThenRecency:
                clauses.append("""
                (
                    \(tableAlias).importance < ?
                    OR (\(tableAlias).importance = ? AND \(tableAlias).effective_at < ?)
                    OR (\(tableAlias).importance = ? AND \(tableAlias).effective_at = ? AND \(tableAlias).record_order > ?)
                    OR (\(tableAlias).importance = ? AND \(tableAlias).effective_at = ? AND \(tableAlias).record_order = ? AND \(tableAlias).id > ?)
                )
                """)
                arguments.append(contentsOf: [any DatabaseValueConvertible](arrayLiteral:
                    importance, importance, effectiveAt,
                    importance, effectiveAt, recordOrder,
                    importance, effectiveAt, recordOrder, cursor.recordID
                ))
            case .recencyThenImportance:
                clauses.append("""
                (
                    \(tableAlias).effective_at < ?
                    OR (\(tableAlias).effective_at = ? AND \(tableAlias).importance < ?)
                    OR (\(tableAlias).effective_at = ? AND \(tableAlias).importance = ? AND \(tableAlias).record_order > ?)
                    OR (\(tableAlias).effective_at = ? AND \(tableAlias).importance = ? AND \(tableAlias).record_order = ? AND \(tableAlias).id > ?)
                )
                """)
                arguments.append(contentsOf: [any DatabaseValueConvertible](arrayLiteral:
                    effectiveAt, effectiveAt, importance,
                    effectiveAt, importance, recordOrder,
                    effectiveAt, importance, recordOrder, cursor.recordID
                ))
            }
        }
        return (clauses.joined(separator: " AND "), arguments)
    }

    func placeholders(_ count: Int) -> String {
        "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
    }
}
