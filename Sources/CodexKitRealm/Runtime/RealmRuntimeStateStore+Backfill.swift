import CodexKit
import RealmSwift

extension RealmRuntimeStateStore {
    private static var queryProjectionBackfillBatchSize: Int { 4 }

    func backfillQueryProjectionsInBatches(in realm: Realm) async throws {
        try await realm.asyncWrite(_isolation: self) {
            realm.delete(realm.objects(RealmRuntimeAttachmentReferenceObject.self))
        }
        try await backfillThreads(in: realm)
        try await backfillSummaries(in: realm)
        try await backfillContexts(in: realm)
        try await backfillHistory(in: realm)
    }

    private func backfillThreads(in realm: Realm) async throws {
        var cursor: String?
        while true {
            var objects = realm.objects(RealmRuntimeThreadObject.self)
            if let cursor { objects = objects.filter("id > %@", cursor) }
            let ids = Array(objects.sorted(byKeyPath: "id")
                .prefix(Self.queryProjectionBackfillBatchSize)
                .map(\.id))
            guard !ids.isEmpty else { return }
            try await realm.asyncWrite(_isolation: self) {
                for id in ids {
                    guard let object = realm.object(
                        ofType: RealmRuntimeThreadObject.self,
                        forPrimaryKey: id
                    ) else { continue }
                    let lastSequence = realm.objects(RealmRuntimeHistoryObject.self)
                        .filter("threadID == %@", id)
                        .sorted(byKeyPath: "sequenceNumber", ascending: false)
                        .first?
                        .sequenceNumber
                    object.nextHistorySequence = AgentHistorySequence.nextOrMaximum(
                        after: lastSequence
                    )
                }
            }
            cursor = ids.last
        }
    }

    private func backfillSummaries(in realm: Realm) async throws {
        var cursor: String?
        while true {
            var objects = realm.objects(RealmRuntimeSummaryObject.self)
            if let cursor { objects = objects.filter("threadID > %@", cursor) }
            let ids = Array(objects.sorted(byKeyPath: "threadID")
                .prefix(Self.queryProjectionBackfillBatchSize)
                .map(\.threadID))
            guard !ids.isEmpty else { return }
            try await realm.asyncWrite(_isolation: self) { [codec] in
                var payloadByteCount = 0
                for id in ids {
                    guard let object = realm.object(
                        ofType: RealmRuntimeSummaryObject.self,
                        forPrimaryKey: id
                    ) else { continue }
                    try AgentStoreLimitValidator.accumulateMaterializedPayload(
                        object.encodedSummary,
                        name: "summary projection backfill",
                        total: &payloadByteCount
                    )
                    let summary = try codec.decodeSummary(from: object)
                    object.createdAt = summary.createdAt
                    object.updatedAt = summary.updatedAt
                    object.pendingStateKind = summary.pendingState?.kind.rawValue
                }
            }
            cursor = ids.last
        }
    }

    private func backfillContexts(in realm: Realm) async throws {
        var cursor: String?
        while true {
            var objects = realm.objects(RealmRuntimeContextObject.self)
            if let cursor { objects = objects.filter("threadID > %@", cursor) }
            let ids = Array(objects.sorted(byKeyPath: "threadID")
                .prefix(Self.queryProjectionBackfillBatchSize)
                .map(\.threadID))
            guard !ids.isEmpty else { return }
            try await realm.asyncWrite(_isolation: self) { [codec] in
                var payloadByteCount = 0
                for id in ids {
                    guard let object = realm.object(
                        ofType: RealmRuntimeContextObject.self,
                        forPrimaryKey: id
                    ) else { continue }
                    try AgentStoreLimitValidator.accumulateMaterializedPayload(
                        object.encodedState,
                        name: "context projection backfill",
                        total: &payloadByteCount
                    )
                    object.generation = try codec.decodeContextState(from: object).generation
                    RealmRuntimeAttachmentReferences.replace(
                        ownerType: .context,
                        ownerKey: object.threadID,
                        threadID: object.threadID,
                        storageKeys: try codec.attachmentStorageKeys(from: object),
                        in: realm
                    )
                }
            }
            cursor = ids.last
        }
    }

    private func backfillHistory(in realm: Realm) async throws {
        var cursor: String?
        while true {
            var objects = realm.objects(RealmRuntimeHistoryObject.self)
            if let cursor { objects = objects.filter("key > %@", cursor) }
            let keys = Array(objects.sorted(byKeyPath: "key")
                .prefix(Self.queryProjectionBackfillBatchSize)
                .map(\.key))
            guard !keys.isEmpty else { return }
            try await realm.asyncWrite(_isolation: self) { [codec] in
                var payloadByteCount = 0
                for key in keys {
                    guard let object = realm.object(
                        ofType: RealmRuntimeHistoryObject.self,
                        forPrimaryKey: key
                    ) else { continue }
                    try AgentStoreLimitValidator.accumulateMaterializedPayload(
                        object.encodedRecord,
                        name: "history projection backfill",
                        total: &payloadByteCount
                    )
                    let projection = try codec.projectedHistoryMetadata(from: object)
                    object.recordID = projection.recordID
                    object.turnID = projection.turnID
                    object.relationshipKey = projection.relationshipKey
                    object.isCompactionMarker = projection.isCompactionMarker
                    object.messageRole = projection.messageRole
                    object.hasStructuredOutput = projection.hasStructuredOutput
                    object.systemEventType = projection.systemEventType
                    RealmRuntimeAttachmentReferences.replace(
                        ownerType: .history,
                        ownerKey: object.key,
                        threadID: object.threadID,
                        storageKeys: try codec.attachmentStorageKeys(from: object),
                        in: realm
                    )
                    if let structuredOutput = projection.structuredOutput {
                        realm.add(
                            try codec.makeStructuredOutputObject(
                                from: structuredOutput,
                                historyKey: object.key
                            ),
                            update: .modified
                        )
                    }
                }
            }
            cursor = keys.last
        }
    }
}
