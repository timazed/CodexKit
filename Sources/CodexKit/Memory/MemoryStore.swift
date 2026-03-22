import Foundation

public protocol MemoryStoring: Sendable {
    func put(_ record: MemoryRecord) async throws
    func putMany(_ records: [MemoryRecord]) async throws
    func upsert(_ record: MemoryRecord, dedupeKey: String) async throws
    func query(_ query: MemoryQuery) async throws -> MemoryQueryResult
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
    @discardableResult
    func pruneExpired(namespace: String) async throws -> Int {
        try await pruneExpired(now: Date(), namespace: namespace)
    }
}
