import Foundation
import RealmSwift

public enum RealmMemoryStoreIntegrityError: Error, LocalizedError, Equatable, Sendable {
    case corruptDedupeClaim(String)

    public var errorDescription: String? {
        switch self {
        case let .corruptDedupeClaim(key):
            return "Realm memory dedupe claim \(key) does not reference its expected record."
        }
    }
}

struct RealmMemoryDedupeClaimRepository {
    func deleteAll(
        records: Results<RealmMemoryRecord>,
        claims: Results<RealmMemoryDedupeClaim>,
        namespace: String,
        diagnosticsWriter: RealmMemoryDiagnosticsWriter,
        in realm: Realm
    ) throws -> RealmMemoryDiagnosticsDelta {
        let expectedClaimCount = records.filter("dedupeKey != nil").count
        guard claims.count == expectedClaimCount else {
            let corruptKey = records
                .filter("dedupeKey != nil")
                .first?
                .dedupeKey ?? namespace
            throw RealmMemoryStoreIntegrityError.corruptDedupeClaim(corruptKey)
        }
        if let corrupt = claims
            .filter("record == nil OR key != record.dedupeClaimKey")
            .first {
            throw RealmMemoryStoreIntegrityError.corruptDedupeClaim(corrupt.key)
        }
        let diagnosticsDelta = try diagnosticsWriter.removalDelta(
            for: records,
            namespace: namespace
        )
        realm.delete(claims)
        realm.delete(records)
        return diagnosticsDelta
    }

    func deleteRecordClaimed(
        by claimKey: String,
        diagnosticsDelta: inout RealmMemoryDiagnosticsDelta,
        in realm: Realm
    ) throws {
        let records = realm.objects(RealmMemoryRecord.self)
            .filter("dedupeClaimKey == %@", claimKey)
        guard let claim = realm.object(
            ofType: RealmMemoryDedupeClaim.self,
            forPrimaryKey: claimKey
        ) else {
            guard records.isEmpty else {
                throw RealmMemoryStoreIntegrityError.corruptDedupeClaim(claimKey)
            }
            return
        }
        guard records.count == 1,
              let record = claim.record,
              record.dedupeClaimKey == claimKey,
              records.first?.key == record.key else {
            throw RealmMemoryStoreIntegrityError.corruptDedupeClaim(claim.key)
        }
        try delete(
            record,
            knownClaim: claim,
            diagnosticsDelta: &diagnosticsDelta,
            in: realm
        )
    }

    func delete(
        _ record: RealmMemoryRecord,
        diagnosticsDelta: inout RealmMemoryDiagnosticsDelta,
        in realm: Realm
    ) throws {
        try delete(
            record,
            knownClaim: nil,
            diagnosticsDelta: &diagnosticsDelta,
            in: realm
        )
    }

    private func delete(
        _ record: RealmMemoryRecord,
        knownClaim: RealmMemoryDedupeClaim?,
        diagnosticsDelta: inout RealmMemoryDiagnosticsDelta,
        in realm: Realm
    ) throws {
        let claim: RealmMemoryDedupeClaim?
        if let dedupeKey = record.dedupeKey {
            let expectedKey = RealmMemoryKey.make(
                namespace: record.namespace,
                id: dedupeKey
            )
            let records = realm.objects(RealmMemoryRecord.self)
                .filter("dedupeClaimKey == %@", expectedKey)
            claim = knownClaim ?? realm.object(
                ofType: RealmMemoryDedupeClaim.self,
                forPrimaryKey: expectedKey
            )
            guard records.count == 1,
                  records.first?.key == record.key,
                  record.dedupeClaimKey == expectedKey,
                  claim?.key == expectedKey,
                  claim?.record?.key == record.key
            else {
                throw RealmMemoryStoreIntegrityError.corruptDedupeClaim(expectedKey)
            }
        } else {
            guard knownClaim == nil else {
                throw RealmMemoryStoreIntegrityError.corruptDedupeClaim(knownClaim?.key ?? "")
            }
            claim = nil
        }

        if let claim {
            realm.delete(claim)
        }
        diagnosticsDelta.add(record, by: -1)
        realm.delete(record)
    }
}
