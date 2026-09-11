import Foundation

public actor FileRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    private let url: URL
    private let logger: AgentLogger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    public init(
        url: URL,
        logging: AgentLoggingConfiguration = .disabled
    ) {
        self.url = url
        self.logger = AgentLogger(configuration: logging)
    }

    public func loadState() async throws -> StoredRuntimeState {
        return try await RuntimeStoreMutationCoordinator.shared.perform(
            for: coordinationRootURL
        ) {
            try await self.loadStateWithoutCoordination()
        }
    }

    private func loadStateWithoutCoordination() throws -> StoredRuntimeState {
        logger.debug(.persistence, "Loading file runtime state.", metadata: ["url": url.path])
        return try loadNormalizedStateMigratingIfNeeded()
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        return try await RuntimeStoreMutationCoordinator.shared.perform(
            for: coordinationRootURL
        ) {
            try await self.saveStateWithoutCoordination(state)
        }
    }

    private func saveStateWithoutCoordination(_ state: StoredRuntimeState) throws {
        try AgentHistoryWriteValidator.validateSnapshot(state)
        logger.info(
            .persistence,
            "Saving file runtime state snapshot.",
            metadata: [
                "url": url.path,
                "threads": "\(state.threads.count)"
            ]
        )
        try persistLayout(for: state.normalized())
    }

    public func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        guard !operations.isEmpty else { return }
        try AgentStoreLimitValidator.validate(operations)
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: coordinationRootURL
        ) {
            try await self.applyWithoutCoordination(operations)
        }
    }

    private func applyWithoutCoordination(
        _ operations: [AgentStoreWriteOperation]
    ) throws {
        let state = try loadNormalizedStateMigratingIfNeeded()
        try persistLayout(for: state.applying(operations).normalized())
    }

    public func prepare() async throws -> AgentStoreMetadata {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: coordinationRootURL
        ) {
            try await self.prepareWithoutCoordination()
        }
    }

    private func prepareWithoutCoordination() async throws -> AgentStoreMetadata {
        logger.info(.persistence, "Preparing file runtime state store.", metadata: ["url": url.path])
        _ = try loadNormalizedStateMigratingIfNeeded()
        return try await readMetadata()
    }

    public func readMetadata() async throws -> AgentStoreMetadata {
        AgentStoreMetadata(
            logicalSchemaVersion: .v1,
            storeSchemaVersion: FileRuntimeStateManifest.currentStorageVersion,
            capabilities: AgentStoreCapabilities(
                supportsPushdownQueries: false,
                supportsCrossThreadQueries: false,
                supportsSorting: true,
                supportsFiltering: true,
                supportsMigrations: true
            ),
            storeKind: "FileRuntimeStateStore"
        )
    }

    public func fetchThreadSummary(id: String) async throws -> AgentThreadSummary {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: coordinationRootURL
        ) {
            try await self.fetchThreadSummaryWithoutCoordination(id: id)
        }
    }

    private func fetchThreadSummaryWithoutCoordination(id: String) throws -> AgentThreadSummary {
        if let manifest = try loadManifest() {
            guard let thread = manifest.threads.first(where: { $0.id == id }) else {
                throw AgentRuntimeError.threadNotFound(id)
            }
            return manifest.summariesByThread[id]
                ?? StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
        }

        return try loadNormalizedStateMigratingIfNeeded().threadSummary(id: id)
    }

    public func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage {
        try AgentStoreLimitValidator.validateHistoryPage(query)
        return try await RuntimeStoreMutationCoordinator.shared.perform(
            for: coordinationRootURL
        ) {
            try await self.fetchThreadHistoryWithoutCoordination(id: id, query: query)
        }
    }

    private func fetchThreadHistoryWithoutCoordination(
        id: String,
        query: AgentHistoryQuery
    ) throws -> AgentThreadHistoryPage {
        if let manifest = try loadManifest() {
            guard manifest.threads.contains(where: { $0.id == id }) else {
                throw AgentRuntimeError.threadNotFound(id)
            }

            let history = try loadHistory(for: id, manifest: manifest)
            let state = StoredRuntimeState(
                threads: manifest.threads,
                historyByThread: [id: history],
                summariesByThread: manifest.summariesByThread,
                nextHistorySequenceByThread: manifest.nextHistorySequenceByThread
            )
            return try state.threadHistoryPage(id: id, query: query)
        }

        return try loadNormalizedStateMigratingIfNeeded().threadHistoryPage(id: id, query: query)
    }

    public func fetchLatestStructuredOutputMetadata(id: String) async throws -> AgentStructuredOutputMetadata? {
        let summary = try await fetchThreadSummary(id: id)
        return summary.latestStructuredOutputMetadata
    }

    public func fetchThreadContextState(id: String) async throws -> AgentThreadContextState? {
        try await RuntimeStoreMutationCoordinator.shared.perform(
            for: coordinationRootURL
        ) {
            try await self.fetchThreadContextStateWithoutCoordination(id: id)
        }
    }

    private func fetchThreadContextStateWithoutCoordination(
        id: String
    ) throws -> AgentThreadContextState? {
        if let manifest = try loadManifest() {
            guard manifest.threads.contains(where: { $0.id == id }) else {
                throw AgentRuntimeError.threadNotFound(id)
            }
            return try manifest.contextState(
                for: id,
                using: attachmentStore(for: manifest)
            )
        }

        return try loadNormalizedStateMigratingIfNeeded().contextStateByThread[id]
    }

    public func execute<Query: AgentQuerySpec>(_ query: Query) async throws -> Query.Result {
        try AgentStoreLimitValidator.validate(query)
        return try await RuntimeStoreMutationCoordinator.shared.perform(
            for: coordinationRootURL
        ) {
            try await self.executeWithoutCoordination(query)
        }
    }

    private func executeWithoutCoordination<Query: AgentQuerySpec>(
        _ query: Query
    ) throws -> Query.Result {
        if let manifest = try loadManifest() {
            if let threadQuery = query as? ThreadMetadataQuery {
                let state = StoredRuntimeState(
                    threads: manifest.threads,
                    summariesByThread: manifest.summariesByThread
                )
                return try castAgentQueryResult(
                    threadQuery.execute(in: state),
                    to: Query.Result.self
                )
            }
            if let historyQuery = query as? HistoryItemsQuery {
                let history = try loadHistory(for: historyQuery.threadID, manifest: manifest)
                let state = StoredRuntimeState(
                    threads: manifest.threads.filter { $0.id == historyQuery.threadID },
                    historyByThread: [historyQuery.threadID: history],
                    summariesByThread: manifest.summariesByThread
                )
                return try castAgentQueryResult(
                    historyQuery.execute(in: state),
                    to: Query.Result.self
                )
            }
            if let contextQuery = query as? ThreadContextStateQuery {
                let attachmentStore = attachmentStore(for: manifest)
                let contexts: [String: AgentThreadContextState]
                if let threadIDs = contextQuery.threadIDs {
                    contexts = try Dictionary(uniqueKeysWithValues: threadIDs.compactMap { threadID in
                        try manifest.contextState(for: threadID, using: attachmentStore).map {
                            (threadID, $0)
                        }
                    })
                } else {
                    contexts = try manifest.decodedContextStates(using: attachmentStore)
                }
                let state = StoredRuntimeState(
                    threads: manifest.threads,
                    contextStateByThread: contexts
                )
                return try castAgentQueryResult(
                    contextQuery.execute(in: state),
                    to: Query.Result.self
                )
            }
        }

        let state = try loadNormalizedStateMigratingIfNeeded()
        return try query.execute(in: state)
    }

    private func loadNormalizedStateMigratingIfNeeded() throws -> StoredRuntimeState {
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }

        if let manifest = try loadManifest() {
            let state = try state(from: manifest)
            try AgentHistoryWriteValidator.validateSnapshot(state)
            if manifest.storageVersion < FileRuntimeStateManifest.currentStorageVersion {
                logger.info(
                    .persistence,
                    "Migrating file runtime state to generation-based storage.",
                    metadata: ["url": url.path]
                )
                try persistLayout(for: state)
            } else {
                try? removeUnreferencedGenerations(keeping: manifest.generation)
            }
            return state
        }

        let data = try Data(contentsOf: url)
        let decodedLegacy = try decoder.decode(StoredRuntimeState.self, from: data)
        try AgentHistoryWriteValidator.validateSnapshot(decodedLegacy)
        let legacy = decodedLegacy.normalized()
        logger.info(
            .persistence,
            "Migrating legacy file runtime state layout.",
            metadata: ["url": url.path]
        )
        try persistLayout(for: legacy)
        return legacy
    }

    private func loadManifest() throws -> FileRuntimeStateManifest? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let probe = try decoder.decode(FileRuntimeStateVersionProbe.self, from: data)
        guard let storageVersion = probe.storageVersion else {
            return nil
        }
        guard (1...FileRuntimeStateManifest.currentStorageVersion).contains(storageVersion) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Unsupported file runtime state storage version \(storageVersion)."
            ))
        }

        let manifest = try decoder.decode(FileRuntimeStateManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    private func state(from manifest: FileRuntimeStateManifest) throws -> StoredRuntimeState {
        var historyByThread: [String: [AgentHistoryRecord]] = [:]
        for thread in manifest.threads {
            historyByThread[thread.id] = try loadHistory(for: thread.id, manifest: manifest)
        }
        let contextStateByThread = try manifest.decodedContextStates(
            using: attachmentStore(for: manifest)
        )

        return StoredRuntimeState(
            threads: manifest.threads,
            historyByThread: historyByThread,
            summariesByThread: manifest.summariesByThread,
            contextStateByThread: contextStateByThread,
            nextHistorySequenceByThread: manifest.nextHistorySequenceByThread
        )
    }

    private func loadHistory(
        for threadID: String,
        manifest: FileRuntimeStateManifest
    ) throws -> [AgentHistoryRecord] {
        let historyURL = historyFileURL(for: threadID, manifest: manifest)
        guard fileManager.fileExists(atPath: historyURL.path) else {
            guard manifest.storageVersion < 2 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Missing history file for thread \(threadID)."
                ))
            }
            return []
        }

        let data = try Data(contentsOf: historyURL)
        if manifest.storageVersion >= FileRuntimeStateManifest.currentStorageVersion {
            let persisted = try decoder.decode([PersistedAgentHistoryRecord].self, from: data)
            let attachmentStore = attachmentStore(for: manifest)
            return try validateLoadedHistory(
                persisted.map { try $0.decode(using: attachmentStore) },
                threadID: threadID
            )
        }
        if let persisted = try? decoder.decode([PersistedAgentHistoryRecord].self, from: data) {
            let attachmentStore = attachmentStore(for: manifest)
            return try validateLoadedHistory(
                persisted.map { try $0.decode(using: attachmentStore) },
                threadID: threadID
            )
        }
        return try validateLoadedHistory(
            decoder.decode([AgentHistoryRecord].self, from: data),
            threadID: threadID
        )
    }

    private func validateLoadedHistory(
        _ records: [AgentHistoryRecord],
        threadID: String
    ) throws -> [AgentHistoryRecord] {
        for record in records {
            try AgentStoreLimitValidator.validateLoadedHistoryRecord(
                record,
                expectedThreadID: threadID
            )
        }
        return records
    }

    private func persistLayout(for state: StoredRuntimeState) throws {
        let normalized = state.normalized()
        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let generation = UUID().uuidString.lowercased()
        let generationURL = generationDirectoryURL(generation)
        let historyDirectoryURL = generationURL.appendingPathComponent("threads", isDirectory: true)
        let attachmentStore = RuntimeAttachmentStore(
            rootURL: generationURL.appendingPathComponent("attachments", isDirectory: true)
        )

        do {
            try fileManager.createDirectory(
                at: historyDirectoryURL,
                withIntermediateDirectories: true
            )
            try attachmentStore.prepare()

            for thread in normalized.threads {
                let historyURL = historyDirectoryURL
                    .appendingPathComponent(RuntimeAttachmentStore.safePathComponent(thread.id))
                    .appendingPathExtension("json")
                let history = normalized.historyByThread[thread.id] ?? []
                let persisted = try history.map {
                    try PersistedAgentHistoryRecord(
                        record: $0,
                        attachmentStore: attachmentStore
                    )
                }
                let data = try encoder.encode(persisted)
                try data.write(to: historyURL, options: .atomic)
            }

            let persistedContextStateByThread = try Dictionary(
                uniqueKeysWithValues: normalized.contextStateByThread.map { threadID, state in
                    (
                        threadID,
                        try PersistedAgentThreadContextState(
                            state: state,
                            attachmentStore: attachmentStore
                        )
                    )
                }
            )

            let manifest = FileRuntimeStateManifest(
                generation: generation,
                threads: normalized.threads,
                summariesByThread: normalized.summariesByThread,
                contextStateByThread: persistedContextStateByThread,
                nextHistorySequenceByThread: normalized.nextHistorySequenceByThread
            )
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: url, options: .atomic)
        } catch {
            if fileManager.fileExists(atPath: generationURL.path) {
                try? fileManager.removeItem(at: generationURL)
            }
            throw error
        }

        try? removeUnreferencedGenerations(keeping: generation)
    }

    private var sidecarDirectoryURL: URL {
        RuntimeAttachmentStore.sidecarDirectoryURL(for: url)
    }

    private var coordinationRootURL: URL {
        sidecarDirectoryURL.appendingPathComponent("attachments", isDirectory: true)
    }

    private var legacySidecarDirectoryURL: URL {
        RuntimeAttachmentStore.legacySidecarDirectoryURL(for: url)
    }

    private func generationDirectoryURL(_ generation: String) -> URL {
        sidecarDirectoryURL
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generation, isDirectory: true)
    }

    private func removeUnreferencedGenerations(keeping generation: String?) throws {
        let generationsURL = sidecarDirectoryURL
            .appendingPathComponent("generations", isDirectory: true)
        guard fileManager.fileExists(atPath: generationsURL.path) else { return }
        for candidate in try fileManager.contentsOfDirectory(
            at: generationsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) where candidate.lastPathComponent != generation {
            try fileManager.removeItem(at: candidate)
        }
    }

    private func historyFileURL(
        for threadID: String,
        manifest: FileRuntimeStateManifest
    ) -> URL {
        if let generation = manifest.generation {
            return generationDirectoryURL(generation)
                .appendingPathComponent("threads", isDirectory: true)
                .appendingPathComponent(RuntimeAttachmentStore.safePathComponent(threadID))
                .appendingPathExtension("json")
        }
        return legacySidecarDirectoryURL
            .appendingPathComponent("threads", isDirectory: true)
            .appendingPathComponent(legacyThreadFilename(threadID))
            .appendingPathExtension("json")
    }

    private func attachmentStore(for manifest: FileRuntimeStateManifest) -> RuntimeAttachmentStore {
        if let generation = manifest.generation {
            return RuntimeAttachmentStore(
                rootURL: generationDirectoryURL(generation)
                    .appendingPathComponent("attachments", isDirectory: true),
                legacyReadRootURLs: [
                    legacySidecarDirectoryURL.appendingPathComponent("attachments", isDirectory: true),
                ]
            )
        }
        return RuntimeAttachmentStore(
            rootURL: legacySidecarDirectoryURL.appendingPathComponent("attachments", isDirectory: true)
        )
    }

    private func legacyThreadFilename(_ threadID: String) -> String {
        threadID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? threadID
    }
}

extension FileRuntimeStateStore: StoreMigrationIdentifying, StoreMigrationCoordinating {
    package nonisolated var storeMigrationIdentity: StoreMigrationIdentity {
        StoreMigrationIdentity(kind: .runtime, url: url)
    }

    package nonisolated var migrationCoordinationRootURL: URL {
        RuntimeAttachmentStore.sidecarDirectoryURL(for: url)
            .appendingPathComponent("attachments", isDirectory: true)
    }
}
