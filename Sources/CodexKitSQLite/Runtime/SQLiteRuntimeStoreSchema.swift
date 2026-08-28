import Foundation
import CodexKit
import GRDB

struct SQLiteRuntimeStoreSchema: Sendable {
    let currentStoreSchemaVersion: Int
    let attachmentStore: RuntimeAttachmentStore

    func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("runtime_store_v1") { db in
            try db.create(table: RuntimeThreadRow.databaseTableName) { table in
                table.column("threadID", .text).primaryKey()
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
                table.column("status", .text).notNull()
                table.column("nextHistorySequence", .integer).notNull().defaults(to: 1)
                table.column("encodedThread", .blob).notNull()
            }

            try db.create(table: RuntimeSummaryRow.databaseTableName) { table in
                table.column("threadID", .text)
                    .primaryKey()
                    .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                table.column("createdAt", .double).notNull()
                table.column("updatedAt", .double).notNull()
                table.column("latestItemAt", .double)
                table.column("itemCount", .integer)
                table.column("pendingStateKind", .text)
                table.column("latestStructuredOutputFormatName", .text)
                table.column("encodedSummary", .blob).notNull()
            }

            try db.create(table: RuntimeHistoryRow.databaseTableName) { table in
                table.column("storageID", .text).primaryKey()
                table.column("recordID", .text).notNull()
                table.column("threadID", .text)
                    .notNull()
                    .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                table.column("sequenceNumber", .integer).notNull()
                table.column("createdAt", .double).notNull()
                table.column("kind", .text).notNull()
                table.column("turnID", .text)
                table.column("relationshipKey", .text)
                table.column("isCompactionMarker", .boolean).notNull().defaults(to: false)
                table.column("isRedacted", .boolean).notNull().defaults(to: false)
                table.column("messageRole", .text)
                table.column("hasStructuredOutput", .boolean).notNull().defaults(to: false)
                table.column("systemEventType", .text)
                table.column("encodedRecord", .blob).notNull()
            }

            try db.create(index: "runtime_history_thread_sequence", on: RuntimeHistoryRow.databaseTableName, columns: ["threadID", "sequenceNumber"], unique: true)
            try db.create(index: "runtime_history_thread_created_at", on: RuntimeHistoryRow.databaseTableName, columns: ["threadID", "createdAt"])
            try db.create(index: "runtime_history_thread_kind", on: RuntimeHistoryRow.databaseTableName, columns: ["threadID", "kind"])
            try db.create(index: "runtime_history_thread_record_id", on: RuntimeHistoryRow.databaseTableName, columns: ["threadID", "recordID"])
            try db.create(index: "runtime_history_thread_relationship", on: RuntimeHistoryRow.databaseTableName, columns: ["threadID", "relationshipKey", "sequenceNumber"])
            try db.execute(sql: """
            CREATE UNIQUE INDEX runtime_history_relationship_kind
            ON \(RuntimeHistoryRow.databaseTableName)(threadID, relationshipKey, kind)
            WHERE relationshipKey IS NOT NULL;
            """)

            try db.create(table: RuntimeStructuredOutputRow.databaseTableName) { table in
                table.column("outputID", .text).primaryKey()
                table.column("threadID", .text)
                    .notNull()
                    .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                table.column("formatName", .text).notNull()
                table.column("committedAt", .double).notNull()
                table.column("encodedRecord", .blob).notNull()
            }

            try db.create(index: "runtime_structured_outputs_thread_committed_at", on: RuntimeStructuredOutputRow.databaseTableName, columns: ["threadID", "committedAt"])
            try db.create(index: "runtime_structured_outputs_format_name", on: RuntimeStructuredOutputRow.databaseTableName, columns: ["formatName"])

            try db.create(table: RuntimeContextStateRow.databaseTableName) { table in
                table.column("threadID", .text)
                    .primaryKey()
                    .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                table.column("generation", .integer).notNull()
                table.column("encodedState", .blob).notNull()
            }

            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        migrator.registerMigration("runtime_store_v2_compaction_state") { db in
            let historyColumns = try db.columns(in: RuntimeHistoryRow.databaseTableName).map(\.name)
            if !historyColumns.contains("isCompactionMarker") {
                try db.alter(table: RuntimeHistoryRow.databaseTableName) { table in
                    table.add(column: "isCompactionMarker", .boolean).notNull().defaults(to: false)
                }
            }

            if try !db.tableExists(RuntimeContextStateRow.databaseTableName) {
                try db.create(table: RuntimeContextStateRow.databaseTableName) { table in
                    table.column("threadID", .text)
                        .primaryKey()
                        .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                    table.column("generation", .integer).notNull()
                    table.column("encodedState", .blob).notNull()
                }
            }

            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        migrator.registerMigration("runtime_store_v3_query_indexes") { db in
            try db.create(
                index: "runtime_threads_status_updated_at",
                on: RuntimeThreadRow.databaseTableName,
                columns: ["status", "updatedAt", "threadID"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_threads_updated_at",
                on: RuntimeThreadRow.databaseTableName,
                columns: ["updatedAt", "threadID"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_threads_created_at",
                on: RuntimeThreadRow.databaseTableName,
                columns: ["createdAt", "threadID"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_summaries_pending_updated_at",
                on: RuntimeSummaryRow.databaseTableName,
                columns: ["pendingStateKind", "updatedAt", "threadID"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_summaries_updated_at",
                on: RuntimeSummaryRow.databaseTableName,
                columns: ["updatedAt", "threadID"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_summaries_created_at",
                on: RuntimeSummaryRow.databaseTableName,
                columns: ["createdAt", "threadID"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_history_thread_turn_sequence",
                on: RuntimeHistoryRow.databaseTableName,
                columns: ["threadID", "turnID", "sequenceNumber"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_context_generation",
                on: RuntimeContextStateRow.databaseTableName,
                columns: ["generation", "threadID"],
                ifNotExists: true
            )
            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        migrator.registerMigration("runtime_store_v3_attachment_recovery") { db in
            if try !db.tableExists(RuntimeAttachmentCleanupRow.databaseTableName) {
                try db.create(table: RuntimeAttachmentCleanupRow.databaseTableName) { table in
                    table.column("storageKey", .text).primaryKey()
                }
            }

            if try !db.tableExists(RuntimeStoreMetadataRow.databaseTableName) {
                try db.create(table: RuntimeStoreMetadataRow.databaseTableName) { table in
                    table.column("id", .text).primaryKey()
                    table.column("legacyImportCompleted", .boolean).notNull().defaults(to: false)
                }
                try RuntimeStoreMetadataRow(
                    id: "runtime",
                    legacyImportCompleted: false
                ).insert(db)
            }

            // Structured-output record identifiers are only unique within a
            // thread. Prefix existing projections so future records in another
            // thread cannot overwrite them.
            try db.execute(
                sql: """
                UPDATE \(RuntimeStructuredOutputRow.databaseTableName)
                SET outputID = threadID || ':' || outputID
                WHERE substr(outputID, 1, length(threadID) + 1) != threadID || ':'
                """
            )
            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        migrator.registerMigration("runtime_store_v3_attachment_references") { db in
            try db.create(table: RuntimeAttachmentReferenceRow.databaseTableName, ifNotExists: true) { table in
                table.column("ownerType", .text).notNull()
                table.column("ownerKey", .text).notNull()
                table.column("threadID", .text)
                    .notNull()
                    .references(RuntimeThreadRow.databaseTableName, onDelete: .cascade)
                table.column("storageKey", .text).notNull()
                table.primaryKey(["ownerType", "ownerKey", "storageKey"])
            }
            try db.create(
                index: "runtime_attachment_references_storage_key",
                on: RuntimeAttachmentReferenceRow.databaseTableName,
                columns: ["storageKey"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_attachment_references_thread",
                on: RuntimeAttachmentReferenceRow.databaseTableName,
                columns: ["threadID"],
                ifNotExists: true
            )

            try backfillAttachmentReferences(in: db)
            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        migrator.registerMigration("runtime_store_v3_summary_projections") { db in
            let columns = try db.columns(in: RuntimeHistoryRow.databaseTableName).map(\.name)
            if !columns.contains("messageRole") ||
                !columns.contains("hasStructuredOutput") ||
                !columns.contains("systemEventType") ||
                !columns.contains("relationshipKey") {
                try db.alter(table: RuntimeHistoryRow.databaseTableName) { table in
                    if !columns.contains("messageRole") {
                        table.add(column: "messageRole", .text)
                    }
                    if !columns.contains("hasStructuredOutput") {
                        table.add(column: "hasStructuredOutput", .boolean)
                            .notNull()
                            .defaults(to: false)
                    }
                    if !columns.contains("systemEventType") {
                        table.add(column: "systemEventType", .text)
                    }
                    if !columns.contains("relationshipKey") {
                        table.add(column: "relationshipKey", .text)
                    }
                }
            }

            try backfillHistoryProjections(in: db)
            try db.create(
                index: "runtime_history_summary_message",
                on: RuntimeHistoryRow.databaseTableName,
                columns: ["threadID", "kind", "messageRole", "sequenceNumber"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_history_summary_structured",
                on: RuntimeHistoryRow.databaseTableName,
                columns: ["threadID", "hasStructuredOutput", "sequenceNumber"],
                ifNotExists: true
            )
            try db.create(
                index: "runtime_history_summary_event",
                on: RuntimeHistoryRow.databaseTableName,
                columns: ["threadID", "kind", "systemEventType", "sequenceNumber"],
                ifNotExists: true
            )
            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        migrator.registerMigration("runtime_store_v3_history_invariants") { db in
            let threadColumns = try db.columns(in: RuntimeThreadRow.databaseTableName).map(\.name)
            if !threadColumns.contains("nextHistorySequence") {
                try db.alter(table: RuntimeThreadRow.databaseTableName) { table in
                    table.add(column: "nextHistorySequence", .integer)
                        .notNull()
                        .defaults(to: 1)
                }
                try db.execute(sql: """
                UPDATE \(RuntimeThreadRow.databaseTableName)
                SET nextHistorySequence = COALESCE(
                    (SELECT CASE
                        WHEN MAX(sequenceNumber) >= \(Int.max - 1) THEN \(Int.max)
                        ELSE MAX(sequenceNumber) + 1
                     END
                     FROM \(RuntimeHistoryRow.databaseTableName)
                     WHERE threadID = \(RuntimeThreadRow.databaseTableName).threadID),
                    1
                );
                """)
            }

            let historyColumns = try db.columns(in: RuntimeHistoryRow.databaseTableName).map(\.name)
            if !historyColumns.contains("relationshipKey") {
                try db.alter(table: RuntimeHistoryRow.databaseTableName) { table in
                    table.add(column: "relationshipKey", .text)
                }
            }
            try backfillHistoryRelationships(in: db)
            try db.create(
                index: "runtime_history_thread_relationship",
                on: RuntimeHistoryRow.databaseTableName,
                columns: ["threadID", "relationshipKey", "sequenceNumber"],
                ifNotExists: true
            )
            try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS runtime_history_relationship_kind
            ON \(RuntimeHistoryRow.databaseTableName)(threadID, relationshipKey, kind)
            WHERE relationshipKey IS NOT NULL;
            """)
            try db.execute(sql: "PRAGMA user_version = \(currentStoreSchemaVersion)")
        }

        return migrator
    }
}
