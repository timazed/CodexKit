import CodexKit
import Foundation

struct RealmRuntimeStateStoreCodec: Sendable {
    let attachmentStore: RuntimeAttachmentStore
    let preparedAttachments: RuntimePreparedAttachments?

    init(
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments? = nil
    ) {
        self.attachmentStore = attachmentStore
        self.preparedAttachments = preparedAttachments
    }

    func makeThreadObject(
        from thread: AgentThread,
        nextHistorySequence: Int = 1
    ) throws -> RealmRuntimeThreadObject {
        let object = RealmRuntimeThreadObject()
        object.id = thread.id
        object.createdAt = thread.createdAt
        object.updatedAt = thread.updatedAt
        object.status = thread.status.rawValue
        object.nextHistorySequence = nextHistorySequence
        object.encodedThread = try encodeBoundedRuntimePayload(thread, name: "thread")
        return object
    }

    func makeSummaryObject(from summary: AgentThreadSummary) throws -> RealmRuntimeSummaryObject {
        let object = RealmRuntimeSummaryObject()
        object.threadID = summary.threadID
        object.createdAt = summary.createdAt
        object.updatedAt = summary.updatedAt
        object.pendingStateKind = summary.pendingState?.kind.rawValue
        object.encodedSummary = try encodeBoundedRuntimePayload(summary, name: "thread summary")
        return object
    }

    func makeHistoryObject(
        from record: AgentHistoryRecord,
        threadID: String
    ) throws -> RealmRuntimeHistoryObject {
        let persisted = try PersistedAgentHistoryRecord(
            record: record,
            attachmentStore: attachmentStore,
            preparedAttachments: preparedAttachments
        )
        let object = RealmRuntimeHistoryObject()
        object.key = Self.historyKey(threadID: threadID, sequenceNumber: record.sequenceNumber)
        object.recordID = record.id
        object.threadID = threadID
        object.sequenceNumber = record.sequenceNumber
        object.createdAt = record.createdAt
        object.kind = record.item.kind.rawValue
        object.turnID = record.item.turnID
        object.relationshipKey = record.item.relationshipKey
        object.isCompactionMarker = record.item.isCompactionMarker
        object.isRedacted = record.redaction != nil
        object.messageRole = record.item.messageRole?.rawValue
        object.hasStructuredOutput = record.item.hasQueryableStructuredOutput
        object.systemEventType = record.item.systemEventType?.rawValue
        object.encodedRecord = try encodeBoundedRuntimePayload(persisted, name: "history record")
        return object
    }

    func makeContextObject(from state: AgentThreadContextState) throws -> RealmRuntimeContextObject {
        let persisted = try PersistedAgentThreadContextState(
            state: state,
            attachmentStore: attachmentStore,
            preparedAttachments: preparedAttachments
        )
        let object = RealmRuntimeContextObject()
        object.threadID = state.threadID
        object.generation = state.generation
        object.encodedState = try encodeBoundedRuntimePayload(persisted, name: "context state")
        return object
    }

    func makeStructuredOutputObject(
        from record: AgentHistoryRecord,
        historyKey: String
    ) throws -> RealmRuntimeStructuredOutputObject? {
        let structuredRecord: AgentStructuredOutputRecord
        switch record.item {
        case let .structuredOutput(output):
            structuredRecord = output
        case let .message(message):
            guard let metadata = message.structuredOutput else {
                return nil
            }
            structuredRecord = AgentStructuredOutputRecord(
                threadID: message.threadID,
                turnID: "",
                messageID: message.id,
                metadata: metadata,
                committedAt: message.createdAt
            )
        default:
            return nil
        }

        return try makeStructuredOutputObject(
            from: structuredRecord,
            historyKey: historyKey
        )
    }

    func makeStructuredOutputObject(
        from structuredRecord: AgentStructuredOutputRecord,
        historyKey: String
    ) throws -> RealmRuntimeStructuredOutputObject {
        let object = RealmRuntimeStructuredOutputObject()
        object.key = historyKey
        object.threadID = structuredRecord.threadID
        object.formatName = structuredRecord.metadata.formatName
        object.committedAt = structuredRecord.committedAt
        object.encodedRecord = try encodeBoundedRuntimePayload(
            structuredRecord,
            name: "structured output"
        )
        return object
    }

    func decodeThread(from object: RealmRuntimeThreadObject) throws -> AgentThread {
        try validateBoundedRuntimePayload(object.encodedThread, name: "stored thread")
        let thread = try JSONDecoder().decode(AgentThread.self, from: object.encodedThread)
        try AgentStoreLimitValidator.validateLoadedThread(thread, expectedID: object.id)
        guard thread.createdAt == object.createdAt,
              thread.updatedAt == object.updatedAt,
              thread.status.rawValue == object.status else {
            throw AgentStoreError.invalidInput(
                "stored thread payload does not match its indexed projection"
            )
        }
        return thread
    }

    func decodeSummary(from object: RealmRuntimeSummaryObject) throws -> AgentThreadSummary {
        try validateBoundedRuntimePayload(object.encodedSummary, name: "stored summary")
        let summary = try JSONDecoder().decode(
            AgentThreadSummary.self,
            from: object.encodedSummary
        )
        try AgentStoreLimitValidator.validateLoadedSummary(
            summary,
            expectedThreadID: object.threadID
        )
        guard summary.createdAt == object.createdAt,
              summary.updatedAt == object.updatedAt,
              summary.pendingState?.kind.rawValue == object.pendingStateKind else {
            throw AgentStoreError.invalidInput(
                "stored summary payload does not match its indexed projection"
            )
        }
        return summary
    }

    func decodeHistoryRecord(from object: RealmRuntimeHistoryObject) throws -> AgentHistoryRecord {
        try validateBoundedRuntimePayload(object.encodedRecord, name: "stored history record")
        let persisted = try JSONDecoder().decode(
            PersistedAgentHistoryRecord.self,
            from: object.encodedRecord
        )
        let record = try persisted.decode(using: attachmentStore)
        try AgentStoreLimitValidator.validateLoadedHistoryRecord(
            record,
            expectedThreadID: object.threadID
        )
        try validateHistoryProjection(record, object: object)
        return record
    }

    func decodeHistoryRecordForProjection(
        from object: RealmRuntimeHistoryObject
    ) throws -> AgentHistoryRecord {
        let record = try decodePersistedHistory(from: object).decodeForProjection(
            using: attachmentStore
        )
        try AgentStoreLimitValidator.validateLoadedHistoryRecord(
            record,
            expectedThreadID: object.threadID
        )
        try validateHistoryProjection(record, object: object)
        return record
    }

    func attachmentStorageKeys(from object: RealmRuntimeHistoryObject) throws -> Set<String> {
        let persisted = try decodePersistedHistory(from: object)
        try persisted.validateAttachmentReferences(using: attachmentStore)
        return Set(persisted.attachmentStorageKeys)
    }

    func attachmentStorageKeys(from object: RealmRuntimeContextObject) throws -> Set<String> {
        try validateBoundedRuntimePayload(object.encodedState, name: "stored context state")
        let persisted = try JSONDecoder().decode(
            PersistedAgentThreadContextState.self,
            from: object.encodedState
        )
        try persisted.validate(using: attachmentStore)
        return Set(persisted.attachmentStorageKeys)
    }

    func projectedHistoryMetadata(
        from object: RealmRuntimeHistoryObject
    ) throws -> (
        recordID: String,
        turnID: String?,
        relationshipKey: String?,
        isCompactionMarker: Bool,
        messageRole: String?,
        hasStructuredOutput: Bool,
        systemEventType: String?,
        structuredOutput: AgentStructuredOutputRecord?
    ) {
        let persisted = try decodePersistedHistory(from: object)
        let record = try persisted.decodeForProjection(using: attachmentStore)
        return (
            persisted.projectedRecordID,
            persisted.projectedTurnID,
            record.item.relationshipKey,
            persisted.projectedIsCompactionMarker,
            record.item.messageRole?.rawValue,
            record.item.hasQueryableStructuredOutput,
            record.item.systemEventType?.rawValue,
            persisted.projectedStructuredOutput
        )
    }

    private func decodePersistedHistory(
        from object: RealmRuntimeHistoryObject
    ) throws -> PersistedAgentHistoryRecord {
        try validateBoundedRuntimePayload(object.encodedRecord, name: "stored history record")
        return try JSONDecoder().decode(
            PersistedAgentHistoryRecord.self,
            from: object.encodedRecord
        )
    }

    func decodeStructuredOutput(
        from object: RealmRuntimeStructuredOutputObject
    ) throws -> AgentStructuredOutputRecord {
        try validateBoundedRuntimePayload(object.encodedRecord, name: "stored structured output")
        let record = try JSONDecoder().decode(
            AgentStructuredOutputRecord.self,
            from: object.encodedRecord
        )
        try AgentStoreLimitValidator.validateLoadedStructuredOutput(
            record,
            expectedThreadID: object.threadID
        )
        guard record.metadata.formatName == object.formatName,
              record.committedAt == object.committedAt else {
            throw AgentStoreError.invalidInput(
                "stored structured output does not match its indexed projection"
            )
        }
        return record
    }

    func decodeContextState(from object: RealmRuntimeContextObject) throws -> AgentThreadContextState {
        try validateBoundedRuntimePayload(object.encodedState, name: "stored context state")
        let persisted = try JSONDecoder().decode(
            PersistedAgentThreadContextState.self,
            from: object.encodedState
        )
        let state = try persisted.decode(using: attachmentStore)
        try AgentStoreLimitValidator.validateLoadedContextState(
            state,
            expectedThreadID: object.threadID
        )
        guard state.generation == object.generation else {
            throw AgentStoreError.invalidInput(
                "stored context payload does not match its indexed projection"
            )
        }
        return state
    }

    private func validateHistoryProjection(
        _ record: AgentHistoryRecord,
        object: RealmRuntimeHistoryObject
    ) throws {
        guard record.id == object.recordID,
              record.sequenceNumber == object.sequenceNumber,
              record.createdAt == object.createdAt,
              record.item.kind.rawValue == object.kind,
              record.item.turnID == object.turnID,
              record.item.relationshipKey == object.relationshipKey,
              record.item.isCompactionMarker == object.isCompactionMarker,
              (record.redaction != nil) == object.isRedacted,
              record.item.messageRole?.rawValue == object.messageRole,
              record.item.hasQueryableStructuredOutput == object.hasStructuredOutput,
              record.item.systemEventType?.rawValue == object.systemEventType else {
            throw AgentStoreError.invalidInput(
                "stored history payload does not match its indexed projection"
            )
        }
    }

    static func historyKey(threadID: String, sequenceNumber: Int) -> String {
        "\(threadID):\(sequenceNumber)"
    }
}
