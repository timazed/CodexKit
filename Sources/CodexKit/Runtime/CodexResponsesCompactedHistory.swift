import Foundation

enum CodexResponsesCompactedHistory {
    // Match upstream's retained-message budget, using the SDK's conservative byte estimate.
    static let retainedTextByteBudget = 64_000 * 4
    static let retainedImageByteCharge = 4_000

    static func build(input: [JSONValue], compaction: JSONValue, threadID: String) throws -> AgentCompactionResult {
        var remaining = retainedTextByteBudget
        var retained: [JSONValue] = []
        // Keep recent user context. Assistant/tool history is represented by the checkpoint.
        for item in input.reversed() {
            guard remaining > 0, var object = item.objectValue,
                  object["type"] == .string("message"), object["role"] == .string("user"),
                  let content = object["content"]?.arrayValue else { continue }
            var kept: [JSONValue] = []
            var exhausted = false
            for value in content {
                guard var part = value.objectValue else { continue }
                if let text = part["text"]?.stringValue {
                    let cost = max(1, text.utf8.count)
                    if cost > remaining {
                        let prefix = utf8Prefix(text, maximumBytes: remaining)
                        if !prefix.isEmpty {
                            part["text"] = .string(prefix)
                            kept.append(.object(part))
                        }
                        remaining = 0
                        exhausted = true
                        break
                    }
                    remaining -= cost
                    kept.append(value)
                } else if part["type"] == .string("input_image") {
                    guard remaining >= retainedImageByteCharge else {
                        remaining = 0
                        exhausted = true
                        break
                    }
                    remaining -= retainedImageByteCharge
                    kept.append(value)
                }
            }
            if !kept.isEmpty {
                object["content"] = .array(kept)
                retained.append(.object(object))
            }
            if exhausted { break }
        }
        retained.reverse()
        let messages = retained.compactMap { item -> AgentMessage? in
            guard let content = item.objectValue?["content"]?.arrayValue else { return nil }
            return AgentMessage(threadID: threadID, role: .user,
                text: content.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n"),
                images: content.compactMap { $0.objectValue.flatMap(StreamMessageContent.parseImageAttachment) })
        }
        let output = try CodexResponsesImageReferences.externalize(retained + [compaction])
        try CodexResponsesImageReferences.validate(output,
            using: CodexResponsesImageReferences.attachments(in: messages))
        return .init(effectiveMessages: messages,
            providerContext: CodexResponsesProviderState(items: output).agentProviderContext, summaryPreview: nil)
    }

    private static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        var bytes = Array(text.utf8.prefix(maximumBytes))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) { return result }
            bytes.removeLast()
        }
        return ""
    }
}
