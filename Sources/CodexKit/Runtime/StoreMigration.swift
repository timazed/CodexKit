import Foundation

public enum CodexKitStoreMigrationError: Error, LocalizedError, Equatable, Sendable {
    case destinationNotEmpty
    case invalidBatchSize
    case tooManyNamespaces
    case countOverflow
    case sameSourceAndDestination
    case overwriteDestinationUnsupported
    case rollbackFailed
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .destinationNotEmpty:
            "The destination store is not empty."
        case .invalidBatchSize:
            "The migration batch size must be between 1 and \(AgentStoreLimits.maximumQueryResultCount)."
        case .tooManyNamespaces:
            "A memory migration must not exceed \(MemoryStoreLimits.maximumBulkIdentifierCount) namespaces."
        case .countOverflow:
            "The migration report count exceeded the supported integer range."
        case .sameSourceAndDestination:
            "The source and destination resolve to the same store."
        case .overwriteDestinationUnsupported:
            "A non-empty destination cannot be overwritten safely; migrate into an empty store."
        case .rollbackFailed:
            "The migration failed and its rollback could not be completed."
        case .verificationFailed:
            "The destination store did not match the source after migration."
        }
    }
}

public struct RuntimeStoreMigrationReport: Sendable, Hashable {
    public let threadCount: Int
    public let historyRecordCount: Int
    public let contextStateCount: Int

    public init(
        threadCount: Int,
        historyRecordCount: Int,
        contextStateCount: Int
    ) {
        self.threadCount = threadCount
        self.historyRecordCount = historyRecordCount
        self.contextStateCount = contextStateCount
    }
}

public enum RuntimeStoreMigrator {
    public static func migrate(
        from source: any AgentRuntimeQueryableStore & RuntimeStateInspecting,
        to destination: any AgentRuntimeQueryableStore & RuntimeStateInspecting,
        overwriteDestination: Bool = false,
        batchSize: Int = 256
    ) async throws -> RuntimeStoreMigrationReport {
        guard (1 ... AgentStoreLimits.maximumQueryResultCount).contains(batchSize) else {
            throw CodexKitStoreMigrationError.invalidBatchSize
        }
        try ensureDifferentStores(source, destination)
        _ = try await source.prepare()
        _ = try await destination.prepare()

        let coordinationRoots = [source, destination].compactMap {
            ($0 as? any StoreMigrationCoordinating)?.migrationCoordinationRootURL
        }
        return try await RuntimeStoreMutationCoordinator.shared.performExclusively(
            for: coordinationRoots
        ) {
            try await migrateWhileExclusivelyHeld(
                from: source,
                to: destination,
                overwriteDestination: overwriteDestination,
                batchSize: batchSize
            )
        }
    }

    private static func migrateWhileExclusivelyHeld(
        from source: any AgentRuntimeQueryableStore & RuntimeStateInspecting,
        to destination: any AgentRuntimeQueryableStore & RuntimeStateInspecting,
        overwriteDestination: Bool,
        batchSize: Int
    ) async throws -> RuntimeStoreMigrationReport {
        let destinationThreads = try await destination.execute(ThreadMetadataQuery(limit: 1))
        if !destinationThreads.isEmpty {
            throw overwriteDestination
                ? CodexKitStoreMigrationError.overwriteDestinationUnsupported
                : CodexKitStoreMigrationError.destinationNotEmpty
        }

        var threadCursor: AgentThreadMetadataCursor?
        var threadCount = 0
        var historyRecordCount = 0
        var contextStateCount = 0
        do {
            while true {
                let threads = try await threadPage(
                    from: source,
                    cursor: threadCursor,
                    batchSize: batchSize
                )
                guard !threads.isEmpty else { break }
                for thread in threads {
                    try await destination.apply([.upsertThread(thread)])
                    historyRecordCount = try migrationCount(
                        adding: try await copyHistory(
                        threadID: thread.id,
                        from: source,
                        to: destination,
                        batchSize: batchSize
                        ),
                        to: historyRecordCount
                    )
                    let contextState = try await source.fetchThreadContextState(id: thread.id)
                    if contextState != nil {
                        contextStateCount = try migrationCount(adding: 1, to: contextStateCount)
                    }
                    let summary = try await source.fetchThreadSummary(id: thread.id)
                    try await destination.apply([
                        .upsertThreadContextState(threadID: thread.id, state: contextState),
                        .upsertSummary(threadID: thread.id, summary: summary),
                    ])
                    threadCount = try migrationCount(adding: 1, to: threadCount)
                }
                guard let lastThread = threads.last else { break }
                threadCursor = metadataCursor(
                    after: lastThread,
                    sort: .createdAt(.ascending)
                )
                if threads.count < batchSize { break }
            }
            try await verifyRuntimeMigration(
                source: source,
                destination: destination,
                batchSize: batchSize
            )
        } catch {
            do {
                try await deleteAllRuntimeThreads(from: destination, batchSize: batchSize)
            } catch {
                throw CodexKitStoreMigrationError.rollbackFailed
            }
            throw error
        }

        return RuntimeStoreMigrationReport(
            threadCount: threadCount,
            historyRecordCount: historyRecordCount,
            contextStateCount: contextStateCount
        )
    }

    private static func copyHistory(
        threadID: String,
        from source: any AgentRuntimeQueryableStore,
        to destination: any RuntimeStateStoring,
        batchSize: Int
    ) async throws -> Int {
        var cursor: AgentHistoryCursor?
        var count = 0
        repeat {
            let page = try await historyPage(
                threadID: threadID,
                cursor: cursor,
                batchSize: batchSize,
                from: source
            )
            if !page.records.isEmpty {
                try await destination.apply([
                    .restoreHistoryItems(threadID: threadID, items: page.records),
                ])
                count = try migrationCount(adding: page.records.count, to: count)
            }
            cursor = page.nextCursor
        } while cursor != nil
        return count
    }

    private static func verifyRuntimeMigration(
        source: any AgentRuntimeQueryableStore & RuntimeStateInspecting,
        destination: any AgentRuntimeQueryableStore & RuntimeStateInspecting,
        batchSize: Int
    ) async throws {
        var sourceCursor: AgentThreadMetadataCursor?
        var destinationCursor: AgentThreadMetadataCursor?
        while true {
            let sourceThreads = try await threadPage(
                from: source,
                cursor: sourceCursor,
                batchSize: batchSize
            )
            let destinationThreads = try await threadPage(
                from: destination,
                cursor: destinationCursor,
                batchSize: batchSize
            )
            guard sourceThreads == destinationThreads else {
                throw CodexKitStoreMigrationError.verificationFailed
            }
            guard !sourceThreads.isEmpty else { break }
            for thread in sourceThreads {
                let sourceSummary = try await source.fetchThreadSummary(id: thread.id)
                let destinationSummary = try await destination.fetchThreadSummary(id: thread.id)
                let sourceContext = try await source.fetchThreadContextState(id: thread.id)
                let destinationContext = try await destination.fetchThreadContextState(id: thread.id)
                guard sourceSummary == destinationSummary,
                      sourceContext == destinationContext else {
                    throw CodexKitStoreMigrationError.verificationFailed
                }
                try await verifyHistory(
                    threadID: thread.id,
                    source: source,
                    destination: destination,
                    batchSize: batchSize
                )
            }
            guard let lastSourceThread = sourceThreads.last,
                  let lastDestinationThread = destinationThreads.last else { break }
            sourceCursor = metadataCursor(
                after: lastSourceThread,
                sort: .createdAt(.ascending)
            )
            destinationCursor = metadataCursor(
                after: lastDestinationThread,
                sort: .createdAt(.ascending)
            )
            if sourceThreads.count < batchSize { break }
        }
    }

    private static func verifyHistory(
        threadID: String,
        source: any AgentRuntimeQueryableStore,
        destination: any AgentRuntimeQueryableStore,
        batchSize: Int
    ) async throws {
        var sourceCursor: AgentHistoryCursor?
        var destinationCursor: AgentHistoryCursor?
        repeat {
            let sourcePage = try await historyPage(
                threadID: threadID,
                cursor: sourceCursor,
                batchSize: batchSize,
                from: source
            )
            let destinationPage = try await historyPage(
                threadID: threadID,
                cursor: destinationCursor,
                batchSize: batchSize,
                from: destination
            )
            guard sourcePage.records == destinationPage.records,
                  (sourcePage.nextCursor == nil) == (destinationPage.nextCursor == nil) else {
                throw CodexKitStoreMigrationError.verificationFailed
            }
            sourceCursor = sourcePage.nextCursor
            destinationCursor = destinationPage.nextCursor
        } while sourceCursor != nil
    }

    private static func threadPage(
        from store: any AgentRuntimeQueryableStore,
        cursor: AgentThreadMetadataCursor?,
        batchSize: Int
    ) async throws -> [AgentThread] {
        try await store.execute(ThreadMetadataQuery(
            sort: .createdAt(.ascending),
            limit: batchSize,
            cursor: cursor
        ))
    }

    private static func metadataCursor(
        after thread: AgentThread,
        sort: AgentThreadMetadataSort
    ) -> AgentThreadMetadataCursor {
        switch sort {
        case .createdAt:
            AgentThreadMetadataCursor(date: thread.createdAt, threadID: thread.id)
        case .updatedAt:
            AgentThreadMetadataCursor(date: thread.updatedAt, threadID: thread.id)
        }
    }

    private static func historyPage(
        threadID: String,
        cursor: AgentHistoryCursor?,
        batchSize: Int,
        from store: any AgentRuntimeQueryableStore
    ) async throws -> AgentHistoryQueryResult {
        try await store.execute(HistoryItemsQuery(
            threadID: threadID,
            includeRedacted: true,
            includeCompactionEvents: true,
            sort: .sequence(.ascending),
            page: AgentQueryPage(
                limit: batchSize,
                cursor: cursor,
                direction: .forward
            )
        ))
    }

    private static func deleteAllRuntimeThreads(
        from destination: any AgentRuntimeQueryableStore,
        batchSize: Int
    ) async throws {
        while true {
            let threads = try await destination.execute(ThreadMetadataQuery(
                sort: .createdAt(.ascending),
                limit: batchSize
            ))
            guard !threads.isEmpty else { return }
            try await destination.apply(threads.map {
                AgentStoreWriteOperation.deleteThread(threadID: $0.id)
            })
        }
    }
}

public struct MemoryStoreMigrationReport: Sendable, Hashable {
    public let namespaceCount: Int
    public let recordCount: Int

    public init(namespaceCount: Int, recordCount: Int) {
        self.namespaceCount = namespaceCount
        self.recordCount = recordCount
    }
}

public enum MemoryStoreMigrator {
    public static func migrate(
        namespaces: [String],
        from source: any MemoryStoring,
        to destination: any MemoryStoring,
        batchSize: Int = 256
    ) async throws -> MemoryStoreMigrationReport {
        guard (1 ... MemoryStoreLimits.maximumListResultCount).contains(batchSize) else {
            throw CodexKitStoreMigrationError.invalidBatchSize
        }
        guard namespaces.count <= MemoryStoreLimits.maximumBulkIdentifierCount else {
            throw CodexKitStoreMigrationError.tooManyNamespaces
        }
        try ensureDifferentStores(source, destination)
        try await source.prepare()
        try await destination.prepare()

        let coordinationRoots = [source, destination].compactMap {
            ($0 as? any StoreMigrationCoordinating)?.migrationCoordinationRootURL
        }
        return try await RuntimeStoreMutationCoordinator.shared.performExclusively(
            for: coordinationRoots
        ) {
            try await migrateWhileExclusivelyHeld(
                namespaces: namespaces,
                source: source,
                destination: destination,
                batchSize: batchSize
            )
        }
    }

    private static func migrateWhileExclusivelyHeld(
        namespaces: [String],
        source: any MemoryStoring,
        destination: any MemoryStoring,
        batchSize: Int
    ) async throws -> MemoryStoreMigrationReport {
        let uniqueNamespaces = Array(Set(namespaces)).sorted()
        for namespace in uniqueNamespaces {
            let destinationRecords = try await destination.list(
                namespace: namespace,
                includeArchived: true,
                limit: 1
            )
            guard destinationRecords.isEmpty else {
                throw CodexKitStoreMigrationError.destinationNotEmpty
            }
        }

        var recordCount = 0
        for namespace in uniqueNamespaces {
            recordCount = try migrationCount(
                adding: try await validateMemoryRecords(
                    namespace: namespace,
                    source: source,
                    batchSize: batchSize
                ),
                to: recordCount
            )
        }

        var copiedRecordCount = 0
        do {
            for namespace in uniqueNamespaces {
                var cursor: MemoryRecordListCursor?
                while true {
                    let records = try await memoryPage(
                        namespace: namespace,
                        cursor: cursor,
                        limit: batchSize,
                        from: source
                    )
                    guard !records.isEmpty else { break }
                    try await destination.putMany(records)
                    copiedRecordCount = try migrationCount(
                        adding: records.count,
                        to: copiedRecordCount
                    )
                    cursor = records.last.map {
                        MemoryRecordListCursor(effectiveDate: $0.effectiveDate, recordID: $0.id)
                    }
                    if records.count < batchSize { break }
                }
            }
            guard copiedRecordCount == recordCount else {
                throw CodexKitStoreMigrationError.verificationFailed
            }
            try await verifyMemoryMigration(
                namespaces: uniqueNamespaces,
                source: source,
                destination: destination,
                batchSize: batchSize
            )
        } catch {
            do {
                try await rollbackMemoryRecords(
                    namespaces: uniqueNamespaces,
                    in: destination,
                    batchSize: batchSize
                )
            } catch {
                throw CodexKitStoreMigrationError.rollbackFailed
            }
            throw error
        }

        return MemoryStoreMigrationReport(
            namespaceCount: uniqueNamespaces.count,
            recordCount: recordCount
        )
    }

    private static func validateMemoryRecords(
        namespace: String,
        source: any MemoryStoring,
        batchSize: Int
    ) async throws -> Int {
        var cursor: MemoryRecordListCursor?
        var count = 0
        while true {
            let records = try await memoryPage(
                namespace: namespace,
                cursor: cursor,
                limit: batchSize,
                from: source
            )
            guard !records.isEmpty else { return count }
            for record in records {
                try MemoryQueryEngine.validate(record)
            }
            count = try migrationCount(adding: records.count, to: count)
            cursor = records.last.map {
                MemoryRecordListCursor(effectiveDate: $0.effectiveDate, recordID: $0.id)
            }
            if records.count < batchSize { return count }
        }
    }

    private static func verifyMemoryMigration(
        namespaces: [String],
        source: any MemoryStoring,
        destination: any MemoryStoring,
        batchSize: Int
    ) async throws {
        for namespace in namespaces {
            var sourceCursor: MemoryRecordListCursor?
            var destinationCursor: MemoryRecordListCursor?
            while true {
                let sourceRecords = try await memoryPage(
                    namespace: namespace,
                    cursor: sourceCursor,
                    limit: batchSize,
                    from: source
                )
                let destinationRecords = try await memoryPage(
                    namespace: namespace,
                    cursor: destinationCursor,
                    limit: batchSize,
                    from: destination
                )
                guard sourceRecords == destinationRecords else {
                    throw CodexKitStoreMigrationError.verificationFailed
                }
                guard !sourceRecords.isEmpty else { break }
                sourceCursor = sourceRecords.last.map {
                    MemoryRecordListCursor(effectiveDate: $0.effectiveDate, recordID: $0.id)
                }
                destinationCursor = destinationRecords.last.map {
                    MemoryRecordListCursor(effectiveDate: $0.effectiveDate, recordID: $0.id)
                }
                if sourceRecords.count < batchSize { break }
            }
        }
    }

    private static func memoryPage(
        namespace: String,
        cursor: MemoryRecordListCursor?,
        limit: Int,
        from store: any MemoryStoring
    ) async throws -> [MemoryRecord] {
        try await store.list(MemoryRecordListQuery(
            namespace: namespace,
            includeArchived: true,
            limit: limit,
            cursor: cursor
        ))
    }

    private static func rollbackMemoryRecords(
        namespaces: [String],
        in destination: any MemoryStoring,
        batchSize: Int
    ) async throws {
        for namespace in namespaces {
            while true {
                let records = try await destination.list(MemoryRecordListQuery(
                    namespace: namespace,
                    includeArchived: true,
                    limit: batchSize
                ))
                guard !records.isEmpty else { break }
                try await destination.delete(
                    ids: records.map(\.id),
                    namespace: namespace
                )
            }
        }
    }
}

private func migrationCount(adding amount: Int, to current: Int) throws -> Int {
    let (result, overflow) = current.addingReportingOverflow(amount)
    guard !overflow, result >= 0 else {
        throw CodexKitStoreMigrationError.countOverflow
    }
    return result
}

private func ensureDifferentStores(_ source: Any, _ destination: Any) throws {
    guard let source = source as? any StoreMigrationIdentifying,
          let destination = destination as? any StoreMigrationIdentifying else {
        return
    }
    guard source.storeMigrationIdentity != destination.storeMigrationIdentity else {
        throw CodexKitStoreMigrationError.sameSourceAndDestination
    }
}
