/// Observable image request stages, not a percentage of model computation.
/// Receiving can include server wait time; completed means the image was validated.
public enum AgentImageGenerationProgress: String, Codable, Hashable, Sendable {
    case requesting, receiving, decoding, completed
}

public typealias AgentImageGenerationProgressHandler = @Sendable (AgentImageGenerationProgress) async -> Void
