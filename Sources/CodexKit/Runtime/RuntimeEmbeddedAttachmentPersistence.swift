import Foundation

package enum PersistedToolResultContent: Codable, Hashable {
    case text(String)
    case image(URL)
    case storedImage(PersistedImageAttachment)
}

package struct PersistedToolResultEnvelope: Codable, Hashable {
    let invocationID: String
    let toolName: String
    let success: Bool
    let content: [PersistedToolResultContent]
    let errorMessage: String?
    let session: ToolSessionDescriptor?

    init(
        result: ToolResultEnvelope,
        threadID: String,
        carrierID: String,
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments?
    ) throws {
        invocationID = result.invocationID
        toolName = result.toolName
        success = result.success
        errorMessage = result.errorMessage
        session = result.session
        var inlineIndex = 0
        content = try result.content.map { value in
            switch value {
            case let .text(text):
                return .text(text)
            case let .image(url):
                guard url.scheme?.lowercased() == "data" else {
                    return .image(url)
                }
                let attachment = try RuntimeEmbeddedAttachmentCollector.inlineAttachment(
                    from: url,
                    carrierID: carrierID,
                    index: inlineIndex
                )
                defer { inlineIndex += 1 }
                return .storedImage(try persistedAttachmentReference(
                    for: attachment,
                    threadID: threadID,
                    carrierID: carrierID,
                    index: inlineIndex,
                    attachmentStore: attachmentStore,
                    preparedAttachments: preparedAttachments
                ))
            }
        }
    }

    var attachmentStorageKeys: [String] {
        content.compactMap { value in
            guard case let .storedImage(image) = value else { return nil }
            return image.storageKey
        }
    }

    func decode(using attachmentStore: RuntimeAttachmentStore) throws -> ToolResultEnvelope {
        ToolResultEnvelope(
            invocationID: invocationID,
            toolName: toolName,
            success: success,
            content: try content.map { value in
                switch value {
                case let .text(text):
                    return .text(text)
                case let .image(url):
                    return .image(url)
                case let .storedImage(reference):
                    let attachment = try attachmentStore.load(reference)
                    guard let url = URL(string: attachment.dataURLString) else {
                        throw AgentStoreError.invalidInput("stored tool image URL is invalid")
                    }
                    return .image(url)
                }
            },
            errorMessage: errorMessage,
            session: session
        )
    }

    func decodeForProjection() throws -> ToolResultEnvelope {
        ToolResultEnvelope(
            invocationID: invocationID,
            toolName: toolName,
            success: success,
            content: try content.map { value in
                switch value {
                case let .text(text):
                    return .text(text)
                case let .image(url):
                    return .image(url)
                case let .storedImage(reference):
                    guard let url = URL(
                        string: "codexkit-attachment://" + reference.storageKey
                    ) else {
                        throw AgentStoreError.invalidInput("stored tool image reference is invalid")
                    }
                    return .image(url)
                }
            },
            errorMessage: errorMessage,
            session: session
        )
    }

    func validate(using attachmentStore: RuntimeAttachmentStore) throws {
        for storageKey in attachmentStorageKeys {
            try attachmentStore.validateStorageKey(storageKey)
        }
    }
}

package struct PersistedAgentToolResultRecord: Codable, Hashable {
    let threadID: String
    let turnID: String
    let result: PersistedToolResultEnvelope
    let completedAt: Date

    init(
        record: AgentToolResultRecord,
        historyRecordID: String,
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments?
    ) throws {
        threadID = record.threadID
        turnID = record.turnID
        completedAt = record.completedAt
        result = try PersistedToolResultEnvelope(
            result: record.result,
            threadID: record.threadID,
            carrierID: RuntimeEmbeddedAttachmentCollector.toolResultCarrierID(historyRecordID),
            attachmentStore: attachmentStore,
            preparedAttachments: preparedAttachments
        )
    }

    var attachmentStorageKeys: [String] { result.attachmentStorageKeys }

    func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentToolResultRecord {
        AgentToolResultRecord(
            threadID: threadID,
            turnID: turnID,
            result: try result.decode(using: attachmentStore),
            completedAt: completedAt
        )
    }

    func decodeForProjection() throws -> AgentToolResultRecord {
        AgentToolResultRecord(
            threadID: threadID,
            turnID: turnID,
            result: try result.decodeForProjection(),
            completedAt: completedAt
        )
    }
}

package struct PersistedAgentToolInteraction: Codable, Hashable {
    let invocation: ToolInvocation
    let result: PersistedToolResultEnvelope

    init(
        interaction: AgentToolInteraction,
        message: AgentMessage,
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments?
    ) throws {
        invocation = interaction.invocation
        result = try PersistedToolResultEnvelope(
            result: interaction.result,
            threadID: message.threadID,
            carrierID: RuntimeEmbeddedAttachmentCollector.toolInteractionCarrierID(message.id),
            attachmentStore: attachmentStore,
            preparedAttachments: preparedAttachments
        )
    }

    var attachmentStorageKeys: [String] { result.attachmentStorageKeys }

    func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentToolInteraction {
        AgentToolInteraction(
            invocation: invocation,
            result: try result.decode(using: attachmentStore)
        )
    }

    func decodeForProjection() throws -> AgentToolInteraction {
        AgentToolInteraction(invocation: invocation, result: try result.decodeForProjection())
    }
}

package struct PersistedAgentSystemEventRecord: Codable, Hashable {
    let type: AgentSystemEventType
    let threadID: String
    let turnID: String?
    let status: AgentThreadStatus?
    let turnSummary: AgentTurnSummary?
    let error: AgentRuntimeError?
    let compaction: AgentContextCompactionMarker?
    let memoryApplication: MemoryApplicationSnapshot?
    let memoryCompactionApplication: MemoryCompactionApplicationSnapshot?
    let occurredAt: Date

    init(
        record: AgentSystemEventRecord
    ) {
        type = record.type
        threadID = record.threadID
        turnID = record.turnID
        status = record.status
        turnSummary = record.turnSummary
        error = record.error
        compaction = record.compaction
        memoryApplication = record.memoryApplication
        memoryCompactionApplication = record.memoryCompactionApplication
        occurredAt = record.occurredAt
    }

    func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentSystemEventRecord {
        AgentSystemEventRecord(
            type: type,
            threadID: threadID,
            turnID: turnID,
            status: status,
            turnSummary: turnSummary,
            error: error,
            compaction: compaction,
            memoryApplication: memoryApplication,
            memoryCompactionApplication: memoryCompactionApplication,
            occurredAt: occurredAt
        )
    }

    func decodeForProjection() -> AgentSystemEventRecord {
        AgentSystemEventRecord(
            type: type,
            threadID: threadID,
            turnID: turnID,
            status: status,
            turnSummary: turnSummary,
            error: error,
            compaction: compaction,
            memoryApplication: memoryApplication,
            memoryCompactionApplication: memoryCompactionApplication,
            occurredAt: occurredAt
        )
    }
}

package enum RuntimeEmbeddedAttachmentCollector {
    static func messages(for record: AgentHistoryRecord) throws -> [AgentMessage] {
        switch record.item {
        case let .toolResult(result):
            return try carrierMessages(
                result: result.result,
                threadID: result.threadID,
                carrierID: toolResultCarrierID(record.id)
            )
        case .systemEvent:
            return []
        default:
            return []
        }
    }

    static func messages(for message: AgentMessage) throws -> [AgentMessage] {
        guard let interaction = message.toolInteraction else { return [] }
        return try carrierMessages(
            result: interaction.result,
            threadID: message.threadID,
            carrierID: toolInteractionCarrierID(message.id)
        )
    }

    static func toolResultCarrierID(_ recordID: String) -> String {
        carrierID(recordID, kind: "tool-result")
    }

    static func toolInteractionCarrierID(_ messageID: String) -> String {
        carrierID(messageID, kind: "tool-interaction")
    }

    static func inlineAttachment(
        from url: URL,
        carrierID: String,
        index: Int
    ) throws -> AgentImageAttachment {
        let id = "embedded-\(index)-\(RuntimeAttachmentStore.safePathComponent(carrierID))"
        guard let attachment = AgentImageAttachment(dataURLString: url.absoluteString, id: id) else {
            throw AgentStoreError.invalidInput("inline tool image data URL is invalid")
        }
        return attachment
    }

    private static func carrierMessages(
        result: ToolResultEnvelope,
        threadID: String,
        carrierID: String
    ) throws -> [AgentMessage] {
        var images: [AgentImageAttachment] = []
        for value in result.content {
            guard case let .image(url) = value,
                  url.scheme?.lowercased() == "data" else {
                continue
            }
            images.append(try inlineAttachment(
                from: url,
                carrierID: carrierID,
                index: images.count
            ))
        }
        guard !images.isEmpty else { return [] }
        return [AgentMessage(
            id: carrierID,
            threadID: threadID,
            role: .system,
            text: "",
            images: images
        )]
    }

    private static func carrierID(_ sourceID: String, kind: String) -> String {
        "embedded-\(kind)-\(RuntimeAttachmentStore.safePathComponent(sourceID))"
    }
}

private func persistedAttachmentReference(
    for attachment: AgentImageAttachment,
    threadID: String,
    carrierID: String,
    index: Int,
    attachmentStore: RuntimeAttachmentStore,
    preparedAttachments: RuntimePreparedAttachments?
) throws -> PersistedImageAttachment {
    if let preparedAttachments {
        return try preparedAttachments.reference(
            for: attachment,
            threadID: threadID,
            recordID: carrierID,
            index: index
        )
    }
    return try attachmentStore.persist(
        attachment,
        threadID: threadID,
        recordID: carrierID,
        index: index
    )
}
