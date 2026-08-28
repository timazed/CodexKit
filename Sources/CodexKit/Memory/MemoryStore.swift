import Foundation

public protocol MemoryStoring: Sendable {
    /// Performs any schema migration or database opening required by the store.
    /// Persistent adapters also call this lazily from their first operation.
    func prepare() async throws
    func put(_ record: MemoryRecord) async throws
    func putMany(_ records: [MemoryRecord]) async throws
    func upsert(_ record: MemoryRecord, dedupeKey: String) async throws
    func query(_ query: MemoryQuery) async throws -> MemoryQueryResult
    func record(id: String, namespace: String) async throws -> MemoryRecord?
    func list(_ query: MemoryRecordListQuery) async throws -> [MemoryRecord]
    func diagnostics(namespace: String) async throws -> MemoryStoreDiagnostics
    func compact(_ request: MemoryCompactionRequest) async throws
    func archive(ids: [String], namespace: String) async throws
    func delete(ids: [String], namespace: String) async throws

    @discardableResult
    func pruneExpired(
        now: Date,
        namespace: String
    ) async throws -> Int
}

public extension MemoryStoring {
    func prepare() async throws {}

    func list(
        namespace: String,
        scopes: [MemoryScope] = [],
        categories: [String] = [],
        includeArchived: Bool = false,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> [MemoryRecord] {
        try await list(
            MemoryRecordListQuery(
                namespace: namespace,
                scopes: scopes,
                categories: categories,
                includeArchived: includeArchived,
                limit: limit,
                offset: offset
            )
        )
    }

    @discardableResult
    func pruneExpired(namespace: String) async throws -> Int {
        try await pruneExpired(now: Date(), namespace: namespace)
    }
}
