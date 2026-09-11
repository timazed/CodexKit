import CodexKit
import CodexKitRealm
import CodexKitSQLite
import Foundation

enum TestStorageBackend: String, CaseIterable, Sendable, CustomStringConvertible {
    case file, sqlite, realm, inMemory

    var description: String { rawValue }

    func open(at url: URL) throws -> any RuntimeStateStoring {
        switch self {
        case .inMemory: InMemoryRuntimeStateStore()
        case .file: FileRuntimeStateStore(url: url)
        case .sqlite: try SQLiteRuntimeStateStore(url: url)
        case .realm: try RealmRuntimeStateStore(url: url)
        }
    }
}
