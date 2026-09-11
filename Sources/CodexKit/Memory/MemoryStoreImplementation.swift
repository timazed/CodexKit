/// Identifies built-in stores while preserving identifiers from custom stores.
public enum MemoryStoreImplementation: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    case inMemory, sqlite, realm
    case custom(String)

    public init(rawValue: String) {
        switch rawValue {
        case "in_memory": self = .inMemory
        case "sqlite": self = .sqlite
        case "realm": self = .realm
        default: self = .custom(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .inMemory: "in_memory"
        case .sqlite: "sqlite"
        case .realm: "realm"
        case let .custom(value): value
        }
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
