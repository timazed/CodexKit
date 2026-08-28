import CodexKit
import Foundation
import GRDB

struct SQLiteMemoryStoreSchema: Sendable {
    // v1 is the released baseline. All unreleased structured-store work ships as v2.
    let currentVersion = 2

    func existingVersion(in db: Database) throws -> Int {
        try MemoryUserVersionQuery().execute(in: db)
    }

    func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("memory_store_v1") { db in
            try createStructuredTables(in: db)
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        migrator.registerMigration("memory_store_v2_query_indexes") { db in
            let columns = try db.columns(in: SQLiteMemoryRecord.databaseTableName).map(\.name)
            if columns.contains("category") {
                try createStructuredIndexes(in: db)
            } else {
                try db.create(
                    index: "memory_records_namespace_importance",
                    on: "memory_records",
                    columns: ["namespace", "importance"],
                    ifNotExists: true
                )
                try db.create(
                    index: "memory_records_namespace_expiration",
                    on: "memory_records",
                    columns: ["namespace", "status", "is_pinned", "expires_at"],
                    ifNotExists: true
                )
                try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS memory_records_namespace_effective_date
                ON memory_records(namespace, COALESCE(observed_at, created_at) DESC, id ASC);
                """)
            }
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        migrator.registerMigration("memory_store_v2_rendered_character_count") { db in
            let columns = try db.columns(in: SQLiteMemoryRecord.databaseTableName).map(\.name)
            if !columns.contains("rendered_character_count") {
                try db.alter(table: SQLiteMemoryRecord.databaseTableName) { table in
                    table.add(column: "rendered_character_count", .integer)
                        .notNull()
                        .defaults(to: 0)
                }
            }
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        // Version four existed only in the legacy denormalized schema. Keep
        // this migration so databases that already recorded versions 1-3 can
        // reach the structured version-five migration in order.
        migrator.registerMigration("memory_store_v2_ranking_importance") { db in
            let columns = try db.columns(in: SQLiteMemoryRecord.databaseTableName).map(\.name)
            if columns.contains("evidence_json"), !columns.contains("ranking_importance") {
                try db.alter(table: SQLiteMemoryRecord.databaseTableName) { table in
                    table.add(column: "ranking_importance", .double)
                        .notNull()
                        .defaults(to: 0)
                }
                try db.execute(sql: """
                UPDATE memory_records
                SET ranking_importance = MIN(1.0, MAX(0.0, importance));
                """)
            }
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        migrator.registerMigration("memory_store_v2_structured_records") { db in
            let columns = try db.columns(in: SQLiteMemoryRecord.databaseTableName).map(\.name)
            if columns.contains("evidence_json") {
                try migrateLegacyRecords(in: db)
            } else {
                try createStructuredTables(in: db)
                try createStructuredIndexes(in: db)
            }
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        migrator.registerMigration("memory_store_v2_native_order_indexes") { db in
            let columns = try db.columns(in: SQLiteMemoryRecord.databaseTableName).map(\.name)
            if !columns.contains("record_order") {
                try db.alter(table: SQLiteMemoryRecord.databaseTableName) { table in
                    table.add(column: "record_order", .integer)
                        .notNull()
                        .defaults(to: 0)
                }
            }
            try rebuildRecordOrders(in: db)
            try createNativeOrderIndexes(in: db)
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        migrator.registerMigration("memory_store_v2_normalized_search_tokens") { db in
            try rebuildSearchTokens(in: db)
            if try db.tableExists("memory_fts") {
                try db.drop(table: "memory_fts")
            }
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        migrator.registerMigration("memory_store_v2_diagnostics_and_complete_ranking_indexes") { db in
            try createNativeOrderIndexes(in: db)
            try createDiagnosticsTables(in: db)
            try rebuildDiagnostics(in: db)
            try createDiagnosticsTriggers(in: db)
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        migrator.registerMigration("memory_store_v2_text_match_count_index") { db in
            try createSearchTokenLookupIndex(in: db)
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        migrator.registerMigration("memory_store_v2_diagnostics_cardinality") { db in
            try validateDiagnosticsCardinality(in: db)
            try createDiagnosticsCardinalityTriggers(in: db)
            try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
        }

        return migrator
    }

    private func createStructuredTables(in db: Database) throws {
        try db.create(table: SQLiteMemoryRecord.databaseTableName, ifNotExists: true) { table in
            table.column("namespace", .text).notNull()
            table.column("id", .text).notNull()
            table.column("record_order", .integer).notNull()
            table.column("scope", .text).notNull()
            table.column("category", .text).notNull()
            table.column("summary", .text).notNull()
            table.column("importance", .double).notNull()
            table.column("created_at", .double).notNull()
            table.column("observed_at", .double)
            table.column("effective_at", .double).notNull()
            table.column("expires_at", .double)
            table.column("dedupe_key", .text)
            table.column("is_pinned", .boolean).notNull()
            table.column("attributes_json", .text)
            table.column("status", .text).notNull()
            table.column("rendered_character_count", .integer).notNull()
            table.primaryKey(["namespace", "id"])
        }
        try createChildTable(
            SQLiteMemoryEvidence.databaseTableName,
            in: db
        )
        try createChildTable(SQLiteMemoryTag.databaseTableName, in: db)
        try createChildTable(SQLiteMemoryRelatedID.databaseTableName, in: db)
        try createSearchTokenTable(in: db)
        try createDiagnosticsTables(in: db)
        try createDiagnosticsTriggers(in: db)
        try createStructuredIndexes(in: db)
    }

    func createChildTable(_ name: String, in db: Database) throws {
        try db.create(table: name, ifNotExists: true) { table in
            table.column("namespace", .text).notNull()
            table.column("record_id", .text).notNull()
            table.column("ordinal", .integer).notNull()
            table.column("value", .text).notNull()
            table.primaryKey(["namespace", "record_id", "ordinal"])
            table.foreignKey(
                ["namespace", "record_id"],
                references: SQLiteMemoryRecord.databaseTableName,
                columns: ["namespace", "id"],
                onDelete: .cascade
            )
        }
    }

    func createSearchTokenTable(in db: Database) throws {
        try db.create(
            table: SQLiteMemorySearchToken.databaseTableName,
            ifNotExists: true
        ) { table in
            table.column("namespace", .text).notNull()
            table.column("record_id", .text).notNull()
            table.column("value", .text).notNull()
            table.primaryKey(["namespace", "record_id", "value"])
            table.foreignKey(
                ["namespace", "record_id"],
                references: SQLiteMemoryRecord.databaseTableName,
                columns: ["namespace", "id"],
                onDelete: .cascade
            )
        }
    }

    func createStructuredIndexes(in db: Database) throws {
        try db.execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS memory_records_namespace_dedupe
        ON memory_records(namespace, dedupe_key)
        WHERE dedupe_key IS NOT NULL;
        """)
        try db.create(index: "memory_records_namespace_scope", on: "memory_records", columns: ["namespace", "scope"], ifNotExists: true)
        try db.create(index: "memory_records_namespace_category", on: "memory_records", columns: ["namespace", "category"], ifNotExists: true)
        try db.create(index: "memory_records_namespace_status", on: "memory_records", columns: ["namespace", "status"], ifNotExists: true)
        try db.create(index: "memory_records_namespace_importance", on: "memory_records", columns: ["namespace", "importance"], ifNotExists: true)
        try db.create(index: "memory_records_namespace_expiration", on: "memory_records", columns: ["namespace", "status", "is_pinned", "expires_at"], ifNotExists: true)
        try db.create(index: "memory_records_namespace_effective_date", on: "memory_records", columns: ["namespace", "effective_at", "id"], ifNotExists: true)
        try db.create(index: "memory_tags_lookup", on: "memory_tags", columns: ["namespace", "value", "record_id"], ifNotExists: true)
        try db.create(index: "memory_related_lookup", on: "memory_related_ids", columns: ["namespace", "value", "record_id"], ifNotExists: true)
        try createSearchTokenLookupIndex(in: db)
        try createNativeOrderIndexes(in: db)
    }

    private func createSearchTokenLookupIndex(in db: Database) throws {
        try db.create(
            index: "memory_search_tokens_lookup",
            on: "memory_search_tokens",
            columns: ["namespace", "value", "record_id"],
            ifNotExists: true
        )
    }

    private func createNativeOrderIndexes(in db: Database) throws {
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS memory_records_active_importance_recency
        ON memory_records(namespace, status, importance DESC, effective_at DESC, record_order ASC, id ASC);

        CREATE INDEX IF NOT EXISTS memory_records_active_recency_importance
        ON memory_records(namespace, status, effective_at DESC, importance DESC, record_order ASC, id ASC);

        CREATE INDEX IF NOT EXISTS memory_records_importance_recency
        ON memory_records(namespace, importance DESC, effective_at DESC, record_order ASC, id ASC);

        CREATE INDEX IF NOT EXISTS memory_records_recency_importance
        ON memory_records(namespace, effective_at DESC, importance DESC, record_order ASC, id ASC);
        """)
    }

    private func createDiagnosticsTables(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS memory_diagnostics (
            namespace TEXT NOT NULL PRIMARY KEY,
            total_count INTEGER NOT NULL,
            active_count INTEGER NOT NULL,
            archived_count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS memory_diagnostic_scopes (
            namespace TEXT NOT NULL,
            value TEXT NOT NULL,
            record_count INTEGER NOT NULL,
            PRIMARY KEY (namespace, value),
            FOREIGN KEY (namespace) REFERENCES memory_diagnostics(namespace) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS memory_diagnostic_categories (
            namespace TEXT NOT NULL,
            value TEXT NOT NULL,
            record_count INTEGER NOT NULL,
            PRIMARY KEY (namespace, value),
            FOREIGN KEY (namespace) REFERENCES memory_diagnostics(namespace) ON DELETE CASCADE
        );
        """)
    }

    private func rebuildDiagnostics(in db: Database) throws {
        try db.execute(sql: """
        DELETE FROM memory_diagnostic_scopes;
        DELETE FROM memory_diagnostic_categories;
        DELETE FROM memory_diagnostics;
        INSERT INTO memory_diagnostics (namespace, total_count, active_count, archived_count)
        SELECT namespace,
               COUNT(*),
               SUM(status = 'active'),
               SUM(status = 'archived')
        FROM memory_records
        GROUP BY namespace;
        INSERT INTO memory_diagnostic_scopes (namespace, value, record_count)
        SELECT namespace, scope, COUNT(*)
        FROM memory_records
        GROUP BY namespace, scope;
        INSERT INTO memory_diagnostic_categories (namespace, value, record_count)
        SELECT namespace, category, COUNT(*)
        FROM memory_records
        GROUP BY namespace, category;
        """)
    }

    private func createDiagnosticsTriggers(in db: Database) throws {
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS memory_diagnostics_after_insert
        AFTER INSERT ON memory_records
        BEGIN
            INSERT INTO memory_diagnostics(namespace, total_count, active_count, archived_count)
            VALUES (NEW.namespace, 1, NEW.status = 'active', NEW.status = 'archived')
            ON CONFLICT(namespace) DO UPDATE SET
                total_count = total_count + 1,
                active_count = active_count + (NEW.status = 'active'),
                archived_count = archived_count + (NEW.status = 'archived');
            INSERT INTO memory_diagnostic_scopes(namespace, value, record_count)
            VALUES (NEW.namespace, NEW.scope, 1)
            ON CONFLICT(namespace, value) DO UPDATE SET record_count = record_count + 1;
            INSERT INTO memory_diagnostic_categories(namespace, value, record_count)
            VALUES (NEW.namespace, NEW.category, 1)
            ON CONFLICT(namespace, value) DO UPDATE SET record_count = record_count + 1;
        END;

        CREATE TRIGGER IF NOT EXISTS memory_diagnostics_after_delete
        AFTER DELETE ON memory_records
        BEGIN
            UPDATE memory_diagnostics SET
                total_count = total_count - 1,
                active_count = active_count - (OLD.status = 'active'),
                archived_count = archived_count - (OLD.status = 'archived')
            WHERE namespace = OLD.namespace;
            UPDATE memory_diagnostic_scopes SET record_count = record_count - 1
            WHERE namespace = OLD.namespace AND value = OLD.scope;
            DELETE FROM memory_diagnostic_scopes
            WHERE namespace = OLD.namespace AND value = OLD.scope AND record_count = 0;
            UPDATE memory_diagnostic_categories SET record_count = record_count - 1
            WHERE namespace = OLD.namespace AND value = OLD.category;
            DELETE FROM memory_diagnostic_categories
            WHERE namespace = OLD.namespace AND value = OLD.category AND record_count = 0;
            DELETE FROM memory_diagnostics
            WHERE namespace = OLD.namespace AND total_count = 0;
        END;

        CREATE TRIGGER IF NOT EXISTS memory_diagnostics_after_update
        AFTER UPDATE OF namespace, status, scope, category ON memory_records
        WHEN OLD.namespace != NEW.namespace OR OLD.status != NEW.status
          OR OLD.scope != NEW.scope OR OLD.category != NEW.category
        BEGIN
            UPDATE memory_diagnostics SET
                total_count = total_count - 1,
                active_count = active_count - (OLD.status = 'active'),
                archived_count = archived_count - (OLD.status = 'archived')
            WHERE namespace = OLD.namespace;
            UPDATE memory_diagnostic_scopes SET record_count = record_count - 1
            WHERE namespace = OLD.namespace AND value = OLD.scope;
            DELETE FROM memory_diagnostic_scopes
            WHERE namespace = OLD.namespace AND value = OLD.scope AND record_count = 0;
            UPDATE memory_diagnostic_categories SET record_count = record_count - 1
            WHERE namespace = OLD.namespace AND value = OLD.category;
            DELETE FROM memory_diagnostic_categories
            WHERE namespace = OLD.namespace AND value = OLD.category AND record_count = 0;
            DELETE FROM memory_diagnostics
            WHERE namespace = OLD.namespace AND total_count = 0;

            INSERT INTO memory_diagnostics(namespace, total_count, active_count, archived_count)
            VALUES (NEW.namespace, 1, NEW.status = 'active', NEW.status = 'archived')
            ON CONFLICT(namespace) DO UPDATE SET
                total_count = total_count + 1,
                active_count = active_count + (NEW.status = 'active'),
                archived_count = archived_count + (NEW.status = 'archived');
            INSERT INTO memory_diagnostic_scopes(namespace, value, record_count)
            VALUES (NEW.namespace, NEW.scope, 1)
            ON CONFLICT(namespace, value) DO UPDATE SET record_count = record_count + 1;
            INSERT INTO memory_diagnostic_categories(namespace, value, record_count)
            VALUES (NEW.namespace, NEW.category, 1)
            ON CONFLICT(namespace, value) DO UPDATE SET record_count = record_count + 1;
        END;
        """)
    }
}

struct MemoryUserVersionQuery: Sendable {
    func execute(in db: Database) throws -> Int {
        let row = try SQLRequest<Row>(sql: "PRAGMA user_version;").fetchOne(db)
        return row?[0] ?? 0
    }
}
