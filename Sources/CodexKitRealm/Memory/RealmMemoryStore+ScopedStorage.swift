import CodexKit
import Foundation

extension RealmMemoryStore {
    /// Uses fixed CodexKit database filenames beneath an app-owned account directory.
    public init(storageDirectory: URL, logging: AgentLoggingConfiguration = .disabled) throws {
        let url = try CodexKitManagedStorageLayout.fileURL(in: storageDirectory, for: .realmMemory)
        try self.init(url: url, logging: logging)
    }
}
