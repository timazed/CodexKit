import CodexKit
import Foundation

extension SQLiteRuntimeStateStore {
    /// Uses fixed CodexKit database filenames beneath an app-owned account directory.
    public init(storageDirectory: URL, logging: AgentLoggingConfiguration = .disabled) throws {
        let url = try CodexKitManagedStorageLayout.fileURL(in: storageDirectory, for: .sqliteRuntime)
        try self.init(url: url, logging: logging)
    }

    public init(
        importingLegacyStateFrom legacyStateURL: URL? = nil,
        logging: AgentLoggingConfiguration = .disabled
    ) throws {
        let layout = try CodexKitManagedStorageLayout.live()
        try self.init(
            url: layout.fileURL(for: .sqliteRuntime),
            importingLegacyStateFrom: legacyStateURL,
            logging: logging
        )
    }
}
