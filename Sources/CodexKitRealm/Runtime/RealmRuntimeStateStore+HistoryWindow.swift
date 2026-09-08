import CodexKit
import Foundation
import RealmSwift

extension RealmRuntimeStateStore {
    func unfilteredSequenceWindow(
        _ query: HistoryItemsQuery,
        in realm: Realm,
        anchor: Int?,
        ascending: Bool,
        limit: Int
    ) -> [RealmRuntimeHistoryObject]? {
        guard case .sequence = query.sort, query.kinds == nil,
              query.createdAtRange == nil, query.turnID == nil, query.relationship == nil else { return nil }
        return contiguousHistoryWindow(in: realm, threadID: query.threadID, anchor: anchor,
            ascending: ascending, limit: limit, includeCompactionEvents: query.includeCompactionEvents,
            includeRedacted: query.includeRedacted)
    }

    /// History writes assign consecutive sequence numbers. Read a small adjacent
    /// window by primary key before asking Realm to sort the entire matching
    /// history. A missing or excluded row falls back to the normal filtered query,
    /// including restored histories whose first sequence is greater than one.
    func contiguousHistoryWindow(
        in realm: Realm,
        threadID: String,
        anchor: Int?,
        ascending: Bool,
        limit: Int,
        includeCompactionEvents: Bool = true,
        includeRedacted: Bool = true
    ) -> [RealmRuntimeHistoryObject]? {
        guard limit > 0 else { return [] }
        guard let thread = realm.object(ofType: RealmRuntimeThreadObject.self, forPrimaryKey: threadID),
              thread.nextHistorySequence > 0 else { return nil }
        let upperBound = thread.nextHistorySequence
        let first: Int
        let count: Int
        if ascending {
            let lowerBound = max(0, anchor ?? 0)
            guard lowerBound < upperBound - 1 else { return [] }
            first = lowerBound + 1
            count = min(limit, upperBound - first)
        } else {
            let end = min(anchor ?? upperBound, upperBound)
            guard end > 1 else { return [] }
            first = end - 1
            count = min(limit, first)
        }
        var objects: [RealmRuntimeHistoryObject] = []
        objects.reserveCapacity(count)
        for offset in 0..<count {
            let sequence = ascending ? first + offset : first - offset
            guard let object = realm.object(ofType: RealmRuntimeHistoryObject.self,
                forPrimaryKey: RealmRuntimeStateStoreCodec.historyKey(threadID: threadID, sequenceNumber: sequence)),
                object.threadID == threadID, object.sequenceNumber == sequence,
                includeCompactionEvents || !object.isCompactionMarker,
                includeRedacted || !object.isRedacted else { return nil }
            objects.append(object)
        }
        return objects
    }
}
