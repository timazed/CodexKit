import Foundation

package struct PersistedImageAttachment: Codable, Hashable {
    let id: String
    let mimeType: String
    let storageKey: String
    let generationMetadata: AgentImageGenerationMetadata?
}

package struct PersistedAgentMessage: Codable, Hashable {
    let id: String
    let threadID: String
    let phase: AgentMessagePhase?
    let role: AgentRole
    let text: String
    let images: [PersistedImageAttachment]
    let structuredOutput: AgentStructuredOutputMetadata?
    let toolInteraction: PersistedAgentToolInteraction?
    let createdAt: Date

    package var attachmentStorageKeys: [String] {
        images.map(\.storageKey) + (toolInteraction?.attachmentStorageKeys ?? [])
    }

    package init(
        message: AgentMessage,
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments? = nil
    ) throws {
        try attachmentStore.validateAttachments(in: [message])
        self.id = message.id
        self.threadID = message.threadID
        self.phase = message.phase
        self.role = message.role
        self.text = message.text
        self.images = try message.images.enumerated().map { index, attachment in
            if let preparedAttachments {
                try preparedAttachments.reference(
                    for: attachment,
                    threadID: message.threadID,
                    recordID: message.id,
                    index: index
                )
            } else {
                try attachmentStore.persist(
                    attachment,
                    threadID: message.threadID,
                    recordID: message.id,
                    index: index
                )
            }
        }
        self.structuredOutput = message.structuredOutput
        self.toolInteraction = try message.toolInteraction.map {
            try PersistedAgentToolInteraction(
                interaction: $0,
                message: message,
                attachmentStore: attachmentStore,
                preparedAttachments: preparedAttachments
            )
        }
        self.createdAt = message.createdAt
    }

    package func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentMessage {
        try validate(using: attachmentStore)
        return AgentMessage(
            id: id,
            threadID: threadID,
            role: role,
            text: text,
            images: try images.map { try attachmentStore.load($0) },
            phase: phase,
            structuredOutput: structuredOutput,
            toolInteraction: try toolInteraction?.decode(using: attachmentStore),
            createdAt: createdAt
        )
    }

    package func decodeForProjection(
        using attachmentStore: RuntimeAttachmentStore
    ) throws -> AgentMessage {
        try validate(using: attachmentStore)
        return AgentMessage(
            id: id,
            threadID: threadID,
            role: role,
            text: text,
            images: images.map {
                AgentImageAttachment(
                    id: $0.id,
                    mimeType: $0.mimeType,
                    data: Data(),
                    generationMetadata: $0.generationMetadata
                )
            },
            phase: phase,
            structuredOutput: structuredOutput,
            toolInteraction: try toolInteraction?.decodeForProjection(),
            createdAt: createdAt
        )
    }

    package func validate(using attachmentStore: RuntimeAttachmentStore) throws {
        guard !id.isEmpty,
              id.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount,
              !threadID.isEmpty,
              threadID.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount,
              text.utf8.count <= AgentStoreLimits.maximumMessageTextByteCount,
              images.count <= AgentStoreLimits.maximumImageCountPerMessage,
              createdAt.timeIntervalSince1970.isFinite else {
            throw AgentStoreError.invalidInput("stored message metadata exceeds its bounded limits")
        }
        for image in images {
            guard !image.id.isEmpty,
                  image.id.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount,
                  !image.mimeType.isEmpty,
                  image.mimeType.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
                throw AgentStoreError.invalidInput("stored image metadata is invalid")
            }
            try attachmentStore.validateStorageKey(image.storageKey)
        }
        try toolInteraction?.result.validate(using: attachmentStore)
    }
}

package struct PersistedAgentThreadContextState: Codable, Hashable {
    let threadID: String
    let effectiveMessages: [PersistedAgentMessage]
    let providerContext: AgentProviderContext?
    let generation: Int
    let lastCompactedAt: Date?
    let lastCompactionReason: AgentContextCompactionReason?
    let latestMarkerID: String?

    package var attachmentStorageKeys: [String] {
        effectiveMessages.flatMap(\.attachmentStorageKeys)
    }

    package init(
        state: AgentThreadContextState,
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments? = nil
    ) throws {
        self.threadID = state.threadID
        self.effectiveMessages = try state.effectiveMessages.map {
            try PersistedAgentMessage(
                message: $0,
                attachmentStore: attachmentStore,
                preparedAttachments: preparedAttachments
            )
        }
        self.providerContext = state.providerContext
        self.generation = state.generation
        self.lastCompactedAt = state.lastCompactedAt
        self.lastCompactionReason = state.lastCompactionReason
        self.latestMarkerID = state.latestMarkerID
    }

    package func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentThreadContextState {
        try validate(using: attachmentStore)
        return AgentThreadContextState(
            threadID: threadID,
            effectiveMessages: try effectiveMessages.map { try $0.decode(using: attachmentStore) },
            providerContext: providerContext,
            generation: generation,
            lastCompactedAt: lastCompactedAt,
            lastCompactionReason: lastCompactionReason,
            latestMarkerID: latestMarkerID
        )
    }

    package func validate(using attachmentStore: RuntimeAttachmentStore) throws {
        guard effectiveMessages.count <= AgentStoreLimits.maximumContextMessageCount,
              generation >= 0,
              lastCompactedAt?.timeIntervalSince1970.isFinite ?? true else {
            throw AgentStoreError.invalidInput("stored context state exceeds its bounded limits")
        }
        for message in effectiveMessages {
            try message.validate(using: attachmentStore)
            guard message.threadID == threadID else {
                throw AgentStoreError.invalidInput(
                    "stored context message belongs to a different thread"
                )
            }
        }
    }
}

package enum PersistedAgentHistoryItem: Hashable {
    case message(PersistedAgentMessage)
    case toolCall(AgentToolCallRecord)
    case toolResult(PersistedAgentToolResultRecord)
    case structuredOutput(AgentStructuredOutputRecord)
    case approval(AgentApprovalRecord)
    case systemEvent(PersistedAgentSystemEventRecord)

    package var attachmentStorageKeys: [String] {
        switch self {
        case let .message(message):
            message.attachmentStorageKeys
        case let .toolResult(record):
            record.attachmentStorageKeys
        case .systemEvent:
            []
        case .toolCall, .structuredOutput, .approval:
            []
        }
    }

    package init(
        item: AgentHistoryItem,
        historyRecordID: String,
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments? = nil
    ) throws {
        switch item {
        case let .message(message):
            self = .message(try PersistedAgentMessage(
                message: message,
                attachmentStore: attachmentStore,
                preparedAttachments: preparedAttachments
            ))
        case let .toolCall(record):
            self = .toolCall(record)
        case let .toolResult(record):
            self = .toolResult(try PersistedAgentToolResultRecord(
                record: record,
                historyRecordID: historyRecordID,
                attachmentStore: attachmentStore,
                preparedAttachments: preparedAttachments
            ))
        case let .structuredOutput(record):
            self = .structuredOutput(record)
        case let .approval(record):
            self = .approval(record)
        case let .systemEvent(record):
            self = .systemEvent(PersistedAgentSystemEventRecord(record: record))
        }
    }

    package func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentHistoryItem {
        switch self {
        case let .message(message):
            return .message(try message.decode(using: attachmentStore))
        case let .toolCall(record):
            return .toolCall(record)
        case let .toolResult(record):
            return .toolResult(try record.decode(using: attachmentStore))
        case let .structuredOutput(record):
            return .structuredOutput(record)
        case let .approval(record):
            return .approval(record)
        case let .systemEvent(record):
            return .systemEvent(try record.decode(using: attachmentStore))
        }
    }

    package func decodeForProjection(
        using attachmentStore: RuntimeAttachmentStore
    ) throws -> AgentHistoryItem {
        switch self {
        case let .message(message):
            .message(try message.decodeForProjection(using: attachmentStore))
        case let .toolCall(record):
            .toolCall(record)
        case let .toolResult(record):
            .toolResult(try record.decodeForProjection())
        case let .structuredOutput(record):
            .structuredOutput(record)
        case let .approval(record):
            .approval(record)
        case let .systemEvent(record):
            .systemEvent(record.decodeForProjection())
        }
    }

    package func validateAttachmentReferences(
        using attachmentStore: RuntimeAttachmentStore
    ) throws {
        switch self {
        case let .message(message):
            try message.validate(using: attachmentStore)
        case let .toolResult(record):
            try record.result.validate(using: attachmentStore)
        case .approval, .structuredOutput, .systemEvent, .toolCall:
            break
        }
    }
}

extension PersistedAgentHistoryItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case message
        case toolCall
        case toolResult
        case structuredOutput
        case approval
        case systemEvent
    }

    private enum Kind: String, Codable {
        case message
        case toolCall
        case toolResult
        case structuredOutput
        case approval
        case systemEvent
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .message:
            self = .message(try container.decode(PersistedAgentMessage.self, forKey: .message))
        case .toolCall:
            self = .toolCall(try container.decode(AgentToolCallRecord.self, forKey: .toolCall))
        case .toolResult:
            self = .toolResult(try container.decode(
                PersistedAgentToolResultRecord.self,
                forKey: .toolResult
            ))
        case .structuredOutput:
            self = .structuredOutput(try container.decode(AgentStructuredOutputRecord.self, forKey: .structuredOutput))
        case .approval:
            self = .approval(try container.decode(AgentApprovalRecord.self, forKey: .approval))
        case .systemEvent:
            self = .systemEvent(try container.decode(
                PersistedAgentSystemEventRecord.self,
                forKey: .systemEvent
            ))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .message(message):
            try container.encode(Kind.message, forKey: .kind)
            try container.encode(message, forKey: .message)
        case let .toolCall(record):
            try container.encode(Kind.toolCall, forKey: .kind)
            try container.encode(record, forKey: .toolCall)
        case let .toolResult(record):
            try container.encode(Kind.toolResult, forKey: .kind)
            try container.encode(record, forKey: .toolResult)
        case let .structuredOutput(record):
            try container.encode(Kind.structuredOutput, forKey: .kind)
            try container.encode(record, forKey: .structuredOutput)
        case let .approval(record):
            try container.encode(Kind.approval, forKey: .kind)
            try container.encode(record, forKey: .approval)
        case let .systemEvent(record):
            try container.encode(Kind.systemEvent, forKey: .kind)
            try container.encode(record, forKey: .systemEvent)
        }
    }
}

package struct PersistedAgentHistoryRecord: Codable, Hashable {
    let id: String
    let sequenceNumber: Int
    let createdAt: Date
    let item: PersistedAgentHistoryItem
    let redaction: AgentHistoryRedaction?

    package var projectedRecordID: String { id }

    package var attachmentRecordIDs: [String] {
        switch item {
        case let .message(message):
            [message.id]
        case .toolCall, .toolResult, .structuredOutput, .approval, .systemEvent:
            []
        }
    }

    package var attachmentStorageKeys: [String] {
        item.attachmentStorageKeys
    }

    package func validateAttachmentReferences(
        using attachmentStore: RuntimeAttachmentStore
    ) throws {
        try item.validateAttachmentReferences(using: attachmentStore)
    }

    package var projectedTurnID: String? {
        switch item {
        case .message:
            nil
        case let .toolCall(record):
            record.invocation.turnID
        case let .toolResult(record):
            record.turnID
        case let .structuredOutput(record):
            record.turnID
        case let .approval(record):
            record.request?.turnID ?? record.resolution?.turnID
        case let .systemEvent(record):
            record.turnID
        }
    }

    package var projectedIsCompactionMarker: Bool {
        guard case let .systemEvent(record) = item else {
            return false
        }
        return record.type == .contextCompacted
    }

    package var projectedStructuredOutput: AgentStructuredOutputRecord? {
        switch item {
        case let .structuredOutput(record):
            return record
        case let .message(message):
            guard let metadata = message.structuredOutput else {
                return nil
            }
            return AgentStructuredOutputRecord(
                threadID: message.threadID,
                turnID: "",
                messageID: message.id,
                metadata: metadata,
                committedAt: message.createdAt
            )
        case .toolCall, .toolResult, .approval, .systemEvent:
            return nil
        }
    }

    package init(
        record: AgentHistoryRecord,
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments? = nil
    ) throws {
        self.id = record.id
        self.sequenceNumber = record.sequenceNumber
        self.createdAt = record.createdAt
        self.item = try PersistedAgentHistoryItem(
            item: record.item,
            historyRecordID: record.id,
            attachmentStore: attachmentStore,
            preparedAttachments: preparedAttachments
        )
        self.redaction = record.redaction
    }

    package func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentHistoryRecord {
        AgentHistoryRecord(
            id: id,
            sequenceNumber: sequenceNumber,
            createdAt: createdAt,
            item: try item.decode(using: attachmentStore),
            redaction: redaction
        )
    }

    package func decodeForProjection(
        using attachmentStore: RuntimeAttachmentStore
    ) throws -> AgentHistoryRecord {
        AgentHistoryRecord(
            id: id,
            sequenceNumber: sequenceNumber,
            createdAt: createdAt,
            item: try item.decodeForProjection(using: attachmentStore),
            redaction: redaction
        )
    }
}
