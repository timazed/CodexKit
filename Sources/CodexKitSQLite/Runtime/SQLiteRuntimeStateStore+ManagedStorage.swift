import CodexKit
import Foundation

extension SQLiteRuntimeStateStore {
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
