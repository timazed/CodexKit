import RealmSwift

/// Owns the Realm schema transition independently from store operations.
/// `RealmMemoryStoreConfigurationBuilder` installs `migrationBlock` directly
/// into the Realm configuration used by the store.
final class RealmMemoryStoreMigration {
    // Realm support has not shipped yet. The complete initial schema is v1;
    // development iterations must not become public migration history.
    static let schemaVersion: UInt64 = 1
    static let migrationBlock: MigrationBlock = { _, _ in }

    private init() {}
}
