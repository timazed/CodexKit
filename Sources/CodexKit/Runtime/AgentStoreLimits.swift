import Foundation

package func castAgentQueryResult<Result>(
    _ value: Any,
    to _: Result.Type
) throws -> Result {
    guard let result = value as? Result else {
        throw AgentStoreError.queryNotSupported(String(describing: Result.self))
    }
    return result
}

package func encodeBoundedRuntimePayload<Value: Encodable>(
    _ value: Value,
    name: String
) throws -> Data {
    let data = try JSONEncoder().encode(value)
    try validateBoundedRuntimePayload(data, name: name)
    return data
}

package func validateBoundedRuntimePayload(_ data: Data, name: String) throws {
    guard data.count <= AgentStoreLimits.maximumPersistedPayloadByteCount else {
        throw AgentStoreError.invalidInput(
            "\(name) must not exceed \(AgentStoreLimits.maximumPersistedPayloadByteCount) encoded bytes"
        )
    }
}

public enum AgentStoreLimits {
    public static let defaultListResultCount = 256
    public static let maximumQueryResultCount = 256
    public static let maximumMemoryAttributionScanCount = 4_096
    public static let maximumQueryFilterValueCount = 512
    public static let maximumWriteOperationCount = 1_024
    public static let maximumPendingWriteOperationCount = 4_096
    public static let maximumHistoryWriteCount = 1_024
    public static let maximumRedactionIdentifierCount = 1_024
    public static let maximumRedactionMatchCount = 1_024
    public static let maximumIdentifierByteCount = 1_024
    public static let maximumCursorByteCount = 4_096
    public static let maximumImageCountPerMessage = 32
    public static let maximumImageCountPerWrite = 1_024
    public static let maximumImageByteCount = 50 * 1_024 * 1_024
    public static let maximumImageBytesPerWrite = 256 * 1_024 * 1_024
    public static let maximumPromotionJournalByteCount = 1 * 1_024 * 1_024
    public static let maximumAttachmentStorageKeyByteCount = 4_096
    public static let maximumActivationMessageCount = 512
    public static let maximumActivationEstimatedTokenCount = 1_000_000
    public static let maximumActivationHistoryRecordCount = 2_048
    public static let maximumContextMessageCount = 2_048
    public static let maximumMessageTextByteCount = 1 * 1_024 * 1_024
    public static let maximumMessageTextBytesPerWrite = 64 * 1_024 * 1_024
    public static let maximumContextMessageTextByteCount = 8 * 1_024 * 1_024
    public static let maximumPersistedPayloadByteCount = 16 * 1_024 * 1_024
    public static let maximumMaterializedPayloadByteCount = 64 * 1_024 * 1_024
    public static let maximumEmbeddedPayloadByteCount = 4 * 1_024 * 1_024
    public static let maximumEmbeddedPayloadNodeCount = 10_000
    public static let maximumEmbeddedPayloadDepth = 64
    public static let maximumToolResultContentCount = 256
    public static let maximumResponseErrorBodyByteCount = 1 * 1_024 * 1_024
    public static let maximumResponseItemCount = 2_048
    public static let maximumPendingSteeringMessageCount = 512
    public static let maximumResponseEventByteCount =
        ((maximumImageByteCount + 2) / 3) * 4 + maximumEmbeddedPayloadByteCount

    /// Keeps each attribution-history page comfortably below the aggregate
    /// materialization limit even when snapshots approach their encoded cap.
    package static let memoryAttributionHistoryPageSize = 8

    /// A one-byte control character expands to a six-byte JSON escape. This
    /// reserves at least as much encoded space as any validated identifier.
    package static let maximumEncodedIdentifierPlaceholder = String(
        repeating: "\u{0}",
        count: maximumIdentifierByteCount
    )
}

package enum AgentStoreLimitValidator {
    package static func accumulateMaterializedPayload(
        _ data: Data,
        name: String,
        total: inout Int
    ) throws {
        try validateBoundedRuntimePayload(data, name: name)
        let (updated, overflow) = total.addingReportingOverflow(data.count)
        guard !overflow, updated <= AgentStoreLimits.maximumMaterializedPayloadByteCount else {
            throw invalid(
                "materialized payloads must not exceed \(AgentStoreLimits.maximumMaterializedPayloadByteCount) encoded bytes"
            )
        }
        total = updated
    }

    package static func validate<Query: AgentQuerySpec>(_ query: Query) throws {
        switch query {
        case let query as HistoryItemsQuery:
            try validateIdentifier(query.threadID, name: "threadID")
            if let turnID = query.turnID {
                try validateIdentifier(turnID, name: "turnID")
            }
            if let relationship = query.relationship {
                switch relationship {
                case let .message(id), let .toolInvocation(id):
                    try validateIdentifier(id, name: "relationship ID")
                }
            }
            try validateDateRange(query.createdAtRange, name: "createdAtRange")
            try validate(query.page ?? AgentQueryPage(
                limit: AgentStoreLimits.defaultListResultCount
            ))
        case let query as ThreadMetadataQuery:
            try validateIdentifiers(query.threadIDs, name: "threadIDs")
            try validateOptionalLimit(query.limit)
            try validateDateRange(query.updatedAtRange, name: "updatedAtRange")
            if let cursor = query.cursor {
                guard cursor.date.timeIntervalSince1970.isFinite else {
                    throw invalid("thread cursor date must be finite")
                }
                try validateIdentifier(cursor.threadID, name: "thread cursor threadID")
            }
        case let query as PendingStateQuery:
            try validateIdentifiers(query.threadIDs, name: "threadIDs")
            try validateOptionalLimit(query.limit)
        case let query as StructuredOutputQuery:
            try validateIdentifiers(query.threadIDs, name: "threadIDs")
            try validateIdentifiers(query.formatNames, name: "formatNames")
            try validateOptionalLimit(query.limit)
        case let query as ThreadSnapshotQuery:
            try validateIdentifiers(query.threadIDs, name: "threadIDs")
            try validateOptionalLimit(query.limit)
        case let query as ThreadContextStateQuery:
            try validateIdentifiers(query.threadIDs, name: "threadIDs")
            try validateOptionalLimit(query.limit)
        default:
            break
        }
    }

    package static func validateHistoryPage(_ query: AgentHistoryQuery) throws {
        try validateLimit(query.limit)
        if let cursor = query.cursor {
            guard cursor.rawValue.utf8.count <= AgentStoreLimits.maximumCursorByteCount else {
                throw invalid("history cursor is too large")
            }
        }
    }

    package static func validateLoadedHistoryRecord(
        _ record: AgentHistoryRecord,
        expectedThreadID: String
    ) throws {
        try validateIdentifier(expectedThreadID, name: "threadID")
        try validateIdentifier(record.id, name: "history record ID")
        try validateDate(record.createdAt, name: "history createdAt")
        guard record.sequenceNumber > 0 else {
            throw invalid("history sequence must be positive")
        }
        guard record.item.threadID == expectedThreadID else {
            throw invalid("stored history item belongs to a different thread")
        }
        if case let .message(message) = record.item {
            var attachmentCount = 0
            var attachmentByteCount = 0
            var messageTextByteCount = 0
            try validateMessage(
                message,
                threadID: expectedThreadID,
                attachmentCount: &attachmentCount,
                attachmentByteCount: &attachmentByteCount,
                messageTextByteCount: &messageTextByteCount
            )
        }
        try AgentStoredPayloadValidator.validateHistoryItem(
            record.item,
            expectedThreadID: expectedThreadID
        )
    }

    package static func validateLoadedThread(
        _ thread: AgentThread,
        expectedID: String
    ) throws {
        try validateIdentifier(expectedID, name: "threadID")
        guard thread.id == expectedID else {
            throw invalid("stored thread payload does not match its primary key")
        }
        try validateDate(thread.createdAt, name: "thread createdAt")
        try validateDate(thread.updatedAt, name: "thread updatedAt")
    }

    package static func validateLoadedSummary(
        _ summary: AgentThreadSummary,
        expectedThreadID: String
    ) throws {
        try validateIdentifier(expectedThreadID, name: "threadID")
        guard summary.threadID == expectedThreadID,
              summary.itemCount.map({ $0 >= 0 }) ?? true else {
            throw invalid("stored summary payload does not match its indexed projection")
        }
        try validateDate(summary.createdAt, name: "summary createdAt")
        try validateDate(summary.updatedAt, name: "summary updatedAt")
        if let latestItemAt = summary.latestItemAt {
            try validateDate(latestItemAt, name: "summary latestItemAt")
        }
        try AgentStoredPayloadValidator.validateSummary(summary)
    }

    package static func validateLoadedStructuredOutput(
        _ record: AgentStructuredOutputRecord,
        expectedThreadID: String
    ) throws {
        try validateIdentifier(expectedThreadID, name: "threadID")
        guard record.threadID == expectedThreadID else {
            throw invalid("stored structured output belongs to a different thread")
        }
        try validateDate(record.committedAt, name: "structured-output committedAt")
        try AgentStoredPayloadValidator.validateHistoryItem(
            .structuredOutput(record),
            expectedThreadID: expectedThreadID
        )
    }

    package static func validateLoadedContextState(
        _ state: AgentThreadContextState,
        expectedThreadID: String
    ) throws {
        try validateIdentifier(expectedThreadID, name: "threadID")
        guard state.threadID == expectedThreadID else {
            throw invalid("stored context state belongs to a different thread")
        }
        guard state.effectiveMessages.count <= AgentStoreLimits.maximumContextMessageCount,
              state.generation >= 0,
              state.lastCompactedAt?.timeIntervalSince1970.isFinite ?? true else {
            throw invalid("stored context state exceeds its bounded limits")
        }
        var attachmentCount = 0
        var attachmentByteCount = 0
        var messageTextByteCount = 0
        for message in state.effectiveMessages {
            try validateMessage(
                message,
                threadID: expectedThreadID,
                attachmentCount: &attachmentCount,
                attachmentByteCount: &attachmentByteCount,
                messageTextByteCount: &messageTextByteCount
            )
        }
        try validateContextTextBudget(state)
        try AgentStoredPayloadValidator.validateContext(state)
    }

    package static func validate(_ operations: [AgentStoreWriteOperation]) throws {
        guard operations.count <= AgentStoreLimits.maximumWriteOperationCount else {
            throw invalid(
                "a write batch must not exceed \(AgentStoreLimits.maximumWriteOperationCount) operations"
            )
        }
        var attachmentCount = 0
        var attachmentByteCount = 0
        var messageTextByteCount = 0
        for operation in operations {
            switch operation {
            case let .upsertThread(thread):
                try validateIdentifier(thread.id, name: "threadID")
                try validateDate(thread.createdAt, name: "thread createdAt")
                try validateDate(thread.updatedAt, name: "thread updatedAt")
            case let .upsertSummary(threadID, summary):
                try validateIdentifier(threadID, name: "threadID")
                guard summary.threadID == threadID else {
                    throw invalid("summary threadID must match its owning thread")
                }
                try validateDate(summary.createdAt, name: "summary createdAt")
                try validateDate(summary.updatedAt, name: "summary updatedAt")
                if let itemCount = summary.itemCount, itemCount < 0 {
                    throw invalid("summary itemCount must be nonnegative")
                }
                try AgentStoredPayloadValidator.validateSummary(summary)
            case let .appendHistoryItems(threadID, items),
                 let .restoreHistoryItems(threadID, items):
                try validateIdentifier(threadID, name: "threadID")
                guard items.count <= AgentStoreLimits.maximumHistoryWriteCount else {
                    throw invalid(
                        "a history write must not exceed \(AgentStoreLimits.maximumHistoryWriteCount) records"
                    )
                }
                try validateHistoryItems(
                    items,
                    threadID: threadID,
                    attachmentCount: &attachmentCount,
                    attachmentByteCount: &attachmentByteCount,
                    messageTextByteCount: &messageTextByteCount
                )
            case let .appendCompactionMarker(threadID, marker):
                try validateIdentifier(threadID, name: "threadID")
                try validateHistoryItems(
                    [marker],
                    threadID: threadID,
                    attachmentCount: &attachmentCount,
                    attachmentByteCount: &attachmentByteCount,
                    messageTextByteCount: &messageTextByteCount
                )
            case let .upsertThreadContextState(threadID, state):
                try validateIdentifier(threadID, name: "threadID")
                if let state {
                    guard state.threadID == threadID else {
                        throw invalid("context-state threadID must match its owning thread")
                    }
                    guard state.effectiveMessages.count <= AgentStoreLimits.maximumContextMessageCount else {
                        throw invalid(
                            "context state must not exceed \(AgentStoreLimits.maximumContextMessageCount) messages"
                        )
                    }
                    guard state.generation >= 0 else {
                        throw invalid("context generation must be nonnegative")
                    }
                    try validateContextTextBudget(state)
                    for message in state.effectiveMessages {
                        try validateMessage(
                            message,
                            threadID: threadID,
                            attachmentCount: &attachmentCount,
                            attachmentByteCount: &attachmentByteCount,
                            messageTextByteCount: &messageTextByteCount
                        )
                    }
                    try AgentStoredPayloadValidator.validateContext(state)
                }
            case let .setPendingState(threadID, state):
                try validateIdentifier(threadID, name: "threadID")
                if let state {
                    try AgentStoredPayloadValidator.validatePendingState(
                        state,
                        expectedThreadID: threadID
                    )
                }
            case let .setPartialStructuredSnapshot(threadID, snapshot):
                try validateIdentifier(threadID, name: "threadID")
                if let snapshot {
                    try AgentStoredPayloadValidator.validatePartialSnapshot(snapshot)
                }
            case let .upsertToolSession(threadID, session):
                try validateIdentifier(threadID, name: "threadID")
                guard session.threadID == threadID else {
                    throw invalid("tool-session threadID must match its owning thread")
                }
                try validateIdentifier(session.invocationID, name: "invocationID")
                try validateIdentifier(session.turnID, name: "turnID")
                try validateIdentifier(session.toolName, name: "toolName")
                try validateDate(session.updatedAt, name: "tool-session updatedAt")
                try AgentStoredPayloadValidator.validateToolSession(session)
            case let .redactHistoryItems(threadID, itemIDs, _):
                try validateIdentifier(threadID, name: "threadID")
                guard itemIDs.count <= AgentStoreLimits.maximumRedactionIdentifierCount else {
                    throw invalid(
                        "a redaction must not exceed \(AgentStoreLimits.maximumRedactionIdentifierCount) identifiers"
                    )
                }
                try validateIdentifiers(Set(itemIDs), name: "redaction identifiers")
            default:
                try validateIdentifier(operation.affectedThreadID, name: "threadID")
            }
        }
    }

    package static func boundedLimit(_ limit: Int) -> Int {
        min(max(1, limit), AgentStoreLimits.maximumQueryResultCount)
    }

    package static func boundedOptionalLimit(_ limit: Int?) -> Int {
        min(
            max(0, limit ?? AgentStoreLimits.defaultListResultCount),
            AgentStoreLimits.maximumQueryResultCount
        )
    }

    private static func validate(_ page: AgentQueryPage?) throws {
        guard let page else { return }
        try validateLimit(page.limit)
        if let cursor = page.cursor {
            guard cursor.rawValue.utf8.count <= AgentStoreLimits.maximumCursorByteCount else {
                throw invalid("history cursor is too large")
            }
        }
    }

    private static func validateLimit(_ limit: Int) throws {
        guard (1 ... AgentStoreLimits.maximumQueryResultCount).contains(limit) else {
            throw invalid(
                "query limit must be between 1 and \(AgentStoreLimits.maximumQueryResultCount)"
            )
        }
    }

    private static func validateOptionalLimit(_ limit: Int?) throws {
        guard let limit else { return }
        guard (0 ... AgentStoreLimits.maximumQueryResultCount).contains(limit) else {
            throw invalid(
                "query limit must be between 0 and \(AgentStoreLimits.maximumQueryResultCount)"
            )
        }
    }

    private static func validateIdentifiers(
        _ values: Set<String>?,
        name: String
    ) throws {
        guard let values else { return }
        guard values.count <= AgentStoreLimits.maximumQueryFilterValueCount else {
            throw invalid(
                "\(name) must not contain more than \(AgentStoreLimits.maximumQueryFilterValueCount) values"
            )
        }
        for value in values { try validateIdentifier(value, name: name) }
    }

    private static func validateIdentifier(_ value: String, name: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
            throw invalid(
                "\(name) must be nonempty and at most \(AgentStoreLimits.maximumIdentifierByteCount) UTF-8 bytes"
            )
        }
    }

    private static func validateHistoryItems(
        _ items: [AgentHistoryRecord],
        threadID: String,
        attachmentCount: inout Int,
        attachmentByteCount: inout Int,
        messageTextByteCount: inout Int
    ) throws {
        for item in items {
            try validateIdentifier(item.id, name: "history record ID")
            guard item.item.threadID == threadID else {
                throw invalid("history item threadID must match its owning thread")
            }
            try validateDate(item.createdAt, name: "history createdAt")
            if case let .message(message) = item.item {
                try validateMessage(
                    message,
                    threadID: threadID,
                    attachmentCount: &attachmentCount,
                    attachmentByteCount: &attachmentByteCount,
                    messageTextByteCount: &messageTextByteCount
                )
            }
            try AgentStoredPayloadValidator.validateHistoryItem(
                item.item,
                expectedThreadID: threadID
            )
        }
    }

    private static func validateMessage(
        _ message: AgentMessage,
        threadID: String,
        attachmentCount: inout Int,
        attachmentByteCount: inout Int,
        messageTextByteCount: inout Int
    ) throws {
        guard message.threadID == threadID else {
            throw invalid("message threadID must match its owning thread")
        }
        try validateIdentifier(message.id, name: "message ID")
        try validateDate(message.createdAt, name: "message createdAt")
        guard message.text.utf8.count <= AgentStoreLimits.maximumMessageTextByteCount else {
            throw invalid(
                "message text must not exceed \(AgentStoreLimits.maximumMessageTextByteCount) UTF-8 bytes"
            )
        }
        let (nextTextByteCount, textOverflow) = messageTextByteCount
            .addingReportingOverflow(message.text.utf8.count)
        guard !textOverflow,
              nextTextByteCount <= AgentStoreLimits.maximumMessageTextBytesPerWrite else {
            throw invalid("message text in a write batch exceeds its bounded limit")
        }
        messageTextByteCount = nextTextByteCount
        try AgentStoredPayloadValidator.validateMessage(message)
        guard message.images.count <= AgentStoreLimits.maximumImageCountPerMessage else {
            throw invalid(
                "a message must not exceed \(AgentStoreLimits.maximumImageCountPerMessage) images"
            )
        }
        for image in message.images {
            try validateIdentifier(image.id, name: "image ID")
            try validateIdentifier(image.mimeType.rawValue, name: "image MIME type")
            guard image.data.count <= AgentStoreLimits.maximumImageByteCount else {
                throw invalid(
                    "an image must not exceed \(AgentStoreLimits.maximumImageByteCount) bytes"
                )
            }
            let (nextCount, countOverflow) = attachmentCount.addingReportingOverflow(1)
            let (nextBytes, byteOverflow) = attachmentByteCount.addingReportingOverflow(
                image.data.count
            )
            guard !countOverflow, !byteOverflow,
                  nextCount <= AgentStoreLimits.maximumImageCountPerWrite,
                  nextBytes <= AgentStoreLimits.maximumImageBytesPerWrite else {
                throw invalid("an attachment write batch exceeds its bounded limits")
            }
            attachmentCount = nextCount
            attachmentByteCount = nextBytes
        }
    }

    private static func validateContextTextBudget(
        _ state: AgentThreadContextState
    ) throws {
        var byteCount = 0
        for message in state.effectiveMessages {
            let (updated, overflow) = byteCount.addingReportingOverflow(
                message.text.utf8.count
            )
            guard !overflow,
                  updated <= AgentStoreLimits.maximumContextMessageTextByteCount else {
                throw invalid(
                    "context message text must not exceed \(AgentStoreLimits.maximumContextMessageTextByteCount) UTF-8 bytes"
                )
            }
            byteCount = updated
        }
    }

    private static func validateDateRange(
        _ range: ClosedRange<Date>?,
        name: String
    ) throws {
        guard let range else { return }
        try validateDate(range.lowerBound, name: name)
        try validateDate(range.upperBound, name: name)
    }

    private static func validateDate(_ date: Date, name: String) throws {
        guard date.timeIntervalSince1970.isFinite else {
            throw invalid("\(name) must be finite")
        }
    }

    private static func invalid(_ message: String) -> AgentStoreError {
        .invalidInput(message)
    }
}
