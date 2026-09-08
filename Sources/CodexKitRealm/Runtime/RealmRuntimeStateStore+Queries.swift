import CodexKit
import Foundation
import RealmSwift

extension RealmRuntimeStateStore {
    func executeHistoryQuery(
        _ query: HistoryItemsQuery,
        in realm: Realm
    ) throws -> AgentHistoryQueryResult {
        guard realm.object(
            ofType: RealmRuntimeThreadObject.self,
            forPrimaryKey: query.threadID
        ) != nil else {
            return emptyHistoryQueryResult(threadID: query.threadID)
        }
        if let kinds = query.kinds, kinds.isEmpty {
            return emptyHistoryQueryResult(threadID: query.threadID)
        }

        var base = filteredHistory(
            in: realm,
            threadID: query.threadID,
            kinds: query.kinds,
            includeCompactionEvents: query.includeCompactionEvents
        )
        if let range = query.createdAtRange {
            base = base.filter(
                "createdAt >= %@ AND createdAt <= %@",
                range.lowerBound,
                range.upperBound
            )
        }
        if let turnID = query.turnID {
            base = base.filter("turnID == %@", turnID)
        }
        if let relationship = query.relationship {
            base = base.filter("relationshipKey == %@", relationship.storageKey)
        }
        if !query.includeRedacted {
            base = base.filter("isRedacted == false")
        }

        let page = query.page ?? AgentQueryPage(
            limit: AgentStoreLimits.defaultListResultCount
        )
        let limit = AgentStoreLimitValidator.boundedLimit(page.limit)
        let anchor = try page.cursor?.decodedHistoryQueryAnchor(
            expectedThreadID: query.threadID,
            sort: query.sort
        )
        if let anchor {
            guard let anchorObject = realm.object(ofType: RealmRuntimeHistoryObject.self,
                forPrimaryKey: RealmRuntimeStateStoreCodec.historyKey(
                    threadID: query.threadID, sequenceNumber: anchor.sequenceNumber)),
                anchorObject.threadID == query.threadID,
                anchorObject.sequenceNumber == anchor.sequenceNumber,
                anchorObject.createdAt == anchor.createdAt
            else {
                throw AgentRuntimeError.invalidHistoryCursor()
            }
        }
        if page.direction == .forward {
            var window = base
            if let anchor {
                window = try historyAfterAnchor(anchor, sort: query.sort, in: window)
            }
            let adjacent = unfilteredSequenceWindow(query, in: realm, anchor: anchor?.sequenceNumber,
                ascending: true, limit: agentOverfetchLimit(limit))
            let fetched: [RealmRuntimeHistoryObject]
            if let adjacent {
                fetched = adjacent
            } else {
                fetched = Array(sortHistory(window, using: query.sort, ascending: true)
                    .prefix(agentOverfetchLimit(limit)))
            }
            let pageObjects = Array(fetched.prefix(limit))
            let recordsAscending = try decodeHistory(pageObjects)
            let records = historySortOrder(query.sort) == .ascending
                ? recordsAscending
                : Array(recordsAscending.reversed())
            let hasMoreBefore = if let anchor {
                try historyExistsAtOrBeforeAnchor(anchor, sort: query.sort, in: base)
            } else {
                false
            }
            return AgentHistoryQueryResult(
                threadID: query.threadID,
                records: records,
                nextCursor: fetched.count > limit
                    ? AgentHistoryCursor(
                        threadID: query.threadID,
                        record: recordsAscending.last,
                        sort: query.sort
                    )
                    : nil,
                previousCursor: hasMoreBefore
                    ? AgentHistoryCursor(
                        threadID: query.threadID,
                        record: recordsAscending.first,
                        sort: query.sort
                    )
                    : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: fetched.count > limit
            )
        }
        var window = base
        if let anchor {
            window = try historyBeforeAnchor(
                anchor,
                sort: query.sort,
                in: window
            )
        }
        let adjacent = unfilteredSequenceWindow(query, in: realm, anchor: anchor?.sequenceNumber,
            ascending: false, limit: agentOverfetchLimit(limit))
        let fetched: [RealmRuntimeHistoryObject]
        if let adjacent {
            fetched = adjacent
        } else {
            fetched = Array(sortHistory(window, using: query.sort, ascending: false)
                .prefix(agentOverfetchLimit(limit)))
        }
        let pageObjects = Array(fetched.prefix(limit).reversed())
        let recordsAscending = try decodeHistory(pageObjects)
        let records = historySortOrder(query.sort) == .ascending
            ? recordsAscending
            : Array(recordsAscending.reversed())
        let hasMoreAfter = if let anchor {
            try historyExistsAtOrAfterAnchor(
                anchor,
                sort: query.sort,
                in: base
            )
        } else {
            false
        }
        return AgentHistoryQueryResult(
            threadID: query.threadID,
            records: records,
            nextCursor: fetched.count > limit
                ? AgentHistoryCursor(
                    threadID: query.threadID,
                    record: recordsAscending.first,
                    sort: query.sort
                )
                : nil,
            previousCursor: hasMoreAfter
                ? AgentHistoryCursor(
                    threadID: query.threadID,
                    record: recordsAscending.last,
                    sort: query.sort
                )
                : nil,
            hasMoreBefore: fetched.count > limit,
            hasMoreAfter: hasMoreAfter
        )
    }

    func executeThreadQuery(
        _ query: ThreadMetadataQuery,
        in realm: Realm
    ) throws -> [AgentThread] {
        if query.threadIDs?.isEmpty == true || query.statuses?.isEmpty == true {
            return []
        }
        var results = realm.objects(RealmRuntimeThreadObject.self)
        if let ids = query.threadIDs {
            results = results.filter("id IN %@", Array(ids))
        }
        if let statuses = query.statuses {
            results = results.filter("status IN %@", statuses.map(\.rawValue))
        }
        if let range = query.updatedAtRange {
            results = results.filter(
                "updatedAt >= %@ AND updatedAt <= %@",
                range.lowerBound,
                range.upperBound
            )
        }
        if let cursor = query.cursor {
            let keyPath: String
            let order: AgentSortOrder
            switch query.sort {
            case let .updatedAt(sortOrder):
                keyPath = "updatedAt"
                order = sortOrder
            case let .createdAt(sortOrder):
                keyPath = "createdAt"
                order = sortOrder
            }
            let comparison = order == .ascending ? ">" : "<"
            results = results.filter(
                "(%K \(comparison) %@) OR (%K == %@ AND id > %@)",
                keyPath,
                cursor.date,
                keyPath,
                cursor.date,
                cursor.threadID
            )
        }
        let sorted: Results<RealmRuntimeThreadObject>
        switch query.sort {
        case let .updatedAt(order):
            sorted = results.sorted(by: [
                SortDescriptor(keyPath: "updatedAt", ascending: order == .ascending),
                SortDescriptor(keyPath: "id", ascending: true),
            ])
        case let .createdAt(order):
            sorted = results.sorted(by: [
                SortDescriptor(keyPath: "createdAt", ascending: order == .ascending),
                SortDescriptor(keyPath: "id", ascending: true),
            ])
        }
        let objects = Array(sorted.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
        return try decodeBoundedRuntimeObjects(
            objects,
            name: "thread query",
            payload: \.encodedThread,
            decode: codec.decodeThread
        )
    }

    func executePendingStateQuery(
        _ query: PendingStateQuery,
        in realm: Realm
    ) throws -> [AgentPendingStateRecord] {
        if query.threadIDs?.isEmpty == true || query.kinds?.isEmpty == true {
            return []
        }
        var results = realm.objects(RealmRuntimeSummaryObject.self)
            .filter("pendingStateKind != nil")
        if let ids = query.threadIDs {
            results = results.filter("threadID IN %@", Array(ids))
        }
        if let kinds = query.kinds {
            results = results.filter("pendingStateKind IN %@", kinds.map(\.rawValue))
        }
        let ascending: Bool
        switch query.sort {
        case let .updatedAt(order): ascending = order == .ascending
        }
        let sorted = results.sorted(by: [
            SortDescriptor(keyPath: "updatedAt", ascending: ascending),
            SortDescriptor(keyPath: "threadID", ascending: true),
        ])
        let objects = Array(sorted.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
        let summaries = try decodeBoundedRuntimeObjects(
            objects,
            name: "pending-state query",
            payload: \.encodedSummary,
            decode: codec.decodeSummary
        )
        return summaries.compactMap { summary in
            guard let pendingState = summary.pendingState else { return nil }
            return AgentPendingStateRecord(
                threadID: summary.threadID,
                pendingState: pendingState,
                updatedAt: summary.updatedAt
            )
        }
    }

    func executeStructuredOutputQuery(
        _ query: StructuredOutputQuery,
        in realm: Realm
    ) throws -> [AgentStructuredOutputRecord] {
        if query.threadIDs?.isEmpty == true || query.formatNames?.isEmpty == true {
            return []
        }
        var results = realm.objects(RealmRuntimeStructuredOutputObject.self)
        if let ids = query.threadIDs {
            results = results.filter("threadID IN %@", Array(ids))
        }
        if let names = query.formatNames {
            results = results.filter("formatName IN %@", Array(names))
        }

        let selected: Results<RealmRuntimeStructuredOutputObject>
        if query.latestOnly {
            let newestFirst = results.sorted(by: [
                SortDescriptor(keyPath: "committedAt", ascending: false),
                SortDescriptor(keyPath: "key", ascending: true),
            ])
            selected = sortStructuredResults(
                newestFirst.distinct(by: ["threadID"]),
                using: query.sort
            )
        } else {
            selected = sortStructuredResults(results, using: query.sort)
        }
        let objects = Array(selected.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
        return try decodeBoundedRuntimeObjects(
            objects,
            name: "structured-output query",
            payload: \.encodedRecord,
            decode: codec.decodeStructuredOutput
        )
    }

    func executeThreadSnapshotQuery(
        _ query: ThreadSnapshotQuery,
        in realm: Realm
    ) throws -> [AgentThreadSnapshot] {
        if query.threadIDs?.isEmpty == true { return [] }
        var results = realm.objects(RealmRuntimeSummaryObject.self)
        if let ids = query.threadIDs {
            results = results.filter("threadID IN %@", Array(ids))
        }
        let sorted: Results<RealmRuntimeSummaryObject>
        switch query.sort {
        case let .updatedAt(order):
            sorted = results.sorted(by: [
                SortDescriptor(keyPath: "updatedAt", ascending: order == .ascending),
                SortDescriptor(keyPath: "threadID", ascending: true),
            ])
        case let .createdAt(order):
            sorted = results.sorted(by: [
                SortDescriptor(keyPath: "createdAt", ascending: order == .ascending),
                SortDescriptor(keyPath: "threadID", ascending: true),
            ])
        }
        let objects = Array(sorted.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
        return try decodeBoundedRuntimeObjects(
            objects,
            name: "snapshot query",
            payload: \.encodedSummary,
            decode: codec.decodeSummary
        ).map(\.snapshot)
    }

    func executeThreadContextStateQuery(
        _ query: ThreadContextStateQuery,
        in realm: Realm
    ) throws -> [AgentThreadContextState] {
        if query.threadIDs?.isEmpty == true { return [] }
        var results = realm.objects(RealmRuntimeContextObject.self)
        if let ids = query.threadIDs {
            results = results.filter("threadID IN %@", Array(ids))
        }
        let sorted = results.sorted(by: [
            SortDescriptor(keyPath: "generation", ascending: false),
            SortDescriptor(keyPath: "threadID", ascending: true),
        ])
        let objects = Array(sorted.prefix(
            AgentStoreLimitValidator.boundedOptionalLimit(query.limit)
        ))
        return try decodeBoundedRuntimeObjects(
            objects,
            name: "context query",
            payload: \.encodedState,
            decode: codec.decodeContextState
        )
    }

    func filteredHistory(
        in realm: Realm,
        threadID: String,
        kinds: Set<AgentHistoryItemKind>?,
        includeCompactionEvents: Bool
    ) -> Results<RealmRuntimeHistoryObject> {
        var results = realm.objects(RealmRuntimeHistoryObject.self)
            .filter("threadID == %@", threadID)
        if let kinds {
            results = results.filter("kind IN %@", kinds.map(\.rawValue))
        }
        if !includeCompactionEvents {
            results = results.filter("isCompactionMarker == false")
        }
        return results
    }

    func historyKinds(
        from filter: AgentHistoryFilter?
    ) -> Set<AgentHistoryItemKind>? {
        guard let filter else { return nil }
        var kinds = Set<AgentHistoryItemKind>()
        if filter.includeMessages { kinds.insert(.message) }
        if filter.includeToolCalls { kinds.insert(.toolCall) }
        if filter.includeToolResults { kinds.insert(.toolResult) }
        if filter.includeStructuredOutputs { kinds.insert(.structuredOutput) }
        if filter.includeApprovals { kinds.insert(.approval) }
        if filter.includeSystemEvents { kinds.insert(.systemEvent) }
        return kinds
    }

    func sortHistory(
        _ results: Results<RealmRuntimeHistoryObject>,
        using sort: AgentHistorySort,
        ascending: Bool
    ) -> Results<RealmRuntimeHistoryObject> {
        switch sort {
        case .sequence:
            results.sorted(by: [
                SortDescriptor(keyPath: "sequenceNumber", ascending: ascending),
                SortDescriptor(keyPath: "createdAt", ascending: ascending),
            ])
        case .createdAt:
            results.sorted(by: [
                SortDescriptor(keyPath: "createdAt", ascending: ascending),
                SortDescriptor(keyPath: "sequenceNumber", ascending: ascending),
            ])
        }
    }

    func historySortOrder(_ sort: AgentHistorySort) -> AgentSortOrder {
        switch sort {
        case let .sequence(order), let .createdAt(order):
            order
        }
    }

    func historyBeforeAnchor(
        _ anchor: AgentHistoryQueryCursorAnchor,
        sort: AgentHistorySort,
        in results: Results<RealmRuntimeHistoryObject>
    ) throws -> Results<RealmRuntimeHistoryObject> {
        switch sort {
        case .sequence:
            return results.filter("sequenceNumber < %d", anchor.sequenceNumber)
        case .createdAt:
            return results.filter(
                "createdAt < %@ OR (createdAt == %@ AND sequenceNumber < %d)",
                anchor.createdAt,
                anchor.createdAt,
                anchor.sequenceNumber
            )
        }
    }

    func historyAfterAnchor(
        _ anchor: AgentHistoryQueryCursorAnchor,
        sort: AgentHistorySort,
        in results: Results<RealmRuntimeHistoryObject>
    ) throws -> Results<RealmRuntimeHistoryObject> {
        switch sort {
        case .sequence:
            return results.filter("sequenceNumber > %d", anchor.sequenceNumber)
        case .createdAt:
            return results.filter(
                "createdAt > %@ OR (createdAt == %@ AND sequenceNumber > %d)",
                anchor.createdAt,
                anchor.createdAt,
                anchor.sequenceNumber
            )
        }
    }

    func historyExistsAtOrAfterAnchor(
        _ anchor: AgentHistoryQueryCursorAnchor,
        sort: AgentHistorySort,
        in results: Results<RealmRuntimeHistoryObject>
    ) throws -> Bool {
        switch sort {
        case .sequence:
            return results.filter("sequenceNumber >= %d", anchor.sequenceNumber).first != nil
        case .createdAt:
            return results.filter(
                "createdAt > %@ OR (createdAt == %@ AND sequenceNumber >= %d)",
                anchor.createdAt,
                anchor.createdAt,
                anchor.sequenceNumber
            ).first != nil
        }
    }

    func historyExistsAtOrBeforeAnchor(
        _ anchor: AgentHistoryQueryCursorAnchor,
        sort: AgentHistorySort,
        in results: Results<RealmRuntimeHistoryObject>
    ) throws -> Bool {
        switch sort {
        case .sequence:
            return results.filter("sequenceNumber <= %d", anchor.sequenceNumber).first != nil
        case .createdAt:
            return results.filter(
                "createdAt < %@ OR (createdAt == %@ AND sequenceNumber <= %d)",
                anchor.createdAt,
                anchor.createdAt,
                anchor.sequenceNumber
            ).first != nil
        }
    }

    func sortStructuredResults(
        _ results: Results<RealmRuntimeStructuredOutputObject>,
        using sort: AgentStructuredOutputSort
    ) -> Results<RealmRuntimeStructuredOutputObject> {
        switch sort {
        case let .committedAt(order):
            results.sorted(by: [
                SortDescriptor(keyPath: "committedAt", ascending: order == .ascending),
                SortDescriptor(keyPath: "threadID", ascending: true),
            ])
        }
    }
}
