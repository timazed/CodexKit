import Foundation

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case extraHigh

    var apiValue: String {
        switch self {
        case .low:
            "low"
        case .medium:
            "medium"
        case .high:
            "high"
        case .extraHigh:
            "xhigh"
        }
    }
}
