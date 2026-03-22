import Foundation

public protocol MemoryStoring: Sendable {
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
    func list(
        namespace: String,
        scopes: [MemoryScope] = [],
        kinds: [String] = [],
        includeArchived: Bool = false,
        limit: Int? = nil
    ) async throws -> [MemoryRecord] {
        try await list(
            MemoryRecordListQuery(
                namespace: namespace,
                scopes: scopes,
                kinds: kinds,
                includeArchived: includeArchived,
                limit: limit
            )
        )
    }

    @discardableResult
    func pruneExpired(namespace: String) async throws -> Int {
        try await pruneExpired(now: Date(), namespace: namespace)
    }
}
