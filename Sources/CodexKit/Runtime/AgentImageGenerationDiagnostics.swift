import Foundation

/// Correlation metadata, separate from prompts, credentials, and image payloads.
public struct AgentImageGenerationDiagnostics: Codable, Hashable, Sendable {
    public let clientRequestID: String
    public let requestID: String?
    public let imageRequestID: String?
    public let generationID: String?
    public let usageLimit: AgentImageGenerationUsageLimit?

    public init(clientRequestID: String, requestID: String? = nil, imageRequestID: String? = nil,
                generationID: String? = nil, usageLimit: AgentImageGenerationUsageLimit? = nil) {
        self.clientRequestID = clientRequestID
        self.requestID = requestID
        self.imageRequestID = imageRequestID
        self.generationID = generationID
        self.usageLimit = usageLimit
    }
}

public struct AgentImageGenerationUsageLimit: Codable, Hashable, Sendable {
    public let limitID: String
    /// Nil means the provider did not supply a usable reset time.
    public let resetsAt: Date?

    public init(limitID: String = "image_gen", resetsAt: Date? = nil) {
        self.limitID = limitID
        self.resetsAt = resetsAt
    }
}
