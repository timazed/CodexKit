import Foundation

extension MemoryQueryEngine {
    package static func validateNamespace(_ namespace: String) throws {
        guard !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              namespace.utf8.count <= MemoryStoreLimits.maximumIdentifierByteCount else {
            throw MemoryStoreError.invalidNamespace
        }
    }

    package static func validate(_ record: MemoryRecord) throws {
        try validateNamespace(record.namespace)
        try validateIdentifier(record.id, name: "id")
        try validateIdentifier(record.scope.rawValue, name: "scope")
        try validateIdentifier(record.category, name: "category")
        if let dedupeKey = record.dedupeKey {
            try validateIdentifier(dedupeKey, name: "dedupeKey")
        }
        guard record.summary.utf8.count <= MemoryStoreLimits.maximumSummaryByteCount else {
            throw MemoryStoreError.invalidRecord(
                "summary must not exceed \(MemoryStoreLimits.maximumSummaryByteCount) UTF-8 bytes."
            )
        }
        try validateCollection(
            record.evidence,
            name: "evidence",
            maximumCount: MemoryStoreLimits.maximumEvidenceCount
        )
        try validateCollection(
            record.tags,
            name: "tags",
            maximumCount: MemoryStoreLimits.maximumTagCount
        )
        try validateCollection(
            record.relatedIDs,
            name: "relatedIDs",
            maximumCount: MemoryStoreLimits.maximumRelatedIDCount
        )
        let searchableByteCount = ([record.summary, record.category] + record.evidence + record.tags)
            .reduce(0) { $0 + $1.utf8.count }
        guard searchableByteCount <= MemoryStoreLimits.maximumSearchableRecordByteCount else {
            throw MemoryStoreError.invalidRecord(
                "searchable text must not exceed \(MemoryStoreLimits.maximumSearchableRecordByteCount) UTF-8 bytes."
            )
        }
        if let attributes = record.attributes {
            try validateAttributes(attributes)
            let encoded = try JSONEncoder().encode(attributes)
            guard encoded.count <= MemoryStoreLimits.maximumAttributesByteCount else {
                throw MemoryStoreError.invalidRecord(
                    "attributes must not exceed \(MemoryStoreLimits.maximumAttributesByteCount) encoded bytes."
                )
            }
        }
        guard record.importance.isFinite, (0 ... 1).contains(record.importance) else {
            throw MemoryStoreError.invalidRecord("importance must be finite and between 0 and 1.")
        }
        let dates: [(String, Date?)] = [
            ("createdAt", record.createdAt),
            ("observedAt", record.observedAt),
            ("expiresAt", record.expiresAt),
        ]
        for (name, date) in dates where !(date?.timeIntervalSince1970.isFinite ?? true) {
            throw MemoryStoreError.invalidRecord("\(name) must be finite.")
        }
    }

    package static func validate(_ query: MemoryQuery) throws {
        try validateNamespace(query.namespace)
        if let text = query.text,
           text.utf8.prefix(MemoryStoreLimits.maximumQueryTextByteCount + 1).count
            > MemoryStoreLimits.maximumQueryTextByteCount {
            throw MemoryStoreError.invalidQuery(
                "query text must not exceed \(MemoryStoreLimits.maximumQueryTextByteCount) UTF-8 bytes."
            )
        }
        if let text = query.text {
            let tokens = tokenize(
                text,
                maximumTokenCount: MemoryStoreLimits.maximumQueryTokenCount + 1,
                maximumInputBytes: MemoryStoreLimits.maximumQueryTextByteCount
            )
            guard tokens.count <= MemoryStoreLimits.maximumQueryTokenCount else {
                throw MemoryStoreError.invalidQuery(
                    "query text must not contain more than \(MemoryStoreLimits.maximumQueryTokenCount) distinct tokens."
                )
            }
        }
        let filterValueCount = query.scopes.count + query.categories.count
            + query.tags.count + query.relatedIDs.count
        guard filterValueCount <= MemoryStoreLimits.maximumQueryFilterValueCount else {
            throw MemoryStoreError.invalidQuery(
                "combined scope, category, tag, and related-ID filters must not exceed \(MemoryStoreLimits.maximumQueryFilterValueCount) values."
            )
        }
        for scope in query.scopes {
            try validateIdentifier(scope.rawValue, name: "scope filter", query: true)
        }
        for category in query.categories {
            try validateIdentifier(category, name: "category filter", query: true)
        }
        for tag in query.tags {
            try validateIdentifier(tag, name: "tag filter", query: true)
        }
        for relatedID in query.relatedIDs {
            try validateIdentifier(relatedID, name: "related-ID filter", query: true)
        }
        if let cursor = query.cursor {
            guard cursor.namespace == query.namespace,
                  cursor.rankingProfile == query.ranking,
                  cursor.importance.isFinite,
                  (0 ... 1).contains(cursor.importance),
                  cursor.effectiveDate.timeIntervalSince1970.isFinite else {
                throw MemoryStoreError.invalidQuery(
                    "cursor does not match the query or contains invalid values."
                )
            }
            try validateIdentifier(cursor.recordID, name: "cursor recordID", query: true)
        }
        if let minImportance = query.minImportance,
           !(minImportance.isFinite && (0 ... 1).contains(minImportance)) {
            throw MemoryStoreError.invalidQuery("minImportance must be between 0 and 1.")
        }
        if let recencyWindow = query.recencyWindow,
           !(recencyWindow.isFinite && recencyWindow >= 0) {
            throw MemoryStoreError.invalidQuery("recencyWindow must be finite and nonnegative.")
        }
        guard query.limit >= 0 else {
            throw MemoryStoreError.invalidQuery("limit must be nonnegative.")
        }
        guard query.limit <= MemoryStoreLimits.maximumQueryResultCount else {
            throw MemoryStoreError.invalidQuery(
                "limit must not exceed \(MemoryStoreLimits.maximumQueryResultCount)."
            )
        }
        guard query.maxCharacters >= 0 else {
            throw MemoryStoreError.invalidQuery("maxCharacters must be nonnegative.")
        }
        if case let .atLeastTokens(count) = query.textMatchPolicy {
            guard count >= 1 else {
                throw MemoryStoreError.invalidQuery(
                    "text matching must require at least one token."
                )
            }
            guard count <= MemoryStoreLimits.maximumQueryTokenCount else {
                throw MemoryStoreError.invalidQuery(
                    "text matching must not require more than \(MemoryStoreLimits.maximumQueryTokenCount) tokens."
                )
            }
        }
    }

    package static func validate(_ request: MemoryCompactionRequest) throws {
        try validate(request.replacement)
        try validateBulkIdentifiers(request.sourceIDs, operation: "compaction")
        guard !request.sourceIDs.contains(request.replacement.id) else {
            throw MemoryStoreError.invalidCompaction(
                "replacement id must not also appear in sourceIDs."
            )
        }
    }

    package static func validate(_ query: MemoryRecordListQuery) throws {
        try validateNamespace(query.namespace)
        for scope in query.scopes {
            try validateIdentifier(scope.rawValue, name: "scope filter", query: true)
        }
        for category in query.categories {
            try validateIdentifier(category, name: "category filter", query: true)
        }
        guard (0 ... MemoryStoreLimits.maximumListOffset).contains(query.offset) else {
            throw MemoryStoreError.invalidQuery(
                "list offset must be between 0 and \(MemoryStoreLimits.maximumListOffset); use a cursor for larger scans."
            )
        }
        let limit = query.limit ?? MemoryStoreLimits.maximumListResultCount
        guard (0 ... MemoryStoreLimits.maximumListResultCount).contains(limit) else {
            throw MemoryStoreError.invalidQuery(
                "list limit must be between 0 and \(MemoryStoreLimits.maximumListResultCount)."
            )
        }
        guard query.scopes.count + query.categories.count <= MemoryStoreLimits.maximumQueryFilterValueCount else {
            throw MemoryStoreError.invalidQuery(
                "combined list filters must not exceed \(MemoryStoreLimits.maximumQueryFilterValueCount) values."
            )
        }
        guard query.cursor?.effectiveDate.timeIntervalSince1970.isFinite ?? true else {
            throw MemoryStoreError.invalidQuery("list cursor date must be finite.")
        }
        if let cursor = query.cursor {
            try validateIdentifier(cursor.recordID, name: "list cursor recordID", query: true)
        }
    }

    package static func validateBulkRecords(_ records: [MemoryRecord]) throws {
        guard records.count <= MemoryStoreLimits.maximumBulkRecordCount else {
            throw MemoryStoreError.invalidRecord(
                "bulk writes must not exceed \(MemoryStoreLimits.maximumBulkRecordCount) records."
            )
        }
        var collectionValueCount = 0
        var searchTokenCount = 0
        var encodedByteCount = 0
        for record in records {
            try validate(record)
            try accumulate(
                record.evidence.count + record.tags.count + record.relatedIDs.count,
                in: &collectionValueCount,
                limit: MemoryStoreLimits.maximumBulkCollectionValueCount,
                message: "bulk memory collections"
            )
            let searchableText = ([record.summary, record.category] + record.evidence + record.tags)
                .joined(separator: " ")
            try accumulate(
                tokenize(searchableText).count,
                in: &searchTokenCount,
                limit: MemoryStoreLimits.maximumBulkSearchTokenCount,
                message: "bulk memory search tokens"
            )
            var recordByteCount = record.id.utf8.count
                + record.namespace.utf8.count
                + record.scope.rawValue.utf8.count
                + record.category.utf8.count
                + record.summary.utf8.count
                + (record.dedupeKey?.utf8.count ?? 0)
            for value in record.evidence + record.tags + record.relatedIDs {
                try accumulate(
                    value.utf8.count,
                    in: &recordByteCount,
                    limit: MemoryStoreLimits.maximumBulkEncodedByteCount,
                    message: "a memory record"
                )
            }
            if let attributes = record.attributes {
                try accumulate(
                    JSONEncoder().encode(attributes).count,
                    in: &recordByteCount,
                    limit: MemoryStoreLimits.maximumBulkEncodedByteCount,
                    message: "a memory record"
                )
            }
            try accumulate(
                recordByteCount,
                in: &encodedByteCount,
                limit: MemoryStoreLimits.maximumBulkEncodedByteCount,
                message: "bulk memory data"
            )
        }
    }

    package static func validateBulkIdentifiers(
        _ ids: [String],
        operation: String
    ) throws {
        guard ids.count <= MemoryStoreLimits.maximumBulkIdentifierCount else {
            throw MemoryStoreError.invalidQuery(
                "\(operation) must not exceed \(MemoryStoreLimits.maximumBulkIdentifierCount) identifiers."
            )
        }
        for id in ids {
            try validateIdentifier(id, name: "\(operation) identifier", query: true)
        }
    }

    private static func validateIdentifier(
        _ value: String,
        name: String,
        query: Bool = false
    ) throws {
        let valid = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.utf8.count <= MemoryStoreLimits.maximumIdentifierByteCount
        guard valid else {
            let message = "\(name) must be nonempty and at most \(MemoryStoreLimits.maximumIdentifierByteCount) UTF-8 bytes."
            if query { throw MemoryStoreError.invalidQuery(message) }
            throw MemoryStoreError.invalidRecord(message)
        }
    }

    private static func validateCollection(
        _ values: [String],
        name: String,
        maximumCount: Int
    ) throws {
        guard values.count <= maximumCount else {
            throw MemoryStoreError.invalidRecord(
                "\(name) must not contain more than \(maximumCount) values."
            )
        }
        guard values.allSatisfy({
            $0.utf8.count <= MemoryStoreLimits.maximumCollectionValueByteCount
        }) else {
            throw MemoryStoreError.invalidRecord(
                "each \(name) value must not exceed \(MemoryStoreLimits.maximumCollectionValueByteCount) UTF-8 bytes."
            )
        }
    }

    private static func accumulate(
        _ value: Int,
        in total: inout Int,
        limit: Int,
        message: String
    ) throws {
        let (updated, overflow) = total.addingReportingOverflow(value)
        guard value >= 0, !overflow, updated <= limit else {
            throw MemoryStoreError.invalidRecord(
                "\(message) must not exceed its bounded limit of \(limit)."
            )
        }
        total = updated
    }

    private static func validateAttributes(_ root: JSONValue) throws {
        var stack: [(JSONValue, Int)] = [(root, 1)]
        var nodeCount = 0
        while let (value, depth) = stack.popLast() {
            nodeCount += 1
            guard depth <= MemoryStoreLimits.maximumAttributesDepth,
                  nodeCount <= MemoryStoreLimits.maximumAttributesNodeCount else {
                throw MemoryStoreError.invalidRecord(
                    "attributes must not exceed depth \(MemoryStoreLimits.maximumAttributesDepth) or \(MemoryStoreLimits.maximumAttributesNodeCount) values."
                )
            }
            switch value {
            case let .number(number):
                guard number.isFinite else {
                    throw MemoryStoreError.invalidRecord("attribute numbers must be finite.")
                }
            case let .object(object):
                for (key, child) in object {
                    guard key.utf8.count <= MemoryStoreLimits.maximumCollectionValueByteCount else {
                        throw MemoryStoreError.invalidRecord("attribute keys are too large.")
                    }
                    stack.append((child, depth + 1))
                }
            case let .array(array):
                for child in array { stack.append((child, depth + 1)) }
            case let .string(string):
                guard string.utf8.count <= MemoryStoreLimits.maximumAttributesByteCount else {
                    throw MemoryStoreError.invalidRecord("an attribute string is too large.")
                }
            case .bool, .null:
                break
            }
        }
    }
}
