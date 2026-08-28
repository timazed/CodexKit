import CodexKit
import Foundation
import GRDB

extension SQLiteRuntimeStoreSchema {
    func backfillAttachmentReferences(in db: Database) throws {
        let decoder = JSONDecoder()
        var historyCursor: String?
        while true {
            let rows = try nextHistoryAttachmentBatch(after: historyCursor, in: db)
            guard !rows.isEmpty else { break }
            for row in rows {
                try validateBoundedRuntimePayload(row.encodedRecord, name: "stored history record")
                guard let persisted = try? decoder.decode(
                    PersistedAgentHistoryRecord.self,
                    from: row.encodedRecord
                ) else { continue }
                try persisted.validateAttachmentReferences(using: attachmentStore)
                for storageKey in Set(persisted.attachmentStorageKeys) {
                    try RuntimeAttachmentReferenceRow(
                        ownerType: "history",
                        ownerKey: row.storageID,
                        threadID: row.threadID,
                        storageKey: storageKey
                    ).insert(db, onConflict: .ignore)
                }
            }
            historyCursor = rows.last?.storageID
        }

        var contextCursor: String?
        while true {
            let rows = try nextContextBatch(after: contextCursor, in: db)
            guard !rows.isEmpty else { break }
            for row in rows {
                try validateBoundedRuntimePayload(row.encodedState, name: "stored context state")
                guard let persisted = try? decoder.decode(
                    PersistedAgentThreadContextState.self,
                    from: row.encodedState
                ) else { continue }
                try persisted.validate(using: attachmentStore)
                for storageKey in Set(persisted.attachmentStorageKeys) {
                    try RuntimeAttachmentReferenceRow(
                        ownerType: "context",
                        ownerKey: row.threadID,
                        threadID: row.threadID,
                        storageKey: storageKey
                    ).insert(db, onConflict: .ignore)
                }
            }
            contextCursor = rows.last?.threadID
        }
    }

    func backfillHistoryProjections(in db: Database) throws {
        let decoder = JSONDecoder()
        var cursor: String?
        while true {
            let rows = try nextHistoryBatch(after: cursor, in: db)
            guard !rows.isEmpty else { break }
            for row in rows {
                try validateBoundedRuntimePayload(row.encodedRecord, name: "stored history record")
                let record: AgentHistoryRecord
                if let persisted = try? decoder.decode(
                    PersistedAgentHistoryRecord.self,
                    from: row.encodedRecord
                ) {
                    record = try persisted.decodeForProjection(using: attachmentStore)
                } else {
                    record = try decoder.decode(AgentHistoryRecord.self, from: row.encodedRecord)
                }
                try AgentStoreLimitValidator.validateLoadedHistoryRecord(
                    record,
                    expectedThreadID: row.threadID
                )
                try db.execute(
                    sql: """
                    UPDATE \(RuntimeHistoryRow.databaseTableName)
                    SET messageRole = ?, hasStructuredOutput = ?, systemEventType = ?
                    WHERE storageID = ?
                    """,
                    arguments: [
                        record.item.messageRole?.rawValue,
                        record.item.hasQueryableStructuredOutput,
                        record.item.systemEventType?.rawValue,
                        row.storageID,
                    ]
                )
            }
            cursor = rows.last?.storageID
        }
    }

    func backfillHistoryRelationships(in db: Database) throws {
        let decoder = JSONDecoder()
        var cursor: String?
        while true {
            let rows = try nextHistoryBatch(after: cursor, in: db)
            guard !rows.isEmpty else { break }
            for row in rows {
                try validateBoundedRuntimePayload(row.encodedRecord, name: "stored history record")
                let record: AgentHistoryRecord
                if let persisted = try? decoder.decode(
                    PersistedAgentHistoryRecord.self,
                    from: row.encodedRecord
                ) {
                    record = try persisted.decodeForProjection(using: attachmentStore)
                } else {
                    record = try decoder.decode(AgentHistoryRecord.self, from: row.encodedRecord)
                }
                try AgentStoreLimitValidator.validateLoadedHistoryRecord(
                    record,
                    expectedThreadID: row.threadID
                )
                try db.execute(
                    sql: """
                    UPDATE \(RuntimeHistoryRow.databaseTableName)
                    SET relationshipKey = ?
                    WHERE storageID = ?
                    """,
                    arguments: [record.item.relationshipKey, row.storageID]
                )
            }
            cursor = rows.last?.storageID
        }
    }

    private func nextHistoryAttachmentBatch(
        after cursor: String?,
        in db: Database
    ) throws -> [RuntimeHistoryAttachmentBackfillRow] {
        let predicate = cursor == nil ? "" : "WHERE storageID > ?"
        let request = SQLRequest<RuntimeHistoryAttachmentBackfillRow>(
            sql: """
            SELECT storageID, threadID, encodedRecord
            FROM \(RuntimeHistoryRow.databaseTableName)
            \(predicate)
            ORDER BY storageID
            LIMIT 4
            """,
            arguments: cursor.map { [$0] } ?? []
        )
        return try boundedRuntimeRows(
            request.fetchCursor(db),
            payload: \.encodedRecord,
            name: "history attachment backfill"
        )
    }

    private func nextHistoryBatch(
        after cursor: String?,
        in db: Database
    ) throws -> [RuntimeHistoryRow] {
        let predicate = cursor == nil ? "" : "WHERE storageID > ?"
        let request = SQLRequest<RuntimeHistoryRow>(
            sql: """
            SELECT * FROM \(RuntimeHistoryRow.databaseTableName)
            \(predicate)
            ORDER BY storageID
            LIMIT 4
            """,
            arguments: cursor.map { [$0] } ?? []
        )
        return try boundedRuntimeRows(
            request.fetchCursor(db),
            payload: \.encodedRecord,
            name: "history projection backfill"
        )
    }

    private func nextContextBatch(
        after cursor: String?,
        in db: Database
    ) throws -> [RuntimeContextStateRow] {
        let predicate = cursor == nil ? "" : "WHERE threadID > ?"
        let request = SQLRequest<RuntimeContextStateRow>(
            sql: """
            SELECT * FROM \(RuntimeContextStateRow.databaseTableName)
            \(predicate)
            ORDER BY threadID
            LIMIT 4
            """,
            arguments: cursor.map { [$0] } ?? []
        )
        return try boundedRuntimeRows(
            request.fetchCursor(db),
            payload: \.encodedState,
            name: "context projection backfill"
        )
    }
}
