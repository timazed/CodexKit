import Foundation

/// Stable, extensible failure information for host applications and models.
public struct ToolFailure: Codable, Hashable, Sendable {
    public let code: String
    public let message: String
    public let details: JSONValue?

    public init(code: String, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}
