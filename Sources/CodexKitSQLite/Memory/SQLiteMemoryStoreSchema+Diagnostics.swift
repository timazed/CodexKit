import CodexKit
import GRDB

extension SQLiteMemoryStoreSchema {
    func validateDiagnosticsCardinality(in db: Database) throws {
        let limit = MemoryStoreLimits.maximumDiagnosticDimensionValueCount
        for (table, dimension) in [
            ("memory_diagnostic_scopes", "scope"),
            ("memory_diagnostic_categories", "category"),
        ] {
            if let row = try Row.fetchOne(
                db,
                sql: """
                SELECT namespace, COUNT(*) AS value_count
                FROM \(table)
                GROUP BY namespace
                HAVING COUNT(*) > ?
                LIMIT 1
                """,
                arguments: [limit]
            ) {
                let namespace: String = row["namespace"]
                throw MemoryStoreError.invalidRecord(
                    "namespace \(namespace) exceeds the \(dimension) diagnostics limit of \(limit)."
                )
            }
        }
    }

    func createDiagnosticsCardinalityTriggers(in db: Database) throws {
        let limit = MemoryStoreLimits.maximumDiagnosticDimensionValueCount
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS memory_diagnostics_scope_limit_insert
        BEFORE INSERT ON memory_records
        WHEN NOT EXISTS (
            SELECT 1 FROM memory_diagnostic_scopes
            WHERE namespace = NEW.namespace AND value = NEW.scope
        ) AND (
            SELECT COUNT(*) FROM memory_diagnostic_scopes
            WHERE namespace = NEW.namespace
        ) >= \(limit)
        BEGIN
            SELECT RAISE(ABORT, 'memory diagnostics scope limit exceeded');
        END;

        CREATE TRIGGER IF NOT EXISTS memory_diagnostics_category_limit_insert
        BEFORE INSERT ON memory_records
        WHEN NOT EXISTS (
            SELECT 1 FROM memory_diagnostic_categories
            WHERE namespace = NEW.namespace AND value = NEW.category
        ) AND (
            SELECT COUNT(*) FROM memory_diagnostic_categories
            WHERE namespace = NEW.namespace
        ) >= \(limit)
        BEGIN
            SELECT RAISE(ABORT, 'memory diagnostics category limit exceeded');
        END;

        CREATE TRIGGER IF NOT EXISTS memory_diagnostics_scope_limit_update
        BEFORE UPDATE OF namespace, scope ON memory_records
        WHEN (OLD.namespace != NEW.namespace OR OLD.scope != NEW.scope)
          AND NOT EXISTS (
            SELECT 1 FROM memory_diagnostic_scopes
            WHERE namespace = NEW.namespace AND value = NEW.scope
          ) AND (
            SELECT COUNT(*) FROM memory_diagnostic_scopes
            WHERE namespace = NEW.namespace
          ) >= \(limit)
        BEGIN
            SELECT RAISE(ABORT, 'memory diagnostics scope limit exceeded');
        END;

        CREATE TRIGGER IF NOT EXISTS memory_diagnostics_category_limit_update
        BEFORE UPDATE OF namespace, category ON memory_records
        WHEN (OLD.namespace != NEW.namespace OR OLD.category != NEW.category)
          AND NOT EXISTS (
            SELECT 1 FROM memory_diagnostic_categories
            WHERE namespace = NEW.namespace AND value = NEW.category
          ) AND (
            SELECT COUNT(*) FROM memory_diagnostic_categories
            WHERE namespace = NEW.namespace
          ) >= \(limit)
        BEGIN
            SELECT RAISE(ABORT, 'memory diagnostics category limit exceeded');
        END;
        """)
    }
}
