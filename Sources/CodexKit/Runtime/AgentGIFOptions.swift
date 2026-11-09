import Foundation

/// Controls for opt-in animated GIF generation or editing. Nil uses provider defaults.
public struct AgentGIFOptions: Codable, Hashable, Sendable {
    public var frameCount: Int?
    public var frameDurationMilliseconds: Int?

    public init(frameCount: Int? = nil, frameDurationMilliseconds: Int? = nil) {
        self.frameCount = frameCount
        self.frameDurationMilliseconds = frameDurationMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case frameCount = "frame_count"
        case frameDurationMilliseconds = "frame_duration_ms"
    }

    func validate() throws {
        guard frameCount.map({ (2...16).contains($0) }) ?? true,
              frameDurationMilliseconds.map({ (20...2_000).contains($0) }) ?? true else {
            throw AgentRuntimeError(code: .imageGenerationUnsupportedOptions,
                message: "GIF output accepts 2–16 frames and frame durations of 20–2000 milliseconds.")
        }
    }
}
