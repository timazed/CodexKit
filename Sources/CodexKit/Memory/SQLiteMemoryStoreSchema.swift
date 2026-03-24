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
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_records (
                namespace TEXT NOT NULL,
                id TEXT NOT NULL,
                scope TEXT NOT NULL,
                kind TEXT NOT NULL,
                summary TEXT NOT NULL,
                evidence_json TEXT NOT NULL,
                importance REAL NOT NULL,
                created_at REAL NOT NULL,
                observed_at REAL,
                expires_at REAL,
                tags_json TEXT NOT NULL,
                related_ids_json TEXT NOT NULL,
                dedupe_key TEXT,
                is_pinned INTEGER NOT NULL,
                attributes_json TEXT,
                status TEXT NOT NULL,
                PRIMARY KEY(namespace, id)
            );
            """)

            try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS memory_records_namespace_dedupe
            ON memory_records(namespace, dedupe_key)
            WHERE dedupe_key IS NOT NULL;
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_records_namespace_scope
            ON memory_records(namespace, scope);
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_records_namespace_kind
            ON memory_records(namespace, kind);
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_records_namespace_status
            ON memory_records(namespace, status);
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_tags (
                namespace TEXT NOT NULL,
                record_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                FOREIGN KEY(namespace, record_id)
                    REFERENCES memory_records(namespace, id)
                    ON DELETE CASCADE
            );
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_tags_lookup
            ON memory_tags(namespace, tag, record_id);
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_related_ids (
                namespace TEXT NOT NULL,
                record_id TEXT NOT NULL,
                related_id TEXT NOT NULL,
                FOREIGN KEY(namespace, record_id)
                    REFERENCES memory_records(namespace, id)
                    ON DELETE CASCADE
            );
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS memory_related_lookup
            ON memory_related_ids(namespace, related_id, record_id);
            """)

            try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
            USING fts5(namespace UNINDEXED, record_id UNINDEXED, content);
            """)

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
