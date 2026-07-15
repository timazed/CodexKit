import Foundation

public enum ReasoningEffort: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case extraHigh
    case max
    case ultra
    case custom(String)

    public static let allCases: [ReasoningEffort] = [
        .none,
        .minimal,
        .low,
        .medium,
        .high,
        .extraHigh,
        .max,
        .ultra,
    ]

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "none":
            self = .none
        case "minimal":
            self = .minimal
        case "low":
            self = .low
        case "medium":
            self = .medium
        case "high":
            self = .high
        case "xhigh", "extraHigh":
            self = .extraHigh
        case "max":
            self = .max
        case "ultra":
            self = .ultra
        default:
            self = .custom(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .none:
            "none"
        case .minimal:
            "minimal"
        case .low:
            "low"
        case .medium:
            "medium"
        case .high:
            "high"
        case .extraHigh:
            "xhigh"
        case .max:
            "max"
        case .ultra:
            "ultra"
        case let .custom(value):
            value
        }
    }

    var apiValue: String {
        switch self {
        case .ultra:
            // Codex uses Ultra to opt into proactive delegation, while the
            // inference backend continues to accept the `max` effort value.
            "max"
        default:
            rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let effort = ReasoningEffort(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Reasoning effort must not be empty."
            )
        }
        self = effort
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
