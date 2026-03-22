import Foundation

public enum MemoryAuthoringError: Error, LocalizedError, Equatable, Sendable {
    case missingNamespace
    case missingScope
    case missingKind
    case missingDedupeKey

    public var errorDescription: String? {
        switch self {
        case .missingNamespace:
            return "A memory namespace is required before writing memory."
        case .missingScope:
            return "A memory scope is required before writing memory."
        case .missingKind:
            return "A memory kind is required before writing memory."
        case .missingDedupeKey:
            return "A dedupe key is required for memory upserts."
        }
    }
}

public struct MemoryDraft: Codable, Hashable, Sendable {
    public var id: String?
    public var namespace: String?
    public var scope: MemoryScope?
    public var kind: String?
    public var summary: String
    public var evidence: [String]
    public var importance: Double?
    public var createdAt: Date?
    public var observedAt: Date?
    public var expiresAt: Date?
    public var expiresIn: TimeInterval?
    public var tags: [String]
    public var relatedIDs: [String]
    public var dedupeKey: String?
    public var isPinned: Bool?
    public var attributes: JSONValue?
    public var status: MemoryRecordStatus?

    public init(
        id: String? = nil,
        namespace: String? = nil,
        scope: MemoryScope? = nil,
        kind: String? = nil,
        summary: String,
        evidence: [String] = [],
        importance: Double? = nil,
        createdAt: Date? = nil,
        observedAt: Date? = nil,
        expiresAt: Date? = nil,
        expiresIn: TimeInterval? = nil,
        tags: [String] = [],
        relatedIDs: [String] = [],
        dedupeKey: String? = nil,
        isPinned: Bool? = nil,
        attributes: JSONValue? = nil,
        status: MemoryRecordStatus? = nil
    ) {
        self.id = id
        self.namespace = namespace
        self.scope = scope
        self.kind = kind
        self.summary = summary
        self.evidence = evidence
        self.importance = importance
        self.createdAt = createdAt
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.expiresIn = expiresIn
        self.tags = tags
        self.relatedIDs = relatedIDs
        self.dedupeKey = dedupeKey
        self.isPinned = isPinned
        self.attributes = attributes
        self.status = status
    }
}

public struct MemoryWriterDefaults: Codable, Hashable, Sendable {
    public var namespace: String?
    public var scope: MemoryScope?
    public var kind: String?
    public var importance: Double
    public var tags: [String]
    public var relatedIDs: [String]
    public var isPinned: Bool
    public var status: MemoryRecordStatus

    public init(
        namespace: String? = nil,
        scope: MemoryScope? = nil,
        kind: String? = nil,
        importance: Double = 0,
        tags: [String] = [],
        relatedIDs: [String] = [],
        isPinned: Bool = false,
        status: MemoryRecordStatus = .active
    ) {
        self.namespace = namespace
        self.scope = scope
        self.kind = kind
        self.importance = importance
        self.tags = tags
        self.relatedIDs = relatedIDs
        self.isPinned = isPinned
        self.status = status
    }

    public func fillingMissingValues(from inherited: MemoryWriterDefaults) -> MemoryWriterDefaults {
        MemoryWriterDefaults(
            namespace: namespace ?? inherited.namespace,
            scope: scope ?? inherited.scope,
            kind: kind ?? inherited.kind,
            importance: importance,
            tags: Self.uniqueMerged(values: inherited.tags, with: tags),
            relatedIDs: Self.uniqueMerged(values: inherited.relatedIDs, with: relatedIDs),
            isPinned: isPinned,
            status: status
        )
    }

    fileprivate static func uniqueMerged(values base: [String], with override: [String]) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()

        for value in base + override {
            guard seen.insert(value).inserted else {
                continue
            }
            merged.append(value)
        }

        return merged
    }
}

public actor MemoryWriter {
    private let store: any MemoryStoring
    public let defaults: MemoryWriterDefaults

    public init(
        store: any MemoryStoring,
        defaults: MemoryWriterDefaults = .init()
    ) {
        self.store = store
        self.defaults = defaults
    }

    public nonisolated func resolve(
        _ draft: MemoryDraft,
        now: Date = Date()
    ) throws -> MemoryRecord {
        let namespace = try resolvedNamespace(for: draft)
        let scope = try resolvedScope(for: draft)
        let kind = try resolvedKind(for: draft)
        let createdAt = draft.createdAt ?? now
        let baseExpiryDate = draft.observedAt ?? createdAt
        let expiresAt = draft.expiresAt ?? draft.expiresIn.map { baseExpiryDate.addingTimeInterval($0) }

        return MemoryRecord(
            id: draft.id ?? UUID().uuidString,
            namespace: namespace,
            scope: scope,
            kind: kind,
            summary: draft.summary,
            evidence: draft.evidence,
            importance: draft.importance ?? defaults.importance,
            createdAt: createdAt,
            observedAt: draft.observedAt,
            expiresAt: expiresAt,
            tags: MemoryWriterDefaults.uniqueMerged(values: defaults.tags, with: draft.tags),
            relatedIDs: MemoryWriterDefaults.uniqueMerged(values: defaults.relatedIDs, with: draft.relatedIDs),
            dedupeKey: draft.dedupeKey,
            isPinned: draft.isPinned ?? defaults.isPinned,
            attributes: draft.attributes,
            status: draft.status ?? defaults.status
        )
    }

    @discardableResult
    public func put(
        _ draft: MemoryDraft,
        now: Date = Date()
    ) async throws -> MemoryRecord {
        let record = try resolve(draft, now: now)
        try await store.put(record)
        return record
    }

    @discardableResult
    public func putMany(
        _ drafts: [MemoryDraft],
        now: Date = Date()
    ) async throws -> [MemoryRecord] {
        let records = try drafts.map { try resolve($0, now: now) }
        try await store.putMany(records)
        return records
    }

    @discardableResult
    public func upsert(
        _ draft: MemoryDraft,
        now: Date = Date()
    ) async throws -> MemoryRecord {
        guard let dedupeKey = draft.dedupeKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dedupeKey.isEmpty
        else {
            throw MemoryAuthoringError.missingDedupeKey
        }

        var draft = draft
        draft.dedupeKey = dedupeKey
        let record = try resolve(draft, now: now)
        try await store.upsert(record, dedupeKey: dedupeKey)
        return record
    }

    @discardableResult
    public func compact(
        replacement draft: MemoryDraft,
        sourceIDs: [String],
        now: Date = Date()
    ) async throws -> MemoryRecord {
        let record = try resolve(draft, now: now)
        try await store.compact(
            MemoryCompactionRequest(
                replacement: record,
                sourceIDs: sourceIDs
            )
        )
        return record
    }

    public func diagnostics(namespace: String? = nil) async throws -> MemoryStoreDiagnostics {
        try await store.diagnostics(namespace: try resolvedNamespace(namespace))
    }

    public func list(
        namespace: String? = nil,
        scopes: [MemoryScope] = [],
        kinds: [String] = [],
        includeArchived: Bool = false,
        limit: Int? = nil
    ) async throws -> [MemoryRecord] {
        try await store.list(
            namespace: try resolvedNamespace(namespace),
            scopes: scopes,
            kinds: kinds,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    public func archive(
        ids: [String],
        namespace: String? = nil
    ) async throws {
        try await store.archive(ids: ids, namespace: try resolvedNamespace(namespace))
    }

    public func delete(
        ids: [String],
        namespace: String? = nil
    ) async throws {
        try await store.delete(ids: ids, namespace: try resolvedNamespace(namespace))
    }

    @discardableResult
    public func pruneExpired(
        now: Date = Date(),
        namespace: String? = nil
    ) async throws -> Int {
        try await store.pruneExpired(
            now: now,
            namespace: try resolvedNamespace(namespace)
        )
    }

    private nonisolated func resolvedNamespace(for draft: MemoryDraft) throws -> String {
        try resolvedNamespace(draft.namespace)
    }

    private nonisolated func resolvedNamespace(_ namespace: String?) throws -> String {
        guard let namespace = (namespace ?? defaults.namespace)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !namespace.isEmpty
        else {
            throw MemoryAuthoringError.missingNamespace
        }

        return namespace
    }

    private nonisolated func resolvedScope(for draft: MemoryDraft) throws -> MemoryScope {
        guard let scope = draft.scope ?? defaults.scope else {
            throw MemoryAuthoringError.missingScope
        }
        return scope
    }

    private nonisolated func resolvedKind(for draft: MemoryDraft) throws -> String {
        guard let kind = (draft.kind ?? defaults.kind)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kind.isEmpty
        else {
            throw MemoryAuthoringError.missingKind
        }

        return kind
    }
}
