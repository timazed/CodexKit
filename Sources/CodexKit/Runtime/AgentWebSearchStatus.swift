/// Known search states, with room for future provider states.
public enum AgentWebSearchStatus: RawRepresentable, Codable, Hashable, Sendable {
    case inProgress, searching, completed
    case custom(String)

    public init(rawValue: String) {
        switch rawValue {
        case "in_progress": self = .inProgress
        case "searching": self = .searching
        case "completed": self = .completed
        default: self = .custom(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .inProgress: "in_progress"
        case .searching: "searching"
        case .completed: "completed"
        case let .custom(value): value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
