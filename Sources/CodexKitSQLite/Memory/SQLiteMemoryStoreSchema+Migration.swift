import CodexKit
import Foundation
import GRDB

extension SQLiteMemoryStoreSchema {
    func rebuildRecordOrders(in db: Database) throws {
        var cursorNamespace: String?
        var cursorID: String?
        while true {
            let rows = try nextRecordBatch(
                afterNamespace: cursorNamespace,
                id: cursorID,
                in: db
            )
            guard !rows.isEmpty else { break }
            for row in rows {
                try db.execute(
                    sql: "UPDATE memory_records SET record_order = ? WHERE namespace = ? AND id = ?",
                    arguments: [
                        MemoryQueryEngine.recordOrder(for: row.id),
                        row.namespace,
                        row.id,
                    ]
                )
            }
            cursorNamespace = rows.last?.namespace
            cursorID = rows.last?.id
        }
    }

    func migrateLegacyRecords(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE memory_records_v5 (
            namespace TEXT NOT NULL,
            id TEXT NOT NULL,
            record_order INTEGER NOT NULL DEFAULT 0,
            scope TEXT NOT NULL,
            category TEXT NOT NULL,
            summary TEXT NOT NULL,
            importance DOUBLE NOT NULL,
            created_at DOUBLE NOT NULL,
            observed_at DOUBLE,
            effective_at DOUBLE NOT NULL,
            expires_at DOUBLE,
            dedupe_key TEXT,
            is_pinned BOOLEAN NOT NULL,
            attributes_json TEXT,
            status TEXT NOT NULL,
            rendered_character_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (namespace, id)
        );
        CREATE TABLE memory_evidence_v5 (
            namespace TEXT NOT NULL,
            record_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (namespace, record_id, ordinal),
            FOREIGN KEY (namespace, record_id)
                REFERENCES memory_records_v5(namespace, id) ON DELETE CASCADE
        );
        CREATE TABLE memory_tags_v5 (
            namespace TEXT NOT NULL,
            record_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (namespace, record_id, ordinal),
            FOREIGN KEY (namespace, record_id)
                REFERENCES memory_records_v5(namespace, id) ON DELETE CASCADE
        );
        CREATE TABLE memory_related_ids_v5 (
            namespace TEXT NOT NULL,
            record_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (namespace, record_id, ordinal),
            FOREIGN KEY (namespace, record_id)
                REFERENCES memory_records_v5(namespace, id) ON DELETE CASCADE
        );

        INSERT INTO memory_records_v5 (
            namespace, id, record_order, scope, category, summary, importance,
            created_at, observed_at, effective_at, expires_at,
            dedupe_key, is_pinned, attributes_json, status,
            rendered_character_count
        )
        SELECT
            namespace, id, 0, scope, kind, summary,
            MIN(1.0, MAX(0.0, importance)),
            created_at, observed_at, COALESCE(observed_at, created_at), expires_at,
            dedupe_key, is_pinned, attributes_json, status,
            COALESCE(rendered_character_count, 0)
        FROM memory_records;

        INSERT INTO memory_evidence_v5 (namespace, record_id, ordinal, value)
        SELECT r.namespace, r.id, CAST(j.key AS INTEGER), CAST(j.value AS TEXT)
        FROM memory_records r,
             json_each(CASE WHEN json_valid(r.evidence_json) THEN r.evidence_json ELSE '[]' END) j
        WHERE j.type = 'text';

        INSERT INTO memory_tags_v5 (namespace, record_id, ordinal, value)
        SELECT namespace, record_id,
               ROW_NUMBER() OVER (PARTITION BY namespace, record_id ORDER BY rowid) - 1,
               tag
        FROM memory_tags;

        INSERT INTO memory_related_ids_v5 (namespace, record_id, ordinal, value)
        SELECT namespace, record_id,
               ROW_NUMBER() OVER (PARTITION BY namespace, record_id ORDER BY rowid) - 1,
               related_id
        FROM memory_related_ids;

        DROP TABLE memory_tags;
        DROP TABLE memory_related_ids;
        DROP TABLE memory_fts;
        DROP TABLE memory_records;
        ALTER TABLE memory_records_v5 RENAME TO memory_records;
        """)

        try createChildTable(SQLiteMemoryEvidence.databaseTableName, in: db)
        try createChildTable(SQLiteMemoryTag.databaseTableName, in: db)
        try createChildTable(SQLiteMemoryRelatedID.databaseTableName, in: db)
        try createSearchTokenTable(in: db)
        try db.execute(sql: """
        INSERT INTO memory_evidence SELECT * FROM memory_evidence_v5;
        INSERT INTO memory_tags SELECT * FROM memory_tags_v5;
        INSERT INTO memory_related_ids SELECT * FROM memory_related_ids_v5;
        DROP TABLE memory_evidence_v5;
        DROP TABLE memory_tags_v5;
        DROP TABLE memory_related_ids_v5;
        """)

        try createStructuredIndexes(in: db)
        try rebuildRecordProjections(in: db, rebuildRenderedCounts: true)
    }

    func rebuildSearchTokens(in db: Database) throws {
        try createSearchTokenTable(in: db)
        try rebuildRecordProjections(in: db, rebuildRenderedCounts: false)
    }

    private func rebuildRecordProjections(
        in db: Database,
        rebuildRenderedCounts: Bool
    ) throws {
        try SQLiteMemorySearchToken.deleteAll(db)
        let codec = SQLiteMemoryStoreCodec()
        let repository = SQLiteMemoryStoreRepository(codec: codec)
        var cursorNamespace: String?
        var cursorID: String?

        while true {
            let rows = try nextRecordBatch(
                afterNamespace: cursorNamespace,
                id: cursorID,
                in: db
            )
            guard !rows.isEmpty else { break }
            let groupedRows = Dictionary(grouping: rows, by: \.namespace)
            let records = try groupedRows.flatMap { namespace, namespaceRows in
                try repository.makeRecords(
                    from: namespaceRows,
                    namespace: namespace,
                    in: db,
                    includeAttributes: false,
                    validateProjections: false
                )
            }
            for record in records {
                if rebuildRenderedCounts {
                    try db.execute(
                        sql: "UPDATE memory_records SET rendered_character_count = ? WHERE namespace = ? AND id = ?",
                        arguments: [
                            MemoryQueryEngine.renderedCharacterCount(for: record),
                            record.namespace,
                            record.id,
                        ]
                    )
                }
                let searchableText = ([record.summary, record.category] + record.evidence + record.tags)
                    .joined(separator: " ")
                for value in codec.searchTokens(from: searchableText) {
                    try SQLiteMemorySearchToken(
                        namespace: record.namespace,
                        recordID: record.id,
                        value: value
                    ).insert(db)
                }
            }
            cursorNamespace = rows.last?.namespace
            cursorID = rows.last?.id
        }
    }

    private func nextRecordBatch(
        afterNamespace namespace: String?,
        id: String?,
        in db: Database
    ) throws -> [SQLiteMemoryRecord] {
        if let namespace, let id {
            return try SQLRequest<SQLiteMemoryRecord>(
                sql: """
                SELECT * FROM memory_records
                WHERE namespace > ? OR (namespace = ? AND id > ?)
                ORDER BY namespace, id
                LIMIT 256
                """,
                arguments: [namespace, namespace, id]
            ).fetchAll(db)
        }
        return try SQLRequest<SQLiteMemoryRecord>(
            sql: "SELECT * FROM memory_records ORDER BY namespace, id LIMIT 256"
        ).fetchAll(db)
    }
}
