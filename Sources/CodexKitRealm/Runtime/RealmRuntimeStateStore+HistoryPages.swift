import CodexKit
import Foundation
import RealmSwift

extension RealmRuntimeStateStore {
    func fetchHistoryPage(
        id: String,
        query: AgentHistoryQuery,
        from realm: Realm
    ) throws -> AgentThreadHistoryPage {
        let limit = AgentStoreLimitValidator.boundedLimit(query.limit)
        let kinds = historyKinds(from: query.filter)
        if let kinds, kinds.isEmpty {
            return AgentThreadHistoryPage(
                threadID: id,
                items: [],
                nextCursor: nil,
                previousCursor: nil,
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }
        let includeCompactionEvents = query.filter?.includeCompactionEvents ?? false
        let anchor = try query.cursor?.decodedSequenceNumber(expectedThreadID: id)
        let base = filteredHistory(
            in: realm,
            threadID: id,
            kinds: kinds,
            includeCompactionEvents: includeCompactionEvents
        )

        switch query.direction {
        case .backward:
            let overfetchLimit = agentOverfetchLimit(limit)
            var window = base
            if let anchor {
                window = window.filter("sequenceNumber < %d", anchor)
            }
            let adjacent = kinds == nil ? contiguousHistoryWindow(in: realm, threadID: id,
                anchor: anchor, ascending: false, limit: overfetchLimit,
                includeCompactionEvents: includeCompactionEvents) : nil
            let fetched: [RealmRuntimeHistoryObject]
            if let adjacent {
                fetched = adjacent
            } else {
                fetched = Array(window.sorted(byKeyPath: "sequenceNumber", ascending: false)
                    .prefix(overfetchLimit))
            }
            let pageObjects = Array(fetched.prefix(limit).reversed())
            let records = try decodeHistory(pageObjects)
            let hasMoreAfter = if let anchor {
                base.filter("sequenceNumber >= %d", anchor).first != nil
            } else {
                false
            }
            return AgentThreadHistoryPage(
                threadID: id,
                items: records.map(\.item),
                nextCursor: fetched.count > limit
                    ? AgentHistoryCursor(threadID: id, sequenceNumber: records.first?.sequenceNumber)
                    : nil,
                previousCursor: hasMoreAfter
                    ? AgentHistoryCursor(threadID: id, sequenceNumber: records.last?.sequenceNumber)
                    : nil,
                hasMoreBefore: fetched.count > limit,
                hasMoreAfter: hasMoreAfter
            )

        case .forward:
            let overfetchLimit = agentOverfetchLimit(limit)
            var window = base
            if let anchor {
                window = window.filter("sequenceNumber > %d", anchor)
            }
            let adjacent = kinds == nil ? contiguousHistoryWindow(in: realm, threadID: id,
                anchor: anchor, ascending: true, limit: overfetchLimit,
                includeCompactionEvents: includeCompactionEvents) : nil
            let fetched: [RealmRuntimeHistoryObject]
            if let adjacent {
                fetched = adjacent
            } else {
                fetched = Array(window.sorted(byKeyPath: "sequenceNumber", ascending: true)
                    .prefix(overfetchLimit))
            }
            let pageObjects = Array(fetched.prefix(limit))
            let records = try decodeHistory(pageObjects)
            let hasMoreBefore = if let anchor {
                base.filter("sequenceNumber <= %d", anchor).first != nil
            } else {
                false
            }
            return AgentThreadHistoryPage(
                threadID: id,
                items: records.map(\.item),
                nextCursor: fetched.count > limit
                    ? AgentHistoryCursor(threadID: id, sequenceNumber: records.last?.sequenceNumber)
                    : nil,
                previousCursor: hasMoreBefore
                    ? AgentHistoryCursor(threadID: id, sequenceNumber: records.first?.sequenceNumber)
                    : nil,
                hasMoreBefore: hasMoreBefore,
                hasMoreAfter: fetched.count > limit
            )
        }
    }

}
