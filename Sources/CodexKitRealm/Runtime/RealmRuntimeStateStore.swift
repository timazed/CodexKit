import CodexKit
import Foundation
import RealmSwift

public actor RealmRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    let url: URL
    let legacyStateURL: URL?
    let logging: AgentLoggingConfiguration
    let logger: AgentLogger
    let attachmentStore: RuntimeAttachmentStore
    let configuration: Realm.Configuration
    var realm: Realm?
    var isPrepared = false
    var preparationTask: Task<Void, Error>?
    var preparationGeneration: UInt64 = 0
    var latestApplyDecodedHistoryRecordCount = 0
    var latestQueryDecodedHistoryRecordCount = 0
    var attachmentMaintenanceTask: Task<Void, Never>?

    var codec: RealmRuntimeStateStoreCodec {
        RealmRuntimeStateStoreCodec(attachmentStore: attachmentStore)
    }

    public init(
        importingLegacyStateFrom legacyStateURL: URL? = nil,
        logging: AgentLoggingConfiguration = .disabled
    ) throws {
        let layout = try CodexKitManagedStorageLayout.live()
        try self.init(
            url: layout.fileURL(for: .realmRuntime),
            importingLegacyStateFrom: legacyStateURL,
            logging: logging
        )
    }

    package init(
        url: URL,
        importingLegacyStateFrom legacyStateURL: URL? = nil,
        logging: AgentLoggingConfiguration = .disabled
    ) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        self.url = url
        self.legacyStateURL = legacyStateURL ?? Self.defaultLegacyImportURL(for: url)
        self.logging = logging
        self.logger = AgentLogger(configuration: logging)
        let sidecarURL = RuntimeAttachmentStore.sidecarDirectoryURL(for: url)
        let legacySidecarURL = RuntimeAttachmentStore.legacySidecarDirectoryURL(for: url)
        self.attachmentStore = RuntimeAttachmentStore(
            rootURL: sidecarURL.appendingPathComponent("attachments", isDirectory: true),
            legacyReadRootURLs: [
                legacySidecarURL.appendingPathComponent("attachments", isDirectory: true),
            ]
        )
        self.configuration = RealmRuntimeStoreConfigurationBuilder(fileURL: url).build()

    }

    public func prepare() async throws -> AgentStoreMetadata {
        try await ensurePrepared()
        scheduleAttachmentMaintenance()
        return try await readMetadata()
    }

    public func readMetadata() async throws -> AgentStoreMetadata {
        try await ensurePrepared()
        let realm = try await openRealm()
        let storedVersion = realm.object(
            ofType: RealmRuntimeMetadataObject.self,
            forPrimaryKey: "runtime"
        )?.storeSchemaVersion ?? Int(RealmRuntimeSchema.version)

        return AgentStoreMetadata(
            logicalSchemaVersion: .v1,
            storeSchemaVersion: storedVersion,
            capabilities: AgentStoreCapabilities(
                supportsPushdownQueries: true,
                supportsCrossThreadQueries: true,
                supportsSorting: true,
                supportsFiltering: true,
                supportsMigrations: true,
                supportsLazyThreadActivation: true
            ),
            storeKind: "RealmRuntimeStateStore"
        )
    }

    public func loadState() async throws -> StoredRuntimeState {
        try await ensurePrepared()
        let realm = try await openRealm()
        let codec = self.codec
        let threads = try realm.objects(RealmRuntimeThreadObject.self).map(codec.decodeThread)
        let summaries = try realm.objects(RealmRuntimeSummaryObject.self).map(codec.decodeSummary)
        let historyObjects = realm.objects(RealmRuntimeHistoryObject.self)
            .sorted(byKeyPath: "sequenceNumber", ascending: true)
        let historyRecords = try historyObjects.map { object in
            (object.threadID, try codec.decodeHistoryRecord(from: object))
        }
        let contexts = try realm.objects(RealmRuntimeContextObject.self).map(codec.decodeContextState)
        let nextSequences = Dictionary(uniqueKeysWithValues: realm
            .objects(RealmRuntimeThreadObject.self)
            .map { ($0.id, $0.nextHistorySequence) })

        let state = StoredRuntimeState(
            threads: Array(threads),
            historyByThread: Dictionary(grouping: historyRecords, by: \.0)
                .mapValues { $0.map(\.1) },
            summariesByThread: Dictionary(uniqueKeysWithValues: summaries.map { ($0.threadID, $0) }),
            contextStateByThread: Dictionary(uniqueKeysWithValues: contexts.map { ($0.threadID, $0) }),
            nextHistorySequenceByThread: nextSequences
        )
        logger.debug(.persistence, "Loaded Realm runtime state.", metadata: ["threads": "\(state.threads.count)"])
        return state
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        try await ensurePrepared()
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: attachmentStore.rootURL
        ) {
            try await self.persistState(state)
        }
    }

    func persistState(
        _ state: StoredRuntimeState,
        legacyImportCompleted: Bool? = nil
    ) async throws {
        try AgentHistoryWriteValidator.validateSnapshot(state)
        let normalized = state.normalized()
        let realm = try await openRealm()
        var attachmentBatch = try attachmentStore.stageAttachments(in: normalized)
        do {
            try attachmentStore.promote(&attachmentBatch)
        } catch {
            try? await removeUnreferencedPromotedAttachments(
                attachmentBatch.newlyPromotedStorageKeys,
                in: realm
            )
            throw error
        }
        let writeCodec = RealmRuntimeStateStoreCodec(
            attachmentStore: attachmentStore,
            preparedAttachments: attachmentBatch.preparedAttachments
        )
        do {
            let threadObjects = try normalized.threads.map { thread in
                try writeCodec.makeThreadObject(
                    from: thread,
                    nextHistorySequence: normalized.nextHistorySequenceByThread[thread.id] ?? 1
                )
            }
            let summaryObjects = try normalized.summariesByThread.values.map(writeCodec.makeSummaryObject)
            let historyObjects = try normalized.historyByThread.flatMap { threadID, records in
                try records.map { try writeCodec.makeHistoryObject(from: $0, threadID: threadID) }
            }
            let contextObjects = try normalized.contextStateByThread.values.map(writeCodec.makeContextObject)
            let structuredOutputObjects = try normalized.historyByThread.flatMap { threadID, records in
                try records.compactMap { record in
                    try writeCodec.makeStructuredOutputObject(
                        from: record,
                        historyKey: RealmRuntimeStateStoreCodec.historyKey(
                            threadID: threadID,
                            sequenceNumber: record.sequenceNumber
                        )
                    )
                }
            }
            try attachmentStore.markFullReconciliationRequired()

            try await realm.asyncWrite {
                realm.delete(realm.objects(RealmRuntimeAttachmentReferenceObject.self))
                realm.delete(realm.objects(RealmRuntimeDeletedThreadAttachmentObject.self))
                realm.delete(realm.objects(RealmRuntimeThreadObject.self))
                realm.delete(realm.objects(RealmRuntimeSummaryObject.self))
                realm.delete(realm.objects(RealmRuntimeHistoryObject.self))
                realm.delete(realm.objects(RealmRuntimeContextObject.self))
                realm.delete(realm.objects(RealmRuntimeStructuredOutputObject.self))
                let metadata = realm.object(
                    ofType: RealmRuntimeMetadataObject.self,
                    forPrimaryKey: "runtime"
                ) ?? RealmRuntimeMetadataObject()
                metadata.storeSchemaVersion = Int(RealmRuntimeSchema.version)
                if let legacyImportCompleted {
                    metadata.legacyImportCompleted = legacyImportCompleted
                }
                realm.add(metadata, update: .modified)
                realm.add(threadObjects, update: .modified)
                realm.add(summaryObjects, update: .modified)
                realm.add(historyObjects, update: .modified)
                realm.add(contextObjects, update: .modified)
                realm.add(structuredOutputObjects, update: .modified)
                for object in historyObjects {
                    replaceAttachmentReferences(
                        ownerType: "history",
                        ownerKey: object.key,
                        threadID: object.threadID,
                        storageKeys: try writeCodec.attachmentStorageKeys(from: object),
                        in: realm
                    )
                }
                for object in contextObjects {
                    replaceAttachmentReferences(
                        ownerType: "context",
                        ownerKey: object.threadID,
                        threadID: object.threadID,
                        storageKeys: try writeCodec.attachmentStorageKeys(from: object),
                        in: realm
                    )
                }
            }
        } catch {
            try? await removeUnreferencedPromotedAttachments(
                attachmentBatch.newlyPromotedStorageKeys,
                in: realm
            )
            throw error
        }
        do {
            try attachmentStore.complete(attachmentBatch)
            try await reconcileAttachments(in: realm)
        } catch {
            logger.warning(
                .persistence,
                "Realm state committed; deferred attachment cleanup will retry on a future mutation or preparation.",
                metadata: ["error": error.localizedDescription]
            )
        }
        logger.debug(.persistence, "Saved Realm runtime state.", metadata: ["threads": "\(normalized.threads.count)"])
    }

    public func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        try await ensurePrepared()
        guard !operations.isEmpty else { return }
        try AgentStoreLimitValidator.validate(operations)

        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: attachmentStore.rootURL
        ) {
            try await self.applyWithoutCoordination(operations)
        }
        scheduleAttachmentMaintenance()
    }

    func applyWithoutCoordination(_ operations: [AgentStoreWriteOperation]) async throws {
        let realm = try await openRealm()
        var attachmentBatch = try attachmentStore.stageAttachments(in: operations)
        do {
            try attachmentStore.promote(&attachmentBatch)
        } catch {
            try? await removeUnreferencedPromotedAttachments(
                attachmentBatch.newlyPromotedStorageKeys,
                in: realm
            )
            throw error
        }
        let writeCodec = RealmRuntimeStateStoreCodec(
            attachmentStore: attachmentStore,
            preparedAttachments: attachmentBatch.preparedAttachments
        )
        latestApplyDecodedHistoryRecordCount = 0
        do {
            try await realm.asyncWrite {
                try applyIncrementally(operations, codec: writeCodec, in: realm)
            }
        } catch {
            try? await removeUnreferencedPromotedAttachments(
                attachmentBatch.newlyPromotedStorageKeys,
                in: realm
            )
            throw error
        }
        do {
            try attachmentStore.complete(attachmentBatch)
            _ = try await drainDeletedThreadAttachmentBatch(in: realm)
            _ = try await settleAttachmentCleanupBatch(in: realm)
        } catch {
            logger.warning(
                .persistence,
                "Realm operations committed; deferred attachment cleanup will retry on a future mutation or preparation.",
                metadata: ["error": error.localizedDescription]
            )
        }
        logger.debug(
            .persistence,
            "Applied Realm runtime state operations.",
            metadata: [
                "operation_count": "\(operations.count)",
                "affected_threads": "\(Set(operations.map(\.affectedThreadID)).count)",
            ]
        )
    }

    public func loadThreadActivationState(
        id: String,
        policy: AgentThreadActivationPolicy
    ) async throws -> AgentThreadActivationState {
        try await ensurePrepared()
        let realm = try await openRealm()
        guard let threadObject = realm.object(
            ofType: RealmRuntimeThreadObject.self,
            forPrimaryKey: id
        ) else {
            throw AgentRuntimeError.threadNotFound(id)
        }
        var payloadByteCount = 0
        try AgentStoreLimitValidator.accumulateMaterializedPayload(
            threadObject.encodedThread,
            name: "thread activation",
            total: &payloadByteCount
        )
        let thread = try codec.decodeThread(from: threadObject)
        let summary: AgentThreadSummary
        if let summaryObject = realm.object(
            ofType: RealmRuntimeSummaryObject.self,
            forPrimaryKey: id
        ) {
            try AgentStoreLimitValidator.accumulateMaterializedPayload(
                summaryObject.encodedSummary,
                name: "thread activation",
                total: &payloadByteCount
            )
            summary = try codec.decodeSummary(from: summaryObject)
        } else {
            summary = StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
        }

        let historyObjects = realm.objects(RealmRuntimeHistoryObject.self)
            .where { $0.threadID == id }
        guard threadObject.nextHistorySequence > 0 else {
            throw AgentStoreError.invalidInput("stored next history sequence must be positive")
        }
        let nextHistorySequence = threadObject.nextHistorySequence
        let persistedContextState: AgentThreadContextState?
        if let contextObject = realm.object(
            ofType: RealmRuntimeContextObject.self,
            forPrimaryKey: id
        ) {
            try AgentStoreLimitValidator.accumulateMaterializedPayload(
                contextObject.encodedState,
                name: "thread activation",
                total: &payloadByteCount
            )
            persistedContextState = try codec.decodeContextState(from: contextObject)
        } else {
            persistedContextState = nil
        }

        let sourceMessages: [AgentMessage]
        if let persistedContextState {
            sourceMessages = persistedContextState.effectiveMessages
        } else {
            let historyLimit = min(
                max(0, policy.maximumHistoryRecordCount),
                AgentStoreLimits.maximumActivationHistoryRecordCount
            )
            let recent = Array(historyObjects
                .sorted(byKeyPath: "sequenceNumber", ascending: false)
                .prefix(historyLimit))
            let relationshipKeys = Set(recent.compactMap(\.relationshipKey))
            let candidateLimit = historyLimit * 2 + 1
            let companions: [RealmRuntimeHistoryObject]
            if relationshipKeys.isEmpty {
                companions = []
            } else {
                companions = Array(historyObjects
                    .filter("relationshipKey IN %@", Array(relationshipKeys))
                    .prefix(candidateLimit))
                guard companions.count < candidateLimit else {
                    throw AgentStoreError.invalidInput(
                        "stored activation relationships exceed their bounded cardinality"
                    )
                }
            }
            var candidates = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0) })
            for object in companions { candidates[object.key] = object }
            let selectedKeys = try AgentThreadContextWindow.completeHistoryStorageKeys(
                from: candidates.values.map {
                    .init(
                        storageKey: $0.key,
                        sequenceNumber: $0.sequenceNumber,
                        relationshipKey: $0.relationshipKey
                    )
                },
                limit: historyLimit
            )
            let selected = candidates.values
                .filter { selectedKeys.contains($0.key) }
                .sorted { $0.sequenceNumber < $1.sequenceNumber }
            let records = try decodeBoundedRuntimeObjects(
                selected,
                name: "thread activation",
                payload: \.encodedRecord,
                payloadByteCount: &payloadByteCount,
                decode: codec.decodeHistoryRecord
            )
            sourceMessages = AgentThreadContextWindow.reconstructedMessages(from: records)
        }
        let effectiveMessages = AgentThreadContextWindow.boundedMessages(
            sourceMessages,
            policy: policy,
            requireClosedTurns: true
        )
        let contextState = persistedContextState.map { contextState in
            AgentThreadContextState(
                threadID: contextState.threadID,
                effectiveMessages: effectiveMessages,
                providerContext: effectiveMessages == contextState.effectiveMessages
                    ? contextState.providerContext
                    : nil,
                generation: contextState.generation,
                lastCompactedAt: contextState.lastCompactedAt,
                lastCompactionReason: contextState.lastCompactionReason,
                latestMarkerID: contextState.latestMarkerID
            )
        }
        return AgentThreadActivationState(
            thread: thread,
            summary: summary,
            contextState: contextState,
            nextHistorySequence: nextHistorySequence,
            effectiveMessages: effectiveMessages
        )
    }

    public func fetchThreadSummary(id: String) async throws -> AgentThreadSummary {
        try await ensurePrepared()
        let realm = try await openRealm()
        if let object = realm.object(
            ofType: RealmRuntimeSummaryObject.self,
            forPrimaryKey: id
        ) {
            return try codec.decodeSummary(from: object)
        }
        guard let object = realm.object(
            ofType: RealmRuntimeThreadObject.self,
            forPrimaryKey: id
        ) else {
            throw AgentRuntimeError.threadNotFound(id)
        }
        let thread = try codec.decodeThread(from: object)
        return StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
    }

    public func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage {
        try await ensurePrepared()
        try AgentStoreLimitValidator.validateHistoryPage(query)
        let realm = try await openRealm()
        guard realm.object(
            ofType: RealmRuntimeThreadObject.self,
            forPrimaryKey: id
        ) != nil else {
            throw AgentRuntimeError.threadNotFound(id)
        }
        latestQueryDecodedHistoryRecordCount = 0
        return try fetchHistoryPage(id: id, query: query, from: realm)
    }

    public func fetchLatestStructuredOutputMetadata(id: String) async throws -> AgentStructuredOutputMetadata? {
        try await fetchThreadSummary(id: id).latestStructuredOutputMetadata
    }

    public func fetchThreadContextState(id: String) async throws -> AgentThreadContextState? {
        try await ensurePrepared()
        let realm = try await openRealm()
        guard realm.object(
            ofType: RealmRuntimeThreadObject.self,
            forPrimaryKey: id
        ) != nil else {
            throw AgentRuntimeError.threadNotFound(id)
        }
        guard let object = realm.object(
            ofType: RealmRuntimeContextObject.self,
            forPrimaryKey: id
        ) else {
            return nil
        }
        return try codec.decodeContextState(from: object)
    }

    public func execute<Query: AgentQuerySpec>(_ query: Query) async throws -> Query.Result {
        try await ensurePrepared()
        try AgentStoreLimitValidator.validate(query)
        let realm = try await openRealm()
        if let historyQuery = query as? HistoryItemsQuery {
            latestQueryDecodedHistoryRecordCount = 0
            return try castAgentQueryResult(
                executeHistoryQuery(historyQuery, in: realm),
                to: Query.Result.self
            )
        }
        if let threadQuery = query as? ThreadMetadataQuery {
            return try castAgentQueryResult(
                executeThreadQuery(threadQuery, in: realm),
                to: Query.Result.self
            )
        }
        if let pendingQuery = query as? PendingStateQuery {
            return try castAgentQueryResult(
                executePendingStateQuery(pendingQuery, in: realm),
                to: Query.Result.self
            )
        }
        if let structuredQuery = query as? StructuredOutputQuery {
            return try castAgentQueryResult(
                executeStructuredOutputQuery(structuredQuery, in: realm),
                to: Query.Result.self
            )
        }
        if let snapshotQuery = query as? ThreadSnapshotQuery {
            return try castAgentQueryResult(
                executeThreadSnapshotQuery(snapshotQuery, in: realm),
                to: Query.Result.self
            )
        }
        if let contextQuery = query as? ThreadContextStateQuery {
            return try castAgentQueryResult(
                executeThreadContextStateQuery(contextQuery, in: realm),
                to: Query.Result.self
            )
        }
        throw AgentStoreError.queryNotSupported(String(describing: Query.self))
    }
}

extension RealmRuntimeStateStore: StoreMigrationIdentifying, StoreMigrationCoordinating {
    package nonisolated var storeMigrationIdentity: StoreMigrationIdentity {
        StoreMigrationIdentity(kind: "runtime", url: url)
    }

    package nonisolated var migrationCoordinationRootURL: URL {
        attachmentStore.rootURL
    }
}
