import Foundation

/// A usage report covers a prefix of provider items. Later items must still be
/// estimated when responses omit token usage (including spending-only reports).
struct CodexContextUsage: Sendable {
    let tokens: Int
    let coveredItemCount: Int

    init(tokens: Int, coveredItemCount: Int) {
        self.tokens = tokens
        self.coveredItemCount = coveredItemCount
    }

    init?(json: JSONValue?, itemCount: Int) {
        guard let object = json?.objectValue,
              case let .number(tokens)? = object["tokens"],
              case let .number(count)? = object["covered_items"],
              tokens.isFinite, count.isFinite, tokens >= 0, count >= 0,
              tokens.rounded(.down) == tokens, count.rounded(.down) == count,
              tokens < Double(Int.max), count <= Double(itemCount) else { return nil }
        self.init(tokens: Int(tokens), coveredItemCount: Int(count))
    }

    var json: JSONValue {
        .object(["tokens": .number(Double(tokens)), "covered_items": .number(Double(coveredItemCount))])
    }

    static func estimate(context: AgentProviderContext?, history: [AgentMessage],
                         pending: Request? = nil, instructions: String = "") -> Int {
        guard let state = CodexResponsesProviderState(context: context), !state.items.isEmpty else { return 0 }
        let boundary = state.contextUsage
        let suffix = state.items.dropFirst(boundary?.coveredItemCount ?? 0)
        let characters = suffix.reduce(0) { AgentCounter.saturatingAdd($0, characterCount($1)) }
        var estimate = AgentCounter.saturatingAdd(boundary?.tokens ?? 0, characters / 4)
        // Reported input already includes instructions; do not charge them twice.
        if boundary == nil { estimate = AgentCounter.saturatingAdd(estimate, instructions.count / 4) }
        if let pending {
            let message = AgentMessage(threadID: "", role: .user, text: pending.text, images: pending.images)
            var count = message.estimatedContextCharacterCount
            count = AgentCounter.saturatingAdd(count, pending.context?.payload.prettyJSONString.count ?? 0)
            count = AgentCounter.saturatingAdd(count, pending.options?.mode.count ?? 0)
            for requirement in pending.options?.requirements ?? [] {
                count = AgentCounter.saturatingAdd(count, requirement.count)
            }
            estimate = AgentCounter.saturatingAdd(estimate, count / 4)
        }
        return estimate
    }

    private static func characterCount(_ value: JSONValue) -> Int {
        switch value {
        case let .object(object):
            if object["type"] == .string("input_image") || object["type"] == .string("output_image") {
                return 4_000 // Charge image context, never the base64 representation.
            }
            return object.reduce(0) { total, field in
                // IDs and envelope metadata do not represent model context.
                if ["id", "type", "status", "call_id"].contains(field.key) { return total }
                if field.key == "b64_json" || field.key == "result" && object["type"] == .string("image_generation_call") {
                    return AgentCounter.saturatingAdd(total, 4_000)
                }
                return AgentCounter.saturatingAdd(total, characterCount(field.value))
            }
        case let .array(values):
            return values.reduce(0) { AgentCounter.saturatingAdd($0, characterCount($1)) }
        case let .string(text): return text.count
        case .null, .bool, .number: return 0
        }
    }
}
