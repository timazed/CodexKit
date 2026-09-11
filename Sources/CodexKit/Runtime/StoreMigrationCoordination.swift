import Foundation

package struct StoreMigrationIdentity: Hashable, Sendable {
    package enum Kind: Sendable {
        case memory, runtime
    }

    package let kind: Kind
    package let location: String

    package init(kind: Kind, url: URL) {
        self.kind = kind
        self.location = url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    package init(kind: Kind, instanceID: UUID) {
        self.kind = kind
        self.location = "memory:\(instanceID.uuidString)"
    }
}

package protocol StoreMigrationIdentifying: Sendable {
    var storeMigrationIdentity: StoreMigrationIdentity { get }
}

/// Built-in persistent stores expose the same coordination root used by their
/// normal mutations, allowing a migration to reserve both stores atomically.
package protocol StoreMigrationCoordinating: Sendable {
    var migrationCoordinationRootURL: URL { get }
}

package enum StoreMigrationCoordinationRoot {
    package static func memoryStore(at url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).codexkit-memory-state", isDirectory: true)
            .appendingPathComponent("coordination", isDirectory: true)
    }
}
