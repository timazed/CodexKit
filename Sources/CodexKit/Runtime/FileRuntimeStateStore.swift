import Foundation

public actor FileRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default
    private let attachmentStore: RuntimeAttachmentStore

    public init(url: URL) {
        self.url = url
        let basename = url.deletingPathExtension().lastPathComponent
        self.attachmentStore = RuntimeAttachmentStore(
            rootURL: url.deletingLastPathComponent()
                .appendingPathComponent("\(basename).codexkit-state", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
        )
    }

    public func loadState() async throws -> StoredRuntimeState {
        try loadNormalizedStateMigratingIfNeeded()
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        try persistLayout(for: state.normalized())
    }

    public func prepare() async throws -> AgentStoreMetadata {
        _ = try loadNormalizedStateMigratingIfNeeded()
        return try await readMetadata()
    }

    public func readMetadata() async throws -> AgentStoreMetadata {
        AgentStoreMetadata(
            logicalSchemaVersion: .v1,
            storeSchemaVersion: 1,
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
        if let manifest = try loadManifest() {
            guard manifest.threads.contains(where: { $0.id == id }) else {
                throw AgentRuntimeError.threadNotFound(id)
            }

            let history = try loadHistory(for: id)
            let state = StoredRuntimeState(
                threads: manifest.threads,
                historyByThread: [id: history],
                summariesByThread: manifest.summariesByThread,
                contextStateByThread: manifest.contextStateByThread,
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
        if let manifest = try loadManifest() {
            guard manifest.threads.contains(where: { $0.id == id }) else {
                throw AgentRuntimeError.threadNotFound(id)
            }
            return manifest.contextStateByThread[id]
        }

        return try loadNormalizedStateMigratingIfNeeded().contextStateByThread[id]
    }

    private func loadNormalizedStateMigratingIfNeeded() throws -> StoredRuntimeState {
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }

        if let manifest = try loadManifest() {
            return try state(from: manifest)
        }

        let data = try Data(contentsOf: url)
        let legacy = try decoder.decode(StoredRuntimeState.self, from: data).normalized()
        try persistLayout(for: legacy)
        return legacy
    }

    private func loadManifest() throws -> FileRuntimeStateManifest? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try? decoder.decode(FileRuntimeStateManifest.self, from: data)
    }

    private func state(from manifest: FileRuntimeStateManifest) throws -> StoredRuntimeState {
        var historyByThread: [String: [AgentHistoryRecord]] = [:]
        for thread in manifest.threads {
            historyByThread[thread.id] = try loadHistory(for: thread.id)
        }

        return StoredRuntimeState(
            threads: manifest.threads,
            historyByThread: historyByThread,
            summariesByThread: manifest.summariesByThread,
            contextStateByThread: manifest.contextStateByThread,
            nextHistorySequenceByThread: manifest.nextHistorySequenceByThread
        )
    }

    private func loadHistory(for threadID: String) throws -> [AgentHistoryRecord] {
        let historyURL = historyFileURL(for: threadID)
        guard fileManager.fileExists(atPath: historyURL.path) else {
            return []
        }

        let data = try Data(contentsOf: historyURL)
        if let persisted = try? decoder.decode([PersistedAgentHistoryRecord].self, from: data) {
            return try persisted.map { try $0.decode(using: attachmentStore) }
        }
        return try decoder.decode([AgentHistoryRecord].self, from: data)
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

        try fileManager.createDirectory(
            at: historyDirectoryURL,
            withIntermediateDirectories: true
        )
        try attachmentStore.reset()

        for thread in normalized.threads {
            let historyURL = historyFileURL(for: thread.id)
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

        let manifest = FileRuntimeStateManifest(
            threads: normalized.threads,
            summariesByThread: normalized.summariesByThread,
            contextStateByThread: normalized.contextStateByThread,
            nextHistorySequenceByThread: normalized.nextHistorySequenceByThread
        )
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: url, options: .atomic)
    }

    private var historyDirectoryURL: URL {
        let basename = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(basename).codexkit-state", isDirectory: true)
            .appendingPathComponent("threads", isDirectory: true)
    }

    private func historyFileURL(for threadID: String) -> URL {
        historyDirectoryURL.appendingPathComponent(safeThreadFilename(threadID)).appendingPathExtension("json")
    }

    private func safeThreadFilename(_ threadID: String) -> String {
        threadID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? threadID
    }
}

private struct FileRuntimeStateManifest: Codable {
    let storageVersion: Int
    let threads: [AgentThread]
    let summariesByThread: [String: AgentThreadSummary]
    let contextStateByThread: [String: AgentThreadContextState]
    let nextHistorySequenceByThread: [String: Int]

    init(
        threads: [AgentThread],
        summariesByThread: [String: AgentThreadSummary],
        contextStateByThread: [String: AgentThreadContextState],
        nextHistorySequenceByThread: [String: Int]
    ) {
        self.storageVersion = 1
        self.threads = threads
        self.summariesByThread = summariesByThread
        self.contextStateByThread = contextStateByThread
        self.nextHistorySequenceByThread = nextHistorySequenceByThread
    }
}
