import Foundation

/// A provider cache request, not a guarantee of retention, account support, or reuse.
public enum AgentPromptCacheTTL: String, Codable, Hashable, Sendable {
    case thirtyMinutes = "30m"
    case twelveHours = "12h"
}

struct ResponsesPromptCacheOptions: Encodable {
    let ttl: AgentPromptCacheTTL
}

/// Automatic compaction shares the current turn's request preference; tasks for
/// subsequent turns explicitly bind their own value (including nil).
enum AgentPromptCacheContext {
    @TaskLocal static var current: AgentPromptCacheTTL?
}
