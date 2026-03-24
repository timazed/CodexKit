import Foundation

public struct StoredRuntimeState: Codable, Hashable, Sendable {
    public var threads: [AgentThread]
    public var messagesByThread: [String: [AgentMessage]]
    public var historyByThread: [String: [AgentHistoryRecord]]
    public var summariesByThread: [String: AgentThreadSummary]
    public var contextStateByThread: [String: AgentThreadContextState]
    public var nextHistorySequenceByThread: [String: Int]

    public init(
        threads: [AgentThread] = [],
        messagesByThread: [String: [AgentMessage]] = [:],
        historyByThread: [String: [AgentHistoryRecord]] = [:],
        summariesByThread: [String: AgentThreadSummary] = [:],
        contextStateByThread: [String: AgentThreadContextState] = [:],
        nextHistorySequenceByThread: [String: Int] = [:]
    ) {
        self.init(
            threads: threads,
            messagesByThread: messagesByThread,
            historyByThread: historyByThread,
            summariesByThread: summariesByThread,
            contextStateByThread: contextStateByThread,
            nextHistorySequenceByThread: nextHistorySequenceByThread,
            normalizeState: false
        )
        self = normalized()
    }

    init(
        threads: [AgentThread],
        messagesByThread: [String: [AgentMessage]],
        historyByThread: [String: [AgentHistoryRecord]],
        summariesByThread: [String: AgentThreadSummary],
        contextStateByThread: [String: AgentThreadContextState],
        nextHistorySequenceByThread: [String: Int],
        normalizeState: Bool
    ) {
        self.threads = threads
        self.messagesByThread = messagesByThread
        self.historyByThread = historyByThread
        self.summariesByThread = summariesByThread
        self.contextStateByThread = contextStateByThread
        self.nextHistorySequenceByThread = nextHistorySequenceByThread
        if normalizeState {
            self = normalized()
        }
    }

    public static let empty = StoredRuntimeState()

    enum CodingKeys: String, CodingKey {
        case threads
        case messagesByThread
        case historyByThread
        case summariesByThread
        case contextStateByThread
        case nextHistorySequenceByThread
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            threads: try container.decodeIfPresent([AgentThread].self, forKey: .threads) ?? [],
            messagesByThread: try container.decodeIfPresent([String: [AgentMessage]].self, forKey: .messagesByThread) ?? [:],
            historyByThread: try container.decodeIfPresent([String: [AgentHistoryRecord]].self, forKey: .historyByThread) ?? [:],
            summariesByThread: try container.decodeIfPresent([String: AgentThreadSummary].self, forKey: .summariesByThread) ?? [:],
            contextStateByThread: try container.decodeIfPresent([String: AgentThreadContextState].self, forKey: .contextStateByThread) ?? [:],
            nextHistorySequenceByThread: try container.decodeIfPresent([String: Int].self, forKey: .nextHistorySequenceByThread) ?? [:]
        )
    }
}

public protocol RuntimeStateStoring: Sendable {
    func loadState() async throws -> StoredRuntimeState
    func saveState(_ state: StoredRuntimeState) async throws
    func prepare() async throws -> AgentStoreMetadata
    func readMetadata() async throws -> AgentStoreMetadata
    func apply(_ operations: [AgentStoreWriteOperation]) async throws
}

public protocol RuntimeStateInspecting: Sendable {
    func fetchThreadSummary(id: String) async throws -> AgentThreadSummary
    func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage
    func fetchLatestStructuredOutputMetadata(id: String) async throws -> AgentStructuredOutputMetadata?
    func fetchThreadContextState(id: String) async throws -> AgentThreadContextState?
}

public extension RuntimeStateStoring {
    func prepare() async throws -> AgentStoreMetadata {
        _ = try await loadState()
        return try await readMetadata()
    }

    func readMetadata() async throws -> AgentStoreMetadata {
        AgentStoreMetadata(
            logicalSchemaVersion: .v1,
            storeSchemaVersion: 1,
            capabilities: AgentStoreCapabilities(
                supportsPushdownQueries: false,
                supportsCrossThreadQueries: true,
                supportsSorting: true,
                supportsFiltering: true,
                supportsMigrations: false
            ),
            storeKind: String(describing: Self.self)
        )
    }

    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        let state = try await loadState()
        let updated = try state.applying(operations)
        try await saveState(updated)
    }
}

public actor InMemoryRuntimeStateStore: RuntimeStateStoring, RuntimeStateInspecting, AgentRuntimeQueryableStore {
    private var state: StoredRuntimeState

    public init(initialState: StoredRuntimeState = .empty) {
        state = initialState.normalized()
    }

    public func loadState() async throws -> StoredRuntimeState {
        state
    }

    public func saveState(_ state: StoredRuntimeState) async throws {
        self.state = state.normalized()
    }

    public func prepare() async throws -> AgentStoreMetadata {
        state = state.normalized()
        return try await readMetadata()
    }

    public func readMetadata() async throws -> AgentStoreMetadata {
        AgentStoreMetadata(
            logicalSchemaVersion: .v1,
            storeSchemaVersion: 1,
            capabilities: AgentStoreCapabilities(
                supportsPushdownQueries: true,
                supportsCrossThreadQueries: true,
                supportsSorting: true,
                supportsFiltering: true,
                supportsMigrations: false
            ),
            storeKind: "InMemoryRuntimeStateStore"
        )
    }

    public func fetchThreadSummary(id: String) async throws -> AgentThreadSummary {
        try state.threadSummary(id: id)
    }

    public func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage {
        try state.threadHistoryPage(id: id, query: query)
    }

    public func fetchLatestStructuredOutputMetadata(id: String) async throws -> AgentStructuredOutputMetadata? {
        try state.threadSummary(id: id).latestStructuredOutputMetadata
    }

    public func fetchThreadContextState(id: String) async throws -> AgentThreadContextState? {
        state.contextStateByThread[id]
    }
}

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

extension StoredRuntimeState {
    func normalized() -> StoredRuntimeState {
        let sortedThreads = threads.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id < rhs.id
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        var normalizedHistory = historyByThread
            .mapValues { records in
                records.sorted { lhs, rhs in
                    if lhs.sequenceNumber == rhs.sequenceNumber {
                        return lhs.createdAt < rhs.createdAt
                    }
                    return lhs.sequenceNumber < rhs.sequenceNumber
                }
            }

        for (threadID, messages) in messagesByThread where normalizedHistory[threadID]?.isEmpty != false {
            normalizedHistory[threadID] = Self.syntheticHistory(from: messages)
        }

        let normalizedMessages: [String: [AgentMessage]] = normalizedHistory.mapValues { records in
            records.compactMap { record -> AgentMessage? in
                guard case let .message(message) = record.item else {
                    return nil
                }
                return message
            }
        }

        var normalizedNextSequence = nextHistorySequenceByThread
        for thread in sortedThreads {
            let history = normalizedHistory[thread.id] ?? []
            let nextSequence = (history.last?.sequenceNumber ?? 0) + 1
            normalizedNextSequence[thread.id] = max(normalizedNextSequence[thread.id] ?? 0, nextSequence)
        }

        var normalizedSummaries: [String: AgentThreadSummary] = [:]
        var normalizedContextState = contextStateByThread
        for thread in sortedThreads {
            let history = normalizedHistory[thread.id] ?? []
            normalizedSummaries[thread.id] = Self.rebuildSummary(
                for: thread,
                history: history,
                existing: summariesByThread[thread.id]
            )
            if let existing = normalizedContextState[thread.id] {
                normalizedContextState[thread.id] = AgentThreadContextState(
                    threadID: thread.id,
                    effectiveMessages: existing.effectiveMessages,
                    generation: existing.generation,
                    lastCompactedAt: existing.lastCompactedAt,
                    lastCompactionReason: existing.lastCompactionReason,
                    latestMarkerID: existing.latestMarkerID
                )
            }
        }

        return StoredRuntimeState(
            threads: sortedThreads,
            messagesByThread: normalizedMessages,
            historyByThread: normalizedHistory,
            summariesByThread: normalizedSummaries,
            contextStateByThread: normalizedContextState,
            nextHistorySequenceByThread: normalizedNextSequence,
            normalizeState: false
        )
    }

    func threadSummary(id: String) throws -> AgentThreadSummary {
        guard let thread = threads.first(where: { $0.id == id }) else {
            throw AgentRuntimeError.threadNotFound(id)
        }

        return summariesByThread[id] ?? threadSummaryFallback(for: thread)
    }

    func threadSummaryFallback(for thread: AgentThread) -> AgentThreadSummary {
        Self.rebuildSummary(
            for: thread,
            history: historyByThread[thread.id] ?? [],
            existing: summariesByThread[thread.id]
        )
    }

    func threadHistoryPage(
        id: String,
        query: AgentHistoryQuery
    ) throws -> AgentThreadHistoryPage {
        guard threads.contains(where: { $0.id == id }) else {
            throw AgentRuntimeError.threadNotFound(id)
        }

        let limit = max(1, query.limit)
        let filter = query.filter ?? AgentHistoryFilter()
        let records = (historyByThread[id] ?? []).filter { filter.matches($0.item) }
        let anchor = try query.cursor?.decodedSequenceNumber(expectedThreadID: id)

        switch query.direction {
        case .backward:
            let endIndex = records.endIndexForBackward(anchor: anchor)
            let startIndex = max(0, endIndex - limit)
            let pageRecords = Array(records[startIndex ..< endIndex])
            let hasMoreBefore = startIndex > 0
            let hasMoreAfter = endIndex < records.count
            return AgentThreadHistoryPage(
                threadID: id,
                items: pageRecords.map(\.item),
                nextCursor: hasMoreBefore ? AgentHistoryCursor(threadID: id, sequenceNumber: pageRecords.first?.sequenceNumber) : nil,
                previousCursor: hasMoreAfter ? AgentHistoryCursor(threadID: id, sequenceNumber: pageRecords.last?.sequenceNumber) : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: hasMoreAfter
            )

        case .forward:
            let startIndex = records.startIndexForForward(anchor: anchor)
            let endIndex = min(records.count, startIndex + limit)
            let pageRecords = Array(records[startIndex ..< endIndex])
            let hasMoreBefore = startIndex > 0
            let hasMoreAfter = endIndex < records.count
            return AgentThreadHistoryPage(
                threadID: id,
                items: pageRecords.map(\.item),
                nextCursor: hasMoreAfter ? AgentHistoryCursor(threadID: id, sequenceNumber: pageRecords.last?.sequenceNumber) : nil,
                previousCursor: hasMoreBefore ? AgentHistoryCursor(threadID: id, sequenceNumber: pageRecords.first?.sequenceNumber) : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: hasMoreAfter
            )
        }
    }

    func applying(_ operations: [AgentStoreWriteOperation]) throws -> StoredRuntimeState {
        var updated = self

        for operation in operations {
            switch operation {
            case let .upsertThread(thread):
                if let index = updated.threads.firstIndex(where: { $0.id == thread.id }) {
                    updated.threads[index] = thread
                } else {
                    updated.threads.append(thread)
                }

            case let .upsertSummary(threadID, summary):
                updated.summariesByThread[threadID] = summary

            case let .appendHistoryItems(threadID, items):
                updated.historyByThread[threadID, default: []].append(contentsOf: items)
                let nextSequence = (updated.historyByThread[threadID]?.last?.sequenceNumber ?? 0) + 1
                updated.nextHistorySequenceByThread[threadID] = nextSequence

            case let .appendCompactionMarker(threadID, marker):
                updated.historyByThread[threadID, default: []].append(marker)
                let nextSequence = (updated.historyByThread[threadID]?.last?.sequenceNumber ?? 0) + 1
                updated.nextHistorySequenceByThread[threadID] = nextSequence

            case let .upsertThreadContextState(threadID, state):
                updated.contextStateByThread[threadID] = state

            case let .deleteThreadContextState(threadID):
                updated.contextStateByThread.removeValue(forKey: threadID)

            case let .setPendingState(threadID, state):
                if let thread = updated.threads.first(where: { $0.id == threadID }) {
                    let current = updated.summariesByThread[threadID] ?? updated.threadSummaryFallback(for: thread)
                    updated.summariesByThread[threadID] = AgentThreadSummary(
                        threadID: current.threadID,
                        createdAt: current.createdAt,
                        updatedAt: current.updatedAt,
                        latestItemAt: current.latestItemAt,
                        itemCount: current.itemCount,
                        latestAssistantMessagePreview: current.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: current.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: current.latestPartialStructuredOutput,
                        latestToolState: current.latestToolState,
                        latestTurnStatus: current.latestTurnStatus,
                        pendingState: state
                    )
                }

            case let .setPartialStructuredSnapshot(threadID, snapshot):
                if let thread = updated.threads.first(where: { $0.id == threadID }) {
                    let current = updated.summariesByThread[threadID] ?? updated.threadSummaryFallback(for: thread)
                    updated.summariesByThread[threadID] = AgentThreadSummary(
                        threadID: current.threadID,
                        createdAt: current.createdAt,
                        updatedAt: current.updatedAt,
                        latestItemAt: current.latestItemAt,
                        itemCount: current.itemCount,
                        latestAssistantMessagePreview: current.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: current.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: snapshot,
                        latestToolState: current.latestToolState,
                        latestTurnStatus: current.latestTurnStatus,
                        pendingState: current.pendingState
                    )
                }

            case let .upsertToolSession(threadID, session):
                if let thread = updated.threads.first(where: { $0.id == threadID }) {
                    let current = updated.summariesByThread[threadID] ?? updated.threadSummaryFallback(for: thread)
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
                    updated.summariesByThread[threadID] = AgentThreadSummary(
                        threadID: current.threadID,
                        createdAt: current.createdAt,
                        updatedAt: current.updatedAt,
                        latestItemAt: current.latestItemAt,
                        itemCount: current.itemCount,
                        latestAssistantMessagePreview: current.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: current.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: current.latestPartialStructuredOutput,
                        latestToolState: latestToolState,
                        latestTurnStatus: current.latestTurnStatus,
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
                guard !itemIDs.isEmpty else {
                    continue
                }
                updated.historyByThread[threadID] = updated.historyByThread[threadID]?.map { record in
                    guard itemIDs.contains(record.id) else {
                        return record
                    }
                    return record.redacted(reason: reason)
                }

            case let .deleteThread(threadID):
                updated.threads.removeAll { $0.id == threadID }
                updated.messagesByThread.removeValue(forKey: threadID)
                updated.historyByThread.removeValue(forKey: threadID)
                updated.summariesByThread.removeValue(forKey: threadID)
                updated.contextStateByThread.removeValue(forKey: threadID)
                updated.nextHistorySequenceByThread.removeValue(forKey: threadID)
            }
        }

        return updated.normalized()
    }

    func execute(_ query: HistoryItemsQuery) throws -> AgentHistoryQueryResult {
        guard threads.contains(where: { $0.id == query.threadID }) else {
            return AgentHistoryQueryResult(
                threadID: query.threadID,
                records: [],
                nextCursor: nil,
                previousCursor: nil,
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        var records = historyByThread[query.threadID] ?? []
        if let kinds = query.kinds {
            records = records.filter { kinds.contains($0.item.kind) }
        }
        if let createdAtRange = query.createdAtRange {
            records = records.filter { createdAtRange.contains($0.createdAt) }
        }
        if let turnID = query.turnID {
            records = records.filter { $0.item.turnID == turnID }
        }
        if !query.includeRedacted {
            records = records.filter { $0.redaction == nil }
        }
        if !query.includeCompactionEvents {
            records = records.filter { !$0.item.isCompactionMarker }
        }

        records = sort(records, using: query.sort)
        let page = try page(records, threadID: query.threadID, with: query.page, sort: query.sort)
        return page
    }

    func execute(_ query: ThreadMetadataQuery) -> [AgentThread] {
        var filtered = threads
        if let threadIDs = query.threadIDs {
            filtered = filtered.filter { threadIDs.contains($0.id) }
        }
        if let statuses = query.statuses {
            filtered = filtered.filter { statuses.contains($0.status) }
        }
        if let updatedAtRange = query.updatedAtRange {
            filtered = filtered.filter { updatedAtRange.contains($0.updatedAt) }
        }
        filtered = sort(filtered, using: query.sort)
        if let limit = query.limit {
            filtered = Array(filtered.prefix(max(0, limit)))
        }
        return filtered
    }

    func execute(_ query: PendingStateQuery) -> [AgentPendingStateRecord] {
        var records = summariesByThread.compactMap { threadID, summary -> AgentPendingStateRecord? in
            guard let pendingState = summary.pendingState else {
                return nil
            }
            return AgentPendingStateRecord(
                threadID: threadID,
                pendingState: pendingState,
                updatedAt: summary.updatedAt
            )
        }

        if let threadIDs = query.threadIDs {
            records = records.filter { threadIDs.contains($0.threadID) }
        }
        if let kinds = query.kinds {
            records = records.filter { kinds.contains($0.pendingState.kind) }
        }
        records = sort(records, using: query.sort)
        if let limit = query.limit {
            records = Array(records.prefix(max(0, limit)))
        }
        return records
    }

    func execute(_ query: StructuredOutputQuery) -> [AgentStructuredOutputRecord] {
        var records = historyByThread.values
            .flatMap { $0 }
            .compactMap { record -> AgentStructuredOutputRecord? in
                switch record.item {
                case let .structuredOutput(structuredOutput):
                    return structuredOutput

                case let .message(message):
                    guard let metadata = message.structuredOutput else {
                        return nil
                    }
                    return AgentStructuredOutputRecord(
                        threadID: message.threadID,
                        turnID: "",
                        messageID: message.id,
                        metadata: metadata,
                        committedAt: message.createdAt
                    )

                default:
                    return nil
                }
            }

        if let threadIDs = query.threadIDs {
            records = records.filter { threadIDs.contains($0.threadID) }
        }
        if let formatNames = query.formatNames {
            records = records.filter { formatNames.contains($0.metadata.formatName) }
        }

        records = sort(records, using: query.sort)

        if query.latestOnly {
            var seen = Set<String>()
            records = records.filter { record in
                seen.insert(record.threadID).inserted
            }
        }

        if let limit = query.limit {
            records = Array(records.prefix(max(0, limit)))
        }
        return records
    }

    func execute(_ query: ThreadSnapshotQuery) -> [AgentThreadSnapshot] {
        var snapshots = threads.compactMap { thread -> AgentThreadSnapshot? in
            guard query.threadIDs?.contains(thread.id) ?? true else {
                return nil
            }
            let summary = summariesByThread[thread.id] ?? threadSummaryFallback(for: thread)
            return summary.snapshot
        }
        snapshots = sort(snapshots, using: query.sort)
        if let limit = query.limit {
            snapshots = Array(snapshots.prefix(max(0, limit)))
        }
        return snapshots
    }

    func execute(_ query: ThreadContextStateQuery) -> [AgentThreadContextState] {
        var records = Array(contextStateByThread.values)
        if let threadIDs = query.threadIDs {
            records = records.filter { threadIDs.contains($0.threadID) }
        }
        records.sort { lhs, rhs in
            if lhs.generation == rhs.generation {
                return lhs.threadID < rhs.threadID
            }
            return lhs.generation > rhs.generation
        }
        if let limit = query.limit {
            records = Array(records.prefix(max(0, limit)))
        }
        return records
    }

    private static func syntheticHistory(from messages: [AgentMessage]) -> [AgentHistoryRecord] {
        let orderedMessages = messages.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            if left.createdAt == right.createdAt {
                return lhs.offset < rhs.offset
            }
            return left.createdAt < right.createdAt
        }

        return orderedMessages.enumerated().map { index, pair in
            AgentHistoryRecord(
                sequenceNumber: index + 1,
                createdAt: pair.element.createdAt,
                item: .message(pair.element)
            )
        }
    }

    private static func rebuildSummary(
        for thread: AgentThread,
        history: [AgentHistoryRecord],
        existing: AgentThreadSummary?
    ) -> AgentThreadSummary {
        var latestAssistantMessagePreview = existing?.latestAssistantMessagePreview
        var latestStructuredOutputMetadata = existing?.latestStructuredOutputMetadata
        var latestToolState = existing?.latestToolState
        var latestTurnStatus = existing?.latestTurnStatus
        let latestPartialStructuredOutput = existing?.latestPartialStructuredOutput
        let pendingState = existing?.pendingState

        for record in history {
            switch record.item {
            case let .message(message):
                if message.role == .assistant {
                    latestAssistantMessagePreview = message.displayText
                    if let structuredOutput = message.structuredOutput {
                        latestStructuredOutputMetadata = structuredOutput
                    }
                }

            case let .toolCall(toolCall):
                latestToolState = AgentLatestToolState(
                    invocationID: toolCall.invocation.id,
                    turnID: toolCall.invocation.turnID,
                    toolName: toolCall.invocation.toolName,
                    status: .waiting,
                    updatedAt: toolCall.requestedAt
                )

            case let .toolResult(toolResult):
                latestToolState = Self.latestToolState(from: toolResult)

            case let .structuredOutput(structuredOutput):
                latestStructuredOutputMetadata = structuredOutput.metadata

            case .approval:
                break

            case let .systemEvent(systemEvent):
                switch systemEvent.type {
                case .turnStarted:
                    latestTurnStatus = .running
                case .turnCompleted:
                    latestTurnStatus = .completed
                case .turnFailed:
                    latestTurnStatus = .failed
                case .threadCreated, .threadResumed, .threadStatusChanged, .contextCompacted:
                    break
                }
            }
        }

        return AgentThreadSummary(
            threadID: thread.id,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            latestItemAt: history.last?.createdAt,
            itemCount: history.count,
            latestAssistantMessagePreview: latestAssistantMessagePreview,
            latestStructuredOutputMetadata: latestStructuredOutputMetadata,
            latestPartialStructuredOutput: latestPartialStructuredOutput,
            latestToolState: latestToolState,
            latestTurnStatus: latestTurnStatus,
            pendingState: pendingState
        )
    }

    private static func latestToolState(from toolResult: AgentToolResultRecord) -> AgentLatestToolState {
        let preview = toolResult.result.primaryText
        let session = toolResult.result.session
        let status: AgentToolSessionStatus
        if toolResult.result.errorMessage == "Tool execution was denied by the user." {
            status = .denied
        } else if let session, !session.isTerminal {
            status = .running
        } else if toolResult.result.success {
            status = .completed
        } else {
            status = .failed
        }

        return AgentLatestToolState(
            invocationID: toolResult.result.invocationID,
            turnID: toolResult.turnID,
            toolName: toolResult.result.toolName,
            status: status,
            success: toolResult.result.success,
            sessionID: session?.sessionID,
            sessionStatus: session?.status,
            metadata: session?.metadata,
            resumable: session?.resumable ?? false,
            updatedAt: toolResult.completedAt,
            resultPreview: preview
        )
    }
}

private extension Array where Element == AgentHistoryRecord {
    func endIndexForBackward(anchor: Int?) -> Int {
        guard let anchor else {
            return count
        }

        return firstIndex(where: { $0.sequenceNumber >= anchor }) ?? count
    }

    func startIndexForForward(anchor: Int?) -> Int {
        guard let anchor else {
            return 0
        }

        return firstIndex(where: { $0.sequenceNumber > anchor }) ?? count
    }
}

private extension StoredRuntimeState {
    func sort(
        _ records: [AgentHistoryRecord],
        using sort: AgentHistorySort
    ) -> [AgentHistoryRecord] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .sequence(order):
                if lhs.sequenceNumber == rhs.sequenceNumber {
                    return lhs.createdAt < rhs.createdAt
                }
                return order == .ascending
                    ? lhs.sequenceNumber < rhs.sequenceNumber
                    : lhs.sequenceNumber > rhs.sequenceNumber

            case let .createdAt(order):
                if lhs.createdAt == rhs.createdAt {
                    return lhs.sequenceNumber < rhs.sequenceNumber
                }
                return order == .ascending
                    ? lhs.createdAt < rhs.createdAt
                    : lhs.createdAt > rhs.createdAt
            }
        }
    }

    func page(
        _ records: [AgentHistoryRecord],
        threadID: String,
        with page: AgentQueryPage?,
        sort: AgentHistorySort
    ) throws -> AgentHistoryQueryResult {
        guard let page else {
            let ordered = normalizePageRecords(records, sort: sort)
            return AgentHistoryQueryResult(
                threadID: threadID,
                records: ordered,
                nextCursor: nil,
                previousCursor: nil,
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        let limit = max(1, page.limit)
        let anchor = try page.cursor?.decodedSequenceNumber(expectedThreadID: threadID)
        let ascending = normalizePageRecords(records, sort: sort)
        let endIndex = if let anchor {
            ascending.firstIndex(where: { $0.sequenceNumber >= anchor }) ?? ascending.count
        } else {
            ascending.count
        }
        let startIndex = max(0, endIndex - limit)
        let sliced = Array(ascending[startIndex ..< endIndex])
        return AgentHistoryQueryResult(
            threadID: threadID,
            records: sliced,
            nextCursor: startIndex > 0 ? AgentHistoryCursor(threadID: threadID, sequenceNumber: sliced.first?.sequenceNumber) : nil,
            previousCursor: endIndex < ascending.count ? AgentHistoryCursor(threadID: threadID, sequenceNumber: sliced.last?.sequenceNumber) : nil,
            hasMoreBefore: startIndex > 0,
            hasMoreAfter: endIndex < ascending.count
        )
    }

    func normalizePageRecords(
        _ records: [AgentHistoryRecord],
        sort: AgentHistorySort
    ) -> [AgentHistoryRecord] {
        switch sort {
        case .sequence(.ascending), .createdAt(.ascending):
            return records
        case .sequence(.descending), .createdAt(.descending):
            return records.reversed()
        }
    }

    func sort(
        _ threads: [AgentThread],
        using sort: AgentThreadMetadataSort
    ) -> [AgentThread] {
        threads.sorted { lhs, rhs in
            switch sort {
            case let .updatedAt(order):
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return order == .ascending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
            case let .createdAt(order):
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id < rhs.id
                }
                return order == .ascending ? lhs.createdAt < rhs.createdAt : lhs.createdAt > rhs.createdAt
            }
        }
    }

    func sort(
        _ records: [AgentPendingStateRecord],
        using sort: AgentPendingStateSort
    ) -> [AgentPendingStateRecord] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .updatedAt(order):
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    func sort(
        _ records: [AgentStructuredOutputRecord],
        using sort: AgentStructuredOutputSort
    ) -> [AgentStructuredOutputRecord] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .committedAt(order):
                if lhs.committedAt == rhs.committedAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.committedAt < rhs.committedAt : lhs.committedAt > rhs.committedAt
            }
        }
    }

    func sort(
        _ records: [AgentThreadSnapshot],
        using sort: AgentThreadSnapshotSort
    ) -> [AgentThreadSnapshot] {
        records.sorted { lhs, rhs in
            switch sort {
            case let .updatedAt(order):
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
            case let .createdAt(order):
                if lhs.createdAt == rhs.createdAt {
                    return lhs.threadID < rhs.threadID
                }
                return order == .ascending ? lhs.createdAt < rhs.createdAt : lhs.createdAt > rhs.createdAt
            }
        }
    }
}

private struct AgentHistoryCursorPayload: Codable {
    let version: Int
    let threadID: String
    let sequenceNumber: Int
}

private extension AgentHistoryCursor {
    init(threadID: String, sequenceNumber: Int?) {
        guard let sequenceNumber else {
            self.init(rawValue: "")
            return
        }

        let payload = AgentHistoryCursorPayload(
            version: 1,
            threadID: threadID,
            sequenceNumber: sequenceNumber
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        self.init(rawValue: base64)
    }

    func decodedSequenceNumber(expectedThreadID: String) throws -> Int {
        let padded = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        let adjusted = padded + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)

        guard let data = Data(base64Encoded: adjusted) else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }

        let payload = try JSONDecoder().decode(AgentHistoryCursorPayload.self, from: data)
        guard payload.threadID == expectedThreadID else {
            throw AgentRuntimeError.invalidHistoryCursor()
        }
        return payload.sequenceNumber
    }
}
