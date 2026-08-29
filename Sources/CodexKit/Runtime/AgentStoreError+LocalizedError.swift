import Foundation

extension AgentStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .incompatibleLogicalSchema(found, supported):
            let versions = supported.map(String.init).joined(separator: ", ")
            return "Runtime store logical schema \(found) is incompatible; supported versions: \(versions)."
        case let .migrationRequired(from, to):
            return "Runtime store migration is required from version \(from) to version \(to)."
        case let .migrationFailed(message):
            return "Runtime store migration failed: \(message)"
        case let .invalidInput(message):
            return "Invalid runtime store input: \(message)"
        case let .queryNotSupported(message):
            return "Runtime store query is not supported: \(message)"
        }
    }
}
