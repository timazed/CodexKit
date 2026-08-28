import CodexKit
import Foundation

extension RealmRuntimeStateStore {
    func decodeBoundedRuntimeObjects<Element, Output>(
        _ objects: [Element],
        name: String,
        payload: (Element) -> Data,
        decode: (Element) throws -> Output
    ) throws -> [Output] {
        var payloadByteCount = 0
        return try decodeBoundedRuntimeObjects(
            objects,
            name: name,
            payload: payload,
            payloadByteCount: &payloadByteCount,
            decode: decode
        )
    }

    func decodeBoundedRuntimeObjects<Element, Output>(
        _ objects: [Element],
        name: String,
        payload: (Element) -> Data,
        payloadByteCount: inout Int,
        decode: (Element) throws -> Output
    ) throws -> [Output] {
        var decoded: [Output] = []
        decoded.reserveCapacity(objects.count)
        for object in objects {
            try AgentStoreLimitValidator.accumulateMaterializedPayload(
                payload(object),
                name: name,
                total: &payloadByteCount
            )
            decoded.append(try decode(object))
        }
        return decoded
    }

    func decodeHistory(
        _ objects: [RealmRuntimeHistoryObject]
    ) throws -> [AgentHistoryRecord] {
        let records = try decodeBoundedRuntimeObjects(
            objects,
            name: "history query",
            payload: \.encodedRecord,
            decode: codec.decodeHistoryRecord
        )
        latestQueryDecodedHistoryRecordCount += records.count
        return records
    }

    func emptyHistoryQueryResult(
        threadID: String
    ) -> AgentHistoryQueryResult {
        AgentHistoryQueryResult(
            threadID: threadID,
            records: [],
            nextCursor: nil,
            previousCursor: nil,
            hasMoreBefore: false,
            hasMoreAfter: false
        )
    }
}
