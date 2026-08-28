import Foundation
import CodexKit
import GRDB

extension SQLiteRuntimeStateStore {
    func shouldImportLegacyState() async throws -> Bool {
        let status = try await dbQueue.read { db -> (completed: Bool, threadCount: Int) in
            let completed = try RuntimeStoreMetadataRow.fetchOne(db, key: "runtime")?
                .legacyImportCompleted ?? false
            let threadCount = try RuntimeThreadCountQuery().execute(in: db)
            return (completed, threadCount)
        }
        guard !status.completed, status.threadCount == 0 else {
            return false
        }
        guard let legacyStateURL else {
            return false
        }
        guard legacyStateURL != url else {
            return false
        }
        guard FileManager.default.fileExists(atPath: legacyStateURL.path) else {
            return false
        }
        return true
    }

    func importLegacyState() async throws {
        guard let legacyStateURL else {
            return
        }

        let legacyStore = FileRuntimeStateStore(
            url: legacyStateURL,
            logging: logger.configuration
        )
        let state = try await legacyStore.loadState().normalized()

        if !state.threads.isEmpty || !state.historyByThread.isEmpty {
            try await saveStateWithoutCoordination(state)
        }
        try await dbQueue.write { db in
            try RuntimeStoreMetadataRow(
                id: "runtime",
                legacyImportCompleted: true
            ).save(db)
        }
    }

    func readUserVersion() async throws -> Int {
        try await dbQueue.read { db in
            try RuntimeUserVersionQuery().execute(in: db)
        }
    }
}

struct SQLiteRuntimeStorePersistence: Sendable {
    let attachmentStore: RuntimeAttachmentStore
    let preparedAttachments: RuntimePreparedAttachments?

    init(
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments? = nil
    ) {
        self.attachmentStore = attachmentStore
        self.preparedAttachments = preparedAttachments
    }

    func apply(
        _ operations: [AgentStoreWriteOperation],
        in db: Database
    ) throws {
        var attachmentCleanup = Set<String>()
        let explicitlyUpdatedSummaryThreadIDs = Set(operations.compactMap { operation -> String? in
            guard case let .upsertSummary(threadID, _) = operation else { return nil }
            return threadID
        })

        // A newly created thread must exist before its summary and history rows
        // can satisfy their foreign keys, regardless of coalescing order.
        for operation in operations {
            guard case let .upsertThread(thread) = operation else { continue }
            try upsertThreadMetadata(thread, in: db)
            if let summaryRow = try RuntimeSummaryRow.fetchOne(db, key: thread.id) {
                let summary = try decodeSummary(from: summaryRow)
                try makeSummaryRow(from: AgentThreadSummary(
                    threadID: summary.threadID,
                    createdAt: thread.createdAt,
                    updatedAt: thread.updatedAt,
                    latestItemAt: summary.latestItemAt,
                    itemCount: summary.itemCount,
                    latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                    latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                    latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                    latestToolState: summary.latestToolState,
                    latestTurnStatus: summary.latestTurnStatus,
                    pendingState: summary.pendingState
                )).save(db)
            } else {
                let summary = StoredRuntimeState(threads: [thread])
                    .threadSummaryFallback(for: thread)
                try makeSummaryRow(from: summary).save(db)
            }
        }

        for operation in operations {
            switch operation {
            case .upsertThread:
                continue

            case let .upsertSummary(_, summary):
                try makeSummaryRow(from: summary).save(db)

            case let .appendHistoryItems(threadID, items):
                try appendHistoryItems(items, to: threadID, in: db)
                if !explicitlyUpdatedSummaryThreadIDs.contains(threadID) {
                    try updateSummaryAfterAppending(items, threadID: threadID, in: db)
                }

            case let .restoreHistoryItems(threadID, items):
                try appendHistoryItems(
                    items,
                    to: threadID,
                    allowInitialSequenceGap: true,
                    in: db
                )
                if !explicitlyUpdatedSummaryThreadIDs.contains(threadID) {
                    try updateSummaryAfterAppending(items, threadID: threadID, in: db)
                }

            case let .appendCompactionMarker(threadID, marker):
                try appendHistoryItems([marker], to: threadID, in: db)
                if !explicitlyUpdatedSummaryThreadIDs.contains(threadID) {
                    try updateSummaryAfterAppending([marker], threadID: threadID, in: db)
                }

            case let .upsertThreadContextState(threadID, state):
                let previousStorageKeys = try attachmentReferenceStorageKeys(
                    ownerType: "context",
                    ownerKey: threadID,
                    in: db
                )
                if let state {
                    let row = try makeContextStateRow(from: state)
                    let newStorageKeys = try attachmentStorageKeys(from: row)
                    try row.save(db)
                    try replaceAttachmentReferences(
                        ownerType: "context",
                        ownerKey: threadID,
                        threadID: threadID,
                        storageKeys: newStorageKeys,
                        in: db
                    )
                    attachmentCleanup.formUnion(previousStorageKeys.subtracting(newStorageKeys))
                } else {
                    _ = try RuntimeContextStateRow.deleteOne(db, key: threadID)
                    try deleteAttachmentReferences(
                        ownerType: "context",
                        ownerKey: threadID,
                        in: db
                    )
                    attachmentCleanup.formUnion(previousStorageKeys)
                }

            case let .deleteThreadContextState(threadID):
                attachmentCleanup.formUnion(try attachmentReferenceStorageKeys(
                    ownerType: "context",
                    ownerKey: threadID,
                    in: db
                ))
                _ = try RuntimeContextStateRow.deleteOne(db, key: threadID)
                try deleteAttachmentReferences(
                    ownerType: "context",
                    ownerKey: threadID,
                    in: db
                )

            case let .setPendingState(threadID, pendingState):
                try updateSummary(threadID: threadID, in: db) { summary in
                    AgentThreadSummary(
                        threadID: summary.threadID,
                        createdAt: summary.createdAt,
                        updatedAt: summary.updatedAt,
                        latestItemAt: summary.latestItemAt,
                        itemCount: summary.itemCount,
                        latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                        latestToolState: summary.latestToolState,
                        latestTurnStatus: summary.latestTurnStatus,
                        pendingState: pendingState
                    )
                }

            case let .setPartialStructuredSnapshot(threadID, snapshot):
                try updateSummary(threadID: threadID, in: db) { summary in
                    AgentThreadSummary(
                        threadID: summary.threadID,
                        createdAt: summary.createdAt,
                        updatedAt: summary.updatedAt,
                        latestItemAt: summary.latestItemAt,
                        itemCount: summary.itemCount,
                        latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: snapshot,
                        latestToolState: summary.latestToolState,
                        latestTurnStatus: summary.latestTurnStatus,
                        pendingState: summary.pendingState
                    )
                }

            case let .upsertToolSession(threadID, session):
                try updateSummary(threadID: threadID, in: db) { summary in
                    let latestToolState = AgentLatestToolState(
                        invocationID: session.invocationID,
                        turnID: session.turnID,
                        toolName: session.toolName,
                        status: .running,
                        success: nil,
                        sessionID: session.sessionID,
                        sessionStatus: session.sessionStatus,
                        metadata: session.metadata,
                        resumable: session.resumable,
                        updatedAt: session.updatedAt,
                        resultPreview: nil
                    )
                    return AgentThreadSummary(
                        threadID: summary.threadID,
                        createdAt: summary.createdAt,
                        updatedAt: summary.updatedAt,
                        latestItemAt: summary.latestItemAt,
                        itemCount: summary.itemCount,
                        latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                        latestToolState: latestToolState,
                        latestTurnStatus: summary.latestTurnStatus,
                        pendingState: .toolWait(
                            AgentPendingToolWaitState(
                                invocationID: session.invocationID,
                                turnID: session.turnID,
                                toolName: session.toolName,
                                startedAt: session.updatedAt,
                                sessionID: session.sessionID,
                                sessionStatus: session.sessionStatus,
                                metadata: session.metadata,
                                resumable: session.resumable
                            )
                        )
                    )
                }

            case let .redactHistoryItems(threadID, itemIDs, reason):
                let storageKeys = try redactHistoryItems(
                    itemIDs,
                    in: threadID,
                    reason: reason,
                    database: db
                )
                attachmentCleanup.formUnion(storageKeys)

            case let .deleteThread(threadID):
                try enqueueAttachmentReferencesForCleanup(threadID: threadID, in: db)
                _ = try RuntimeThreadRow.deleteOne(db, key: threadID)
            }
        }
        try enqueueAttachmentCleanup(attachmentCleanup, in: db)
    }

    func appendHistoryItems(
        _ items: [AgentHistoryRecord],
        to threadID: String,
        allowInitialSequenceGap: Bool = false,
        in db: Database
    ) throws {
        guard !items.isEmpty else { return }
        guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        let expectedSequence = threadRow.nextHistorySequence
        try AgentHistoryWriteValidator.validate(
            items,
            threadID: threadID,
            existingLastSequence: expectedSequence == 1 ? nil : expectedSequence - 1,
            threadExists: true,
            allowInitialSequenceGap: allowInitialSequenceGap
        )

        for item in items {
            let historyRow = try makeHistoryRow(from: item)
            try historyRow.insert(db)
            try replaceAttachmentReferences(
                ownerType: "history",
                ownerKey: historyRow.storageID,
                threadID: threadID,
                storageKeys: try attachmentStorageKeys(from: historyRow),
                in: db
            )
            for structuredOutputRow in try structuredOutputRows(from: [threadID: [item]]) {
                try structuredOutputRow.save(db)
            }
        }
        let nextSequence = try AgentHistorySequence.next(
            after: items.last?.sequenceNumber,
            threadID: threadID
        )
        try db.execute(
            sql: "UPDATE \(RuntimeThreadRow.databaseTableName) SET nextHistorySequence = ? WHERE threadID = ?",
            arguments: [nextSequence, threadID]
        )
    }

    private func upsertThreadMetadata(_ thread: AgentThread, in db: Database) throws {
        let row = try makeThreadRow(from: thread)
        try db.execute(
            sql: """
            INSERT INTO \(RuntimeThreadRow.databaseTableName)
                (threadID, createdAt, updatedAt, status, nextHistorySequence, encodedThread)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(threadID) DO UPDATE SET
                createdAt = excluded.createdAt,
                updatedAt = excluded.updatedAt,
                status = excluded.status,
                encodedThread = excluded.encodedThread
            """,
            arguments: [
                row.threadID,
                row.createdAt,
                row.updatedAt,
                row.status,
                row.nextHistorySequence,
                row.encodedThread,
            ]
        )
    }

    func updateSummary(
        threadID: String,
        in db: Database,
        transform: (AgentThreadSummary) throws -> AgentThreadSummary
    ) throws {
        guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        let thread = try decodeThread(from: threadRow)
        let current: AgentThreadSummary
        if let summaryRow = try RuntimeSummaryRow.fetchOne(db, key: threadID) {
            current = try decodeSummary(from: summaryRow)
        } else {
            current = StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
        }
        try makeSummaryRow(from: try transform(current)).save(db)
    }

    func updateSummaryAfterAppending(
        _ items: [AgentHistoryRecord],
        threadID: String,
        in db: Database
    ) throws {
        guard !items.isEmpty else { return }
        guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: threadID) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        let thread = try decodeThread(from: threadRow)
        try updateSummary(threadID: threadID, in: db) { current in
            let projected = StoredRuntimeStateProjectionBuilder().rebuildSummary(
                for: thread,
                history: items,
                existing: current
            )
            return AgentThreadSummary(
                threadID: projected.threadID,
                createdAt: projected.createdAt,
                updatedAt: projected.updatedAt,
                latestItemAt: items.last?.createdAt ?? current.latestItemAt,
                itemCount: try AgentCounter.adding(
                    items.count,
                    to: current.itemCount ?? 0,
                    field: "history item count",
                    threadID: threadID
                ),
                latestAssistantMessagePreview: projected.latestAssistantMessagePreview,
                latestStructuredOutputMetadata: projected.latestStructuredOutputMetadata,
                latestPartialStructuredOutput: projected.latestPartialStructuredOutput,
                latestToolState: projected.latestToolState,
                latestTurnStatus: projected.latestTurnStatus,
                pendingState: projected.pendingState
            )
        }
    }

    func redactHistoryItems(
        _ itemIDs: [String],
        in threadID: String,
        reason: AgentRedactionReason?,
        database db: Database
    ) throws -> Set<String> {
        guard !itemIDs.isEmpty else { return [] }
        let request = RuntimeHistoryRow
            .filter(Column("threadID") == threadID)
            .filter(itemIDs.contains(Column("recordID")))
        let matchCount = try request.fetchCount(db)
        guard matchCount <= AgentStoreLimits.maximumRedactionMatchCount else {
            throw AgentStoreError.invalidInput(
                "a redaction matches more than \(AgentStoreLimits.maximumRedactionMatchCount) history records"
            )
        }
        let rows = try boundedRuntimeRows(
            request.fetchCursor(db),
            payload: \.encodedRecord,
            name: "redaction"
        )
        let storageIDs = rows.map(\.storageID)
        let referenceLimit = AgentStoreLimits.maximumRedactionMatchCount
            * AgentStoreLimits.maximumImageCountPerMessage + 1
        let attachmentRows = try RuntimeAttachmentReferenceRow
            .filter(Column("ownerType") == "history")
            .filter(storageIDs.contains(Column("ownerKey")))
            .select(Column("storageKey"), as: String.self)
            .limit(referenceLimit)
            .fetchAll(db)
        guard attachmentRows.count < referenceLimit else {
            throw AgentStoreError.invalidInput(
                "stored redaction attachments exceed their bounded limit"
            )
        }
        var attachmentStorageKeys = Set(attachmentRows)
        for row in rows {
            let original = try decodeHistoryRecordForProjection(from: row)
            let redacted = original.redacted(reason: reason)
            let redactedRow = try makeHistoryRow(from: redacted)
            try redactedRow.save(db)
            try replaceAttachmentReferences(
                ownerType: "history",
                ownerKey: redactedRow.storageID,
                threadID: threadID,
                storageKeys: try self.attachmentStorageKeys(from: redactedRow),
                in: db
            )
            for outputID in structuredOutputIDs(from: original) {
                _ = try RuntimeStructuredOutputRow.deleteOne(db, key: outputID)
            }
        }
        attachmentStorageKeys.formUnion(try attachmentReferenceStorageKeys(
            ownerType: "context",
            ownerKey: threadID,
            in: db
        ))
        _ = try RuntimeContextStateRow.deleteOne(db, key: threadID)
        try deleteAttachmentReferences(ownerType: "context", ownerKey: threadID, in: db)
        try rebuildSummary(threadID: threadID, in: db)
        return attachmentStorageKeys
    }

    func rebuildSummary(threadID: String, in db: Database) throws {
        guard let threadRow = try RuntimeThreadRow.fetchOne(db, key: threadID) else {
            return
        }
        let thread = try decodeThread(from: threadRow)
        let existing = try RuntimeSummaryRow.fetchOne(db, key: threadID).map(decodeSummary)
        let table = RuntimeHistoryRow.databaseTableName
        let aggregate = try SQLRequest<Row>(
            sql: """
            SELECT COUNT(*) AS itemCount, MAX(createdAt) AS latestItemAt
            FROM \(table)
            WHERE threadID = ?
            """,
            arguments: [threadID]
        ).fetchOne(db)

        func latestRow(
            where predicate: String,
            arguments: [any DatabaseValueConvertible]
        ) throws -> RuntimeHistoryRow? {
            let allArguments: [any DatabaseValueConvertible] = [threadID] + arguments
            return try SQLRequest<RuntimeHistoryRow>(
                sql: """
                SELECT * FROM \(table)
                WHERE threadID = ? AND \(predicate)
                ORDER BY sequenceNumber DESC
                LIMIT 1
                """,
                arguments: StatementArguments(allArguments)
            ).fetchOne(db)
        }

        var latestRows: [String: RuntimeHistoryRow] = [:]
        let candidates = try [
            latestRow(
                where: "kind = ? AND messageRole = ?",
                arguments: [AgentHistoryItemKind.message.rawValue, AgentRole.assistant.rawValue]
            ),
            latestRow(where: "hasStructuredOutput = 1", arguments: []),
            latestRow(
                where: "kind IN (?, ?)",
                arguments: [
                    AgentHistoryItemKind.toolCall.rawValue,
                    AgentHistoryItemKind.toolResult.rawValue,
                ]
            ),
            latestRow(
                where: "kind = ? AND systemEventType IN (?, ?, ?)",
                arguments: [
                    AgentHistoryItemKind.systemEvent.rawValue,
                    AgentSystemEventType.turnStarted.rawValue,
                    AgentSystemEventType.turnCompleted.rawValue,
                    AgentSystemEventType.turnFailed.rawValue,
                ]
            ),
        ]
        for row in candidates.compactMap({ $0 }) {
            latestRows[row.storageID] = row
        }
        let history = try latestRows.values
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map(decodeHistoryRecordForProjection)
        let baseline = AgentThreadSummary(
            threadID: thread.id,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            latestItemAt: nil,
            itemCount: nil,
            latestAssistantMessagePreview: nil,
            latestStructuredOutputMetadata: nil,
            latestPartialStructuredOutput: existing?.latestPartialStructuredOutput,
            latestToolState: nil,
            latestTurnStatus: nil,
            pendingState: existing?.pendingState
        )
        let projected = StoredRuntimeStateProjectionBuilder().rebuildSummary(
            for: thread,
            history: history,
            existing: baseline
        )
        let latestTimestamp: Double? = aggregate?["latestItemAt"]
        let summary = AgentThreadSummary(
            threadID: projected.threadID,
            createdAt: projected.createdAt,
            updatedAt: projected.updatedAt,
            latestItemAt: latestTimestamp.map(Date.init(timeIntervalSince1970:)),
            itemCount: aggregate?["itemCount"] ?? 0,
            latestAssistantMessagePreview: projected.latestAssistantMessagePreview,
            latestStructuredOutputMetadata: projected.latestStructuredOutputMetadata,
            latestPartialStructuredOutput: projected.latestPartialStructuredOutput,
            latestToolState: projected.latestToolState,
            latestTurnStatus: projected.latestTurnStatus,
            pendingState: projected.pendingState
        )
        try makeSummaryRow(from: summary).save(db)
    }
}
