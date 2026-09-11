import Foundation

/// Retained messages before an encrypted checkpoint are completed context even
/// though upstream compaction intentionally removes their assistant replies.
package enum CodexResponsesCheckpointContext {
    package static func completedMessageIDs(context: AgentProviderContext?, messages: [AgentMessage]) -> Set<String> {
        guard let prefix = checkpointPrefix(context: context, messages: messages) else { return [] }
        return Set(messages.prefix(prefix.count).map(\.id))
    }

    /// Preserve the checkpoint when only its retained-message prefix was bounded.
    /// Changes to later conversation units still invalidate provider context.
    package static func rebase(context: AgentProviderContext?, original: [AgentMessage],
        retained: [AgentMessage]) -> AgentProviderContext? {
        if original == retained { return context }
        guard let context, let prefix = checkpointPrefix(context: context, messages: original) else { return nil }
        let prefixIDs = Set(original.prefix(prefix.count).map(\.id))
        let replacement: [AgentMessage]
        if original.count == prefix.count {
            // A bounded oversized prefix may have become a local system summary.
            replacement = retained
        } else {
            guard Array(original.dropFirst(prefix.count)) == retained.filter({ !prefixIDs.contains($0.id) }) else {
                return nil
            }
            replacement = retained.filter { prefixIDs.contains($0.id) }
        }
        guard let items = try? CodexResponsesImageReferences.externalize(
            replacement.map { WorkingHistoryItem.visibleMessage($0).jsonValue }
        ), var payload = context.payload.objectValue else { return nil }
        payload["items"] = .array(items + prefix.checkpointAndSuffix)
        return .init(providerID: context.providerID, payload: .object(payload))
    }

    private static func checkpointPrefix(context: AgentProviderContext?, messages: [AgentMessage])
        -> (count: Int, checkpointAndSuffix: [JSONValue])? {
        guard context?.providerID == CodexResponsesProviderState.providerID,
              let items = context?.payload.objectValue?["items"]?.arrayValue,
              let index = items.lastIndex(where: { $0.objectValue?["type"] == ResponsesItemType.compaction.jsonValue }),
              let encrypted = items[index].objectValue?["encrypted_content"]?.stringValue, !encrypted.isEmpty,
              index <= messages.count else { return nil }
        // Match the saved prefix rather than treating any pending user input as complete.
        for (item, message) in zip(items.prefix(index), messages) {
            guard let object = item.objectValue, object["type"] == ResponsesItemType.message.jsonValue,
                  object["role"] == .string(message.role.rawValue),
                  let content = object["content"]?.arrayValue,
                  content.compactMap({ $0.objectValue?["text"]?.stringValue }).joined(separator: "\n") == message.text,
                  let expected = try? CodexResponsesImageReferences.externalize([
                    WorkingHistoryItem.visibleMessage(message).jsonValue
                  ]).first?.objectValue?["content"]?.arrayValue else { return nil }
            let imageContent: (JSONValue) -> Bool = { $0.objectValue?["type"] == ResponsesContentType.inputImage.jsonValue }
            guard content.filter(imageContent) == expected.filter(imageContent) else { return nil }
        }
        return (index, Array(items[index...]))
    }
}
