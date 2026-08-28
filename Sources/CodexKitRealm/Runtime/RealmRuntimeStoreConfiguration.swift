import Foundation
import RealmSwift

/// Owns Realm's schema-opening policy separately from runtime-store behavior.
/// Query-projection and attachment backfills remain resumable post-open work.
final class RealmRuntimeStoreMigration {
    static let migrationBlock: MigrationBlock = { _, _ in }

    private init() {}
}

struct RealmRuntimeStoreConfigurationBuilder {
    let fileURL: URL

    func build() -> Realm.Configuration {
        Realm.Configuration(
            fileURL: fileURL,
            schemaVersion: RealmRuntimeSchema.version,
            migrationBlock: RealmRuntimeStoreMigration.migrationBlock,
            objectTypes: RealmRuntimeSchema.objectTypes
        )
    }
}
