import Foundation

package enum AgentHistoryWriteValidator {
    package static func validateSnapshot(_ state: StoredRuntimeState) throws {
        let threadIDs = Set(state.threads.map(\.id))
        guard threadIDs.count == state.threads.count else {
            throw AgentStoreError.invalidInput("a runtime snapshot contains duplicate thread IDs")
        }
        for thread in state.threads {
            guard !thread.id.isEmpty,
                  thread.id.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
                throw AgentStoreError.invalidInput("threadID is empty or too large")
            }
            try validateDate(thread.createdAt, name: "thread createdAt")
            try validateDate(thread.updatedAt, name: "thread updatedAt")
        }
        for (threadID, items) in state.historyByThread {
            try validate(
                items,
                threadID: threadID,
                existingLastSequence: nil,
                threadExists: threadIDs.contains(threadID),
                allowInitialSequenceGap: true
            )
        }
        for (threadID, messages) in state.messagesByThread {
            try validateOwner(threadID, threadIDs: threadIDs, projection: "messages")
            for message in messages {
                try validateMessage(message, threadID: threadID)
            }
        }
        for (threadID, summary) in state.summariesByThread {
            try validateOwner(threadID, threadIDs: threadIDs, projection: "summary")
            guard summary.threadID == threadID else {
                throw AgentStoreError.invalidInput(
                    "summary threadID must match its owning thread"
                )
            }
            if let itemCount = summary.itemCount, itemCount < 0 {
                throw AgentStoreError.invalidInput("summary itemCount must be nonnegative")
            }
            try validateDate(summary.createdAt, name: "summary createdAt")
            try validateDate(summary.updatedAt, name: "summary updatedAt")
            try validateOptionalDate(summary.latestItemAt, name: "summary latestItemAt")
            try AgentStoredPayloadValidator.validateSummary(summary)
        }
        for (threadID, context) in state.contextStateByThread {
            try validateOwner(threadID, threadIDs: threadIDs, projection: "context state")
            guard context.threadID == threadID else {
                throw AgentStoreError.invalidInput(
                    "context-state threadID must match its owning thread"
                )
            }
            guard context.generation >= 0 else {
                throw AgentStoreError.invalidInput("context generation must be nonnegative")
            }
            guard context.effectiveMessages.count <= AgentStoreLimits.maximumContextMessageCount else {
                throw AgentStoreError.invalidInput(
                    "context state must not exceed \(AgentStoreLimits.maximumContextMessageCount) messages"
                )
            }
            let contextAttachmentCount = context.effectiveMessages.reduce(0) { count, message in
                AgentCounter.saturatingAdd(count, message.images.count)
            }
            let contextAttachmentBytes = context.effectiveMessages.reduce(0) { count, message in
                message.images.reduce(count) {
                    AgentCounter.saturatingAdd($0, $1.data.count)
                }
            }
            guard contextAttachmentCount <= AgentStoreLimits.maximumImageCountPerWrite,
                  contextAttachmentBytes <= AgentStoreLimits.maximumImageBytesPerWrite else {
                throw AgentStoreError.invalidInput(
                    "context attachments exceed their bounded limits"
                )
            }
            let contextTextByteCount = context.effectiveMessages.reduce(0) { count, message in
                AgentCounter.saturatingAdd(count, message.text.utf8.count)
            }
            guard contextTextByteCount <= AgentStoreLimits.maximumContextMessageTextByteCount else {
                throw AgentStoreError.invalidInput(
                    "context message text exceeds its bounded limit"
                )
            }
            for message in context.effectiveMessages {
                try validateMessage(message, threadID: threadID)
            }
            try AgentStoredPayloadValidator.validateContext(context)
            try validateOptionalDate(context.lastCompactedAt, name: "context lastCompactedAt")
        }
        for (threadID, nextSequence) in state.nextHistorySequenceByThread {
            try validateOwner(threadID, threadIDs: threadIDs, projection: "next sequence")
            guard nextSequence > 0 else {
                throw AgentStoreError.invalidInput("next history sequence must be positive")
            }
        }
    }

    package static func validate(
        _ items: [AgentHistoryRecord],
        threadID: String,
        existingLastSequence: Int?,
        threadExists: Bool,
        allowInitialSequenceGap: Bool
    ) throws {
        guard !threadID.isEmpty,
              threadID.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
            throw AgentStoreError.invalidInput("threadID is empty or too large")
        }
        guard threadExists else {
            throw AgentRuntimeError.threadNotFound(threadID)
        }
        guard !items.isEmpty else { return }

        var expectedSequence = try AgentHistorySequence.next(
            after: existingLastSequence,
            threadID: threadID
        )
        if allowInitialSequenceGap,
           existingLastSequence == nil,
           let firstSequence = items.first?.sequenceNumber,
           firstSequence > 1 {
            expectedSequence = firstSequence
        }

        for item in items {
            guard item.item.threadID == threadID else {
                throw AgentStoreError.invalidInput(
                    "history item threadID must match its owning thread"
                )
            }
            guard item.sequenceNumber == expectedSequence else {
                throw AgentRuntimeError(
                    code: .invalidHistorySequence,
                    message: "Expected history sequence \(expectedSequence) for thread \(threadID), received \(item.sequenceNumber)."
                )
            }
            guard !item.id.isEmpty,
                  item.id.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
                throw AgentStoreError.invalidInput("history record ID is empty or too large")
            }
            try validateDate(item.createdAt, name: "history createdAt")
            try validateHistoryItem(item.item, threadID: threadID)
            expectedSequence = try AgentHistorySequence.next(
                after: item.sequenceNumber,
                threadID: threadID
            )
        }
    }

    private static func validateOwner(
        _ threadID: String,
        threadIDs: Set<String>,
        projection: String
    ) throws {
        guard !threadID.isEmpty,
              threadID.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
            throw AgentStoreError.invalidInput("\(projection) threadID is empty or too large")
        }
        guard threadIDs.contains(threadID) else {
            throw AgentStoreError.invalidInput(
                "\(projection) belongs to a thread that is not in the snapshot"
            )
        }
    }

    private static func validateHistoryItem(
        _ item: AgentHistoryItem,
        threadID: String
    ) throws {
        switch item {
        case let .message(message):
            try validateMessage(message, threadID: threadID)
        case let .toolCall(call):
            try validateDate(call.requestedAt, name: "tool-call requestedAt")
        case let .toolResult(result):
            try validateDate(result.completedAt, name: "tool-result completedAt")
        case let .structuredOutput(output):
            try validateDate(output.committedAt, name: "structured-output committedAt")
        case let .approval(approval):
            try validateDate(approval.occurredAt, name: "approval occurredAt")
        case let .systemEvent(event):
            try validateDate(event.occurredAt, name: "system-event occurredAt")
        }
        try AgentStoredPayloadValidator.validateHistoryItem(
            item,
            expectedThreadID: threadID
        )
    }

    private static func validateMessage(
        _ message: AgentMessage,
        threadID: String
    ) throws {
        guard message.threadID == threadID else {
            throw AgentStoreError.invalidInput(
                "message threadID must match its owning thread"
            )
        }
        guard !message.id.isEmpty,
              message.id.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
            throw AgentStoreError.invalidInput("message ID is empty or too large")
        }
        guard message.images.count <= AgentStoreLimits.maximumImageCountPerMessage else {
            throw AgentStoreError.invalidInput(
                "a message must not exceed \(AgentStoreLimits.maximumImageCountPerMessage) images"
            )
        }
        guard message.text.utf8.count <= AgentStoreLimits.maximumMessageTextByteCount else {
            throw AgentStoreError.invalidInput(
                "message text must not exceed \(AgentStoreLimits.maximumMessageTextByteCount) UTF-8 bytes"
            )
        }
        try AgentStoredPayloadValidator.validateMessage(message)
        for image in message.images {
            guard !image.id.isEmpty,
                  image.id.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount,
                  !image.mimeType.rawValue.isEmpty,
                  image.mimeType.rawValue.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
                throw AgentStoreError.invalidInput("image metadata is invalid")
            }
            guard image.data.count <= AgentStoreLimits.maximumImageByteCount else {
                throw AgentStoreError.invalidInput(
                    "an image must not exceed \(AgentStoreLimits.maximumImageByteCount) bytes"
                )
            }
        }
        try validateDate(message.createdAt, name: "message createdAt")
    }

    private static func validateOptionalDate(_ date: Date?, name: String) throws {
        guard let date else { return }
        try validateDate(date, name: name)
    }

    private static func validateDate(_ date: Date, name: String) throws {
        guard date.timeIntervalSince1970.isFinite else {
            throw AgentStoreError.invalidInput("\(name) must be finite")
        }
    }
}
