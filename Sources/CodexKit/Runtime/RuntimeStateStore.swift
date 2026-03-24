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
