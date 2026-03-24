import Foundation
import GRDB

struct SQLiteMemoryStoreSchema: Sendable {
    let currentVersion = 1

    func existingVersion(in db: Database) throws -> Int {
        try MemoryUserVersionQuery().execute(in: db)
    }

    func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("memory_store_v1") { db in
            try db.create(table: "memory_records", ifNotExists: true) { table in
                table.column("namespace", .text).notNull()
                table.column("id", .text).notNull()
                table.column("scope", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("summary", .text).notNull()
                table.column("evidence_json", .text).notNull()
                table.column("importance", .double).notNull()
                table.column("created_at", .double).notNull()
                table.column("observed_at", .double)
                table.column("expires_at", .double)
                table.column("tags_json", .text).notNull()
                table.column("related_ids_json", .text).notNull()
                table.column("dedupe_key", .text)
                table.column("is_pinned", .boolean).notNull()
                table.column("attributes_json", .text)
                table.column("status", .text).notNull()
                table.primaryKey(["namespace", "id"])
            }

            // The dedupe index stays raw because it is both partial and unique.
            try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS memory_records_namespace_dedupe
            ON memory_records(namespace, dedupe_key)
            WHERE dedupe_key IS NOT NULL;
            """)
            try db.create(index: "memory_records_namespace_scope", on: "memory_records", columns: ["namespace", "scope"])
            try db.create(index: "memory_records_namespace_kind", on: "memory_records", columns: ["namespace", "kind"])
            try db.create(index: "memory_records_namespace_status", on: "memory_records", columns: ["namespace", "status"])

            try db.create(table: "memory_tags", ifNotExists: true) { table in
                table.column("namespace", .text).notNull()
                table.column("record_id", .text).notNull()
                table.column("tag", .text).notNull()
                table.foreignKey(["namespace", "record_id"], references: "memory_records", columns: ["namespace", "id"], onDelete: .cascade)
            }
            try db.create(index: "memory_tags_lookup", on: "memory_tags", columns: ["namespace", "tag", "record_id"])

            try db.create(table: "memory_related_ids", ifNotExists: true) { table in
                table.column("namespace", .text).notNull()
                table.column("record_id", .text).notNull()
                table.column("related_id", .text).notNull()
                table.foreignKey(["namespace", "record_id"], references: "memory_records", columns: ["namespace", "id"], onDelete: .cascade)
            }
            try db.create(index: "memory_related_lookup", on: "memory_related_ids", columns: ["namespace", "related_id", "record_id"])

            // FTS virtual-table creation still stays raw because it relies on
            // SQLite's module-specific DDL syntax rather than ordinary table creation.
            try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
            USING fts5(namespace UNINDEXED, record_id UNINDEXED, content);
            """)

            // PRAGMA user_version is SQLite-specific migration state.
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        return migrator
    }
}

struct MemoryUserVersionQuery: Sendable {
    func execute(in db: Database) throws -> Int {
        // PRAGMA is SQLite-specific and doesn't map cleanly to GRDB's query interface.
        let row = try SQLRequest<Row>(sql: "PRAGMA user_version;").fetchOne(db)
        return row?[0] ?? 0
    }
}
