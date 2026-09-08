import CodexKit
import Foundation
import RealmSwift

// Transaction logic owns only values passed in by the store. Keeping actor state
// out of Realm's synchronous write closure also supports Swift 6.1's isolation checks.
struct RealmRuntimeStateWriter {
    let codec: RealmRuntimeStateStoreCodec
    private(set) var decodedHistoryRecordCount = 0

    mutating func applyIncrementally(
        _ operations: [AgentStoreWriteOperation],
        codec writeCodec: RealmRuntimeStateStoreCodec,
        in realm: Realm
    ) throws {
        var attachmentCleanup = Set<String>()
        let explicitlyUpdatedSummaryThreadIDs = Set(operations.compactMap { operation -> String? in
            guard case let .upsertSummary(threadID, _) = operation else { return nil }
            return threadID
        })

        // Threads are persisted first so the rest of the batch has the same
        // foreign-key-like semantics as the SQLite adapter.
        for operation in operations {
            guard case let .upsertThread(thread) = operation else { continue }
            let nextSequence = realm.object(
                ofType: RealmRuntimeThreadObject.self,
                forPrimaryKey: thread.id
            )?.nextHistorySequence ?? 1
            realm.add(
                try writeCodec.makeThreadObject(
                    from: thread,
                    nextHistorySequence: nextSequence
                ),
                update: .modified
            )

            let current: AgentThreadSummary
            if let summaryObject = realm.object(
                ofType: RealmRuntimeSummaryObject.self,
                forPrimaryKey: thread.id
            ) {
                let summary = try codec.decodeSummary(from: summaryObject)
                current = AgentThreadSummary(
                    threadID: summary.threadID,
                    createdAt: thread.createdAt,
                    updatedAt: thread.updatedAt,
                    latestItemAt: summary.latestItemAt,
                    itemCount: summary.itemCount,
                    latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                    latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                    latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                    latestToolState: summary.latestToolState,
                    latestTurnStatus: summary.latestTurnStatus,
                    pendingState: summary.pendingState
                )
            } else {
                current = StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
            }
            realm.add(try writeCodec.makeSummaryObject(from: current), update: .modified)
        }

        for operation in operations {
            switch operation {
            case .upsertThread:
                continue

            case let .upsertSummary(_, summary):
                realm.add(try writeCodec.makeSummaryObject(from: summary), update: .modified)

            case let .appendHistoryItems(threadID, items):
                try appendHistoryItems(items, to: threadID, codec: writeCodec, in: realm)
                if !explicitlyUpdatedSummaryThreadIDs.contains(threadID) {
                    try updateSummaryAfterAppending(items, threadID: threadID, in: realm)
                }

            case let .restoreHistoryItems(threadID, items):
                try appendHistoryItems(
                    items,
                    to: threadID,
                    allowInitialSequenceGap: true,
                    codec: writeCodec,
                    in: realm
                )
                if !explicitlyUpdatedSummaryThreadIDs.contains(threadID) {
                    try updateSummaryAfterAppending(items, threadID: threadID, in: realm)
                }

            case let .appendCompactionMarker(threadID, marker):
                try appendHistoryItems([marker], to: threadID, codec: writeCodec, in: realm)
                if !explicitlyUpdatedSummaryThreadIDs.contains(threadID) {
                    try updateSummaryAfterAppending([marker], threadID: threadID, in: realm)
                }

            case let .upsertThreadContextState(threadID, state):
                let previousObject = realm.object(
                    ofType: RealmRuntimeContextObject.self,
                    forPrimaryKey: threadID
                )
                let previousStorageKeys = try RealmRuntimeAttachmentReferences.storageKeys(
                    ownerType: "context",
                    ownerKey: threadID,
                    in: realm
                )
                if let state {
                    let object = try writeCodec.makeContextObject(from: state)
                    let newStorageKeys = try writeCodec.attachmentStorageKeys(from: object)
                    realm.add(object, update: .modified)
                    RealmRuntimeAttachmentReferences.replace(
                        ownerType: "context",
                        ownerKey: threadID,
                        threadID: threadID,
                        storageKeys: newStorageKeys,
                        in: realm
                    )
                    attachmentCleanup.formUnion(previousStorageKeys.subtracting(newStorageKeys))
                } else {
                    if let previousObject {
                        realm.delete(previousObject)
                    }
                    RealmRuntimeAttachmentReferences.delete(ownerType: "context", ownerKey: threadID, in: realm)
                    attachmentCleanup.formUnion(previousStorageKeys)
                }

            case let .deleteThreadContextState(threadID):
                if let object = realm.object(
                    ofType: RealmRuntimeContextObject.self,
                    forPrimaryKey: threadID
                ) {
                    attachmentCleanup.formUnion(try RealmRuntimeAttachmentReferences.storageKeys(
                        ownerType: "context",
                        ownerKey: threadID,
                        in: realm
                    ))
                    realm.delete(object)
                    RealmRuntimeAttachmentReferences.delete(ownerType: "context", ownerKey: threadID, in: realm)
                }

            case let .setPendingState(threadID, pendingState):
                try updateSummary(threadID: threadID, in: realm) { summary in
                    AgentThreadSummary(
                        threadID: summary.threadID,
                        createdAt: summary.createdAt,
                        updatedAt: summary.updatedAt,
                        latestItemAt: summary.latestItemAt,
                        itemCount: summary.itemCount,
                        latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                        latestToolState: summary.latestToolState,
                        latestTurnStatus: summary.latestTurnStatus,
                        pendingState: pendingState
                    )
                }

            case let .setPartialStructuredSnapshot(threadID, snapshot):
                try updateSummary(threadID: threadID, in: realm) { summary in
                    AgentThreadSummary(
                        threadID: summary.threadID,
                        createdAt: summary.createdAt,
                        updatedAt: summary.updatedAt,
                        latestItemAt: summary.latestItemAt,
                        itemCount: summary.itemCount,
                        latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: snapshot,
                        latestToolState: summary.latestToolState,
                        latestTurnStatus: summary.latestTurnStatus,
                        pendingState: summary.pendingState
                    )
                }

            case let .upsertToolSession(threadID, session):
                try updateSummary(threadID: threadID, in: realm) { summary in
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
                    return AgentThreadSummary(
                        threadID: summary.threadID,
                        createdAt: summary.createdAt,
                        updatedAt: summary.updatedAt,
                        latestItemAt: summary.latestItemAt,
                        itemCount: summary.itemCount,
                        latestAssistantMessagePreview: summary.latestAssistantMessagePreview,
                        latestStructuredOutputMetadata: summary.latestStructuredOutputMetadata,
                        latestPartialStructuredOutput: summary.latestPartialStructuredOutput,
                        latestToolState: latestToolState,
                        latestTurnStatus: summary.latestTurnStatus,
                        pendingState: .toolWait(AgentPendingToolWaitState(
                            invocationID: session.invocationID,
                            turnID: session.turnID,
                            toolName: session.toolName,
                            startedAt: session.updatedAt,
                            sessionID: session.sessionID,
                            sessionStatus: session.sessionStatus,
                            metadata: session.metadata,
                            resumable: session.resumable
                        ))
                    )
                }

            case let .redactHistoryItems(threadID, itemIDs, reason):
                let storageKeys = try redactHistoryItems(
                    itemIDs,
                    in: threadID,
                    reason: reason,
                    codec: writeCodec,
                    realm: realm
                )
                attachmentCleanup.formUnion(storageKeys)

            case let .deleteThread(threadID):
                deletePersistedThread(threadID, from: realm)
            }
        }
        RealmRuntimeAttachmentReferences.enqueueCleanup(attachmentCleanup, in: realm)
    }

    func appendHistoryItems(
        _ items: [AgentHistoryRecord],
        to threadID: String,
        allowInitialSequenceGap: Bool = false,
        codec writeCodec: RealmRuntimeStateStoreCodec,
        in realm: Realm
    ) throws {
        guard !items.isEmpty else { return }
        guard let thread = realm.object(
            ofType: RealmRuntimeThreadObject.self,
            forPrimaryKey: threadID
        ) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        let expectedSequence = thread.nextHistorySequence
        let relationshipPairs = items.compactMap { record -> String? in
            guard let relationshipKey = record.item.relationshipKey else { return nil }
            return "r\(relationshipKey.utf8.count):\(relationshipKey)k\(record.item.kind.rawValue)"
        }
        guard Set(relationshipPairs).count == relationshipPairs.count else {
            throw AgentStoreError.invalidInput(
                "a history write contains a duplicate relationship member"
            )
        }
        let relationshipKeys = Set(items.compactMap(\.item.relationshipKey))
        if !relationshipKeys.isEmpty {
            let kinds = Set(items.map { $0.item.kind.rawValue })
            let existing = Array(realm.objects(RealmRuntimeHistoryObject.self)
                .filter(
                    "threadID == %@ AND relationshipKey IN %@ AND kind IN %@",
                    threadID,
                    Array(relationshipKeys),
                    Array(kinds)
                )
                .prefix(items.count * 2 + 1))
            guard existing.count <= items.count * 2 else {
                throw AgentStoreError.invalidInput(
                    "stored history relationships exceed their bounded cardinality"
                )
            }
            let existingPairs = Set(existing.map {
                "r\(($0.relationshipKey ?? "").utf8.count):\($0.relationshipKey ?? "")k\($0.kind)"
            })
            guard existingPairs.isDisjoint(with: relationshipPairs) else {
                throw AgentStoreError.invalidInput(
                    "a stored history relationship already contains this member"
                )
            }
        }
        try AgentHistoryWriteValidator.validate(
            items,
            threadID: threadID,
            existingLastSequence: expectedSequence == 1 ? nil : expectedSequence - 1,
            threadExists: true,
            allowInitialSequenceGap: allowInitialSequenceGap
        )
        for record in items {
            let object = try writeCodec.makeHistoryObject(from: record, threadID: threadID)
            realm.add(object)
            RealmRuntimeAttachmentReferences.replace(
                ownerType: "history",
                ownerKey: object.key,
                threadID: threadID,
                storageKeys: try writeCodec.attachmentStorageKeys(from: object),
                in: realm
            )
            if let structured = try writeCodec.makeStructuredOutputObject(
                from: record,
                historyKey: object.key
            ) {
                realm.add(structured, update: .modified)
            }
        }
        thread.nextHistorySequence = try AgentHistorySequence.next(
            after: items.last?.sequenceNumber,
            threadID: threadID
        )
    }

    func updateSummary(
        threadID: String,
        in realm: Realm,
        transform: (AgentThreadSummary) throws -> AgentThreadSummary
    ) throws {
        guard let threadObject = realm.object(
            ofType: RealmRuntimeThreadObject.self,
            forPrimaryKey: threadID
        ) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        let thread = try codec.decodeThread(from: threadObject)
        let current: AgentThreadSummary
        if let object = realm.object(
            ofType: RealmRuntimeSummaryObject.self,
            forPrimaryKey: threadID
        ) {
            current = try codec.decodeSummary(from: object)
        } else {
            current = StoredRuntimeState(threads: [thread]).threadSummaryFallback(for: thread)
        }
        realm.add(try codec.makeSummaryObject(from: try transform(current)), update: .modified)
    }

    func updateSummaryAfterAppending(
        _ items: [AgentHistoryRecord],
        threadID: String,
        in realm: Realm
    ) throws {
        guard !items.isEmpty else { return }
        guard let threadObject = realm.object(
            ofType: RealmRuntimeThreadObject.self,
            forPrimaryKey: threadID
        ) else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        let thread = try codec.decodeThread(from: threadObject)
        try updateSummary(threadID: threadID, in: realm) { current in
            let projected = StoredRuntimeStateProjectionBuilder().rebuildSummary(
                for: thread,
                history: items,
                existing: current
            )
            return AgentThreadSummary(
                threadID: projected.threadID,
                createdAt: projected.createdAt,
                updatedAt: projected.updatedAt,
                latestItemAt: items.last?.createdAt ?? current.latestItemAt,
                itemCount: try AgentCounter.adding(
                    items.count,
                    to: current.itemCount ?? 0,
                    field: "history item count",
                    threadID: threadID
                ),
                latestAssistantMessagePreview: projected.latestAssistantMessagePreview,
                latestStructuredOutputMetadata: projected.latestStructuredOutputMetadata,
                latestPartialStructuredOutput: projected.latestPartialStructuredOutput,
                latestToolState: projected.latestToolState,
                latestTurnStatus: projected.latestTurnStatus,
                pendingState: projected.pendingState
            )
        }
    }

    mutating func redactHistoryItems(
        _ itemIDs: [String],
        in threadID: String,
        reason: AgentRedactionReason?,
        codec writeCodec: RealmRuntimeStateStoreCodec,
        realm: Realm
    ) throws -> Set<String> {
        guard !itemIDs.isEmpty else { return [] }
        let matches = realm.objects(RealmRuntimeHistoryObject.self)
            .filter("threadID == %@ AND recordID IN %@", threadID, itemIDs)
        guard matches.count <= AgentStoreLimits.maximumRedactionMatchCount else {
            throw AgentStoreError.invalidInput(
                "a redaction matches more than \(AgentStoreLimits.maximumRedactionMatchCount) history records"
            )
        }
        let objects = Array(matches)
        let ownerKeys = objects.map(\.key)
        let referenceLimit = AgentStoreLimits.maximumRedactionMatchCount
            * AgentStoreLimits.maximumImageCountPerMessage + 1
        let attachmentReferences = realm.objects(RealmRuntimeAttachmentReferenceObject.self)
            .filter("ownerType == %@ AND ownerKey IN %@", "history", ownerKeys)
        guard attachmentReferences.count < referenceLimit else {
            throw AgentStoreError.invalidInput(
                "stored redaction attachments exceed their bounded limit"
            )
        }
        var attachmentStorageKeys = Set(attachmentReferences.map(\.storageKey))
        var payloadByteCount = 0
        for object in objects {
            try AgentStoreLimitValidator.accumulateMaterializedPayload(
                object.encodedRecord,
                name: "redaction",
                total: &payloadByteCount
            )
            let redacted = try codec.decodeHistoryRecordForProjection(from: object).redacted(reason: reason)
            decodedHistoryRecordCount += 1
            let redactedObject = try writeCodec.makeHistoryObject(from: redacted, threadID: threadID)
            realm.add(redactedObject, update: .modified)
            RealmRuntimeAttachmentReferences.replace(
                ownerType: "history",
                ownerKey: redactedObject.key,
                threadID: threadID,
                storageKeys: try writeCodec.attachmentStorageKeys(from: redactedObject),
                in: realm
            )
            if let structured = realm.object(
                ofType: RealmRuntimeStructuredOutputObject.self,
                forPrimaryKey: object.key
            ) {
                realm.delete(structured)
            }
        }
        if let context = realm.object(
            ofType: RealmRuntimeContextObject.self,
            forPrimaryKey: threadID
        ) {
            attachmentStorageKeys.formUnion(try RealmRuntimeAttachmentReferences.storageKeys(
                ownerType: "context",
                ownerKey: threadID,
                in: realm
            ))
            realm.delete(context)
            RealmRuntimeAttachmentReferences.delete(ownerType: "context", ownerKey: threadID, in: realm)
        }
        try rebuildSummary(threadID: threadID, in: realm)
        return attachmentStorageKeys
    }

    mutating func rebuildSummary(threadID: String, in realm: Realm) throws {
        guard let threadObject = realm.object(
            ofType: RealmRuntimeThreadObject.self,
            forPrimaryKey: threadID
        ) else { return }
        let thread = try codec.decodeThread(from: threadObject)
        let existing = try realm.object(
            ofType: RealmRuntimeSummaryObject.self,
            forPrimaryKey: threadID
        ).map(codec.decodeSummary)
        let historyObjects = realm.objects(RealmRuntimeHistoryObject.self)
            .where { $0.threadID == threadID }
        var latestObjects: [String: RealmRuntimeHistoryObject] = [:]
        let candidates = [
            historyObjects
                .filter(
                    "kind == %@ AND messageRole == %@",
                    AgentHistoryItemKind.message.rawValue,
                    AgentRole.assistant.rawValue
                )
                .sorted(byKeyPath: "sequenceNumber", ascending: false)
                .first,
            historyObjects
                .filter("hasStructuredOutput == true")
                .sorted(byKeyPath: "sequenceNumber", ascending: false)
                .first,
            historyObjects
                .filter(
                    "kind IN %@",
                    [
                        AgentHistoryItemKind.toolCall.rawValue,
                        AgentHistoryItemKind.toolResult.rawValue,
                    ]
                )
                .sorted(byKeyPath: "sequenceNumber", ascending: false)
                .first,
            historyObjects
                .filter(
                    "kind == %@ AND systemEventType IN %@",
                    AgentHistoryItemKind.systemEvent.rawValue,
                    [
                        AgentSystemEventType.turnStarted.rawValue,
                        AgentSystemEventType.turnCompleted.rawValue,
                        AgentSystemEventType.turnFailed.rawValue,
                        AgentSystemEventType.turnInterrupted.rawValue,
                    ]
                )
                .sorted(byKeyPath: "sequenceNumber", ascending: false)
                .first,
        ]
        for object in candidates.compactMap({ $0 }) {
            latestObjects[object.key] = object
        }
        let history = try latestObjects.values
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map(codec.decodeHistoryRecordForProjection)
        decodedHistoryRecordCount += history.count
        let baseline = AgentThreadSummary(
            threadID: thread.id,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt,
            latestItemAt: nil,
            itemCount: nil,
            latestAssistantMessagePreview: nil,
            latestStructuredOutputMetadata: nil,
            latestPartialStructuredOutput: existing?.latestPartialStructuredOutput,
            latestToolState: nil,
            latestTurnStatus: nil,
            pendingState: existing?.pendingState
        )
        let projected = StoredRuntimeStateProjectionBuilder().rebuildSummary(
            for: thread,
            history: history,
            existing: baseline
        )
        let summary = AgentThreadSummary(
            threadID: projected.threadID,
            createdAt: projected.createdAt,
            updatedAt: projected.updatedAt,
            latestItemAt: historyObjects.max(of: \.createdAt),
            itemCount: historyObjects.count,
            latestAssistantMessagePreview: projected.latestAssistantMessagePreview,
            latestStructuredOutputMetadata: projected.latestStructuredOutputMetadata,
            latestPartialStructuredOutput: projected.latestPartialStructuredOutput,
            latestToolState: projected.latestToolState,
            latestTurnStatus: projected.latestTurnStatus,
            pendingState: projected.pendingState
        )
        realm.add(try codec.makeSummaryObject(from: summary), update: .modified)
    }

    func deletePersistedThread(_ threadID: String, from realm: Realm) {
        let deletion = RealmRuntimeDeletedThreadAttachmentObject()
        deletion.threadID = threadID
        realm.add(deletion, update: .modified)
        if let thread = realm.object(ofType: RealmRuntimeThreadObject.self, forPrimaryKey: threadID) {
            realm.delete(thread)
        }
        if let summary = realm.object(ofType: RealmRuntimeSummaryObject.self, forPrimaryKey: threadID) {
            realm.delete(summary)
        }
        if let context = realm.object(ofType: RealmRuntimeContextObject.self, forPrimaryKey: threadID) {
            realm.delete(context)
        }
        realm.delete(
            realm.objects(RealmRuntimeHistoryObject.self)
                .where { $0.threadID == threadID }
        )
        realm.delete(
            realm.objects(RealmRuntimeStructuredOutputObject.self)
                .where { $0.threadID == threadID }
        )
    }

}
