import Foundation

extension RuntimeAttachmentStore {
    func attachmentMessages(
        in operations: [AgentStoreWriteOperation]
    ) throws -> [AgentMessage] {
        var messages: [AgentMessage] = []
        for operation in operations {
            switch operation {
            case let .appendHistoryItems(_, records),
                 let .restoreHistoryItems(_, records):
                for record in records {
                    try appendAttachmentMessages(for: record, to: &messages)
                }
            case let .appendCompactionMarker(_, record):
                try appendAttachmentMessages(for: record, to: &messages)
            case let .upsertThreadContextState(_, state):
                for message in state?.effectiveMessages ?? [] {
                    messages.append(message)
                    messages.append(contentsOf: try RuntimeEmbeddedAttachmentCollector.messages(
                        for: message
                    ))
                }
            default:
                break
            }
        }
        return messages
    }

    func attachmentMessages(in state: StoredRuntimeState) throws -> [AgentMessage] {
        var messages: [AgentMessage] = []
        for records in state.historyByThread.values {
            for record in records {
                try appendAttachmentMessages(for: record, to: &messages)
            }
        }
        for context in state.contextStateByThread.values {
            for message in context.effectiveMessages {
                messages.append(message)
                messages.append(contentsOf: try RuntimeEmbeddedAttachmentCollector.messages(
                    for: message
                ))
            }
        }
        return messages
    }

    private func appendAttachmentMessages(
        for record: AgentHistoryRecord,
        to messages: inout [AgentMessage]
    ) throws {
        if case let .message(message) = record.item {
            messages.append(message)
            messages.append(contentsOf: try RuntimeEmbeddedAttachmentCollector.messages(
                for: message
            ))
        }
        messages.append(contentsOf: try RuntimeEmbeddedAttachmentCollector.messages(for: record))
    }
}
