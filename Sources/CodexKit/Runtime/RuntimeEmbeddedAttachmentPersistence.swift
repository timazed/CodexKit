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

package struct PersistedAgentTurnRecoveryCheckpoint: Codable, Hashable {
    let providerID: String
    let threadID: String
    let turnID: String
    let request: Request
    let requestImages: [PersistedImageAttachment]
    let payload: JSONValue
    let providerAttachments: [PersistedImageAttachment]
    let createdAt: Date

    init(
        checkpoint: AgentTurnRecoveryCheckpoint,
        historyRecordID: String,
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments?
    ) throws {
        providerID = checkpoint.providerID
        threadID = checkpoint.threadID
        turnID = checkpoint.turnID
        var requestWithoutImages = checkpoint.request
        requestWithoutImages.images = []
        request = requestWithoutImages
        payload = checkpoint.payload
        createdAt = checkpoint.createdAt
        requestImages = try checkpoint.request.images.enumerated().map { index, attachment in
            try persistedAttachmentReference(
                for: attachment,
                threadID: checkpoint.threadID,
                carrierID: RuntimeEmbeddedAttachmentCollector.recoveryRequestCarrierID(historyRecordID),
                index: index,
                attachmentStore: attachmentStore,
                preparedAttachments: preparedAttachments
            )
        }
        providerAttachments = try checkpoint.providerAttachments.enumerated().map { index, attachment in
            try persistedAttachmentReference(
                for: attachment,
                threadID: checkpoint.threadID,
                carrierID: RuntimeEmbeddedAttachmentCollector.recoveryProviderCarrierID(historyRecordID),
                index: index,
                attachmentStore: attachmentStore,
                preparedAttachments: preparedAttachments
            )
        }
    }

    var attachmentStorageKeys: [String] {
        (requestImages + providerAttachments).map(\.storageKey)
    }

    func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentTurnRecoveryCheckpoint {
        var restoredRequest = request
        restoredRequest.images = try requestImages.map(attachmentStore.load)
        return AgentTurnRecoveryCheckpoint(
            providerID: providerID,
            threadID: threadID,
            turnID: turnID,
            request: restoredRequest,
            payload: payload,
            providerAttachments: try providerAttachments.map(attachmentStore.load),
            createdAt: createdAt
        )
    }

    func decodeForProjection() -> AgentTurnRecoveryCheckpoint {
        AgentTurnRecoveryCheckpoint(
            providerID: providerID,
            threadID: threadID,
            turnID: turnID,
            request: request,
            payload: payload,
            createdAt: createdAt
        )
    }
}

package struct PersistedAgentSystemEventRecord: Codable, Hashable {
    let type: AgentSystemEventType
    let threadID: String
    let turnID: String?
    let status: AgentThreadStatus?
    let turnSummary: AgentTurnSummary?
    let error: AgentRuntimeError?
    let recoveryCheckpoint: PersistedAgentTurnRecoveryCheckpoint?
    let compaction: AgentContextCompactionMarker?
    let occurredAt: Date

    init(
        record: AgentSystemEventRecord,
        historyRecordID: String,
        attachmentStore: RuntimeAttachmentStore,
        preparedAttachments: RuntimePreparedAttachments?
    ) throws {
        type = record.type
        threadID = record.threadID
        turnID = record.turnID
        status = record.status
        turnSummary = record.turnSummary
        error = record.error
        compaction = record.compaction
        occurredAt = record.occurredAt
        recoveryCheckpoint = try record.recoveryCheckpoint.map {
            try PersistedAgentTurnRecoveryCheckpoint(
                checkpoint: $0,
                historyRecordID: historyRecordID,
                attachmentStore: attachmentStore,
                preparedAttachments: preparedAttachments
            )
        }
    }

    var attachmentStorageKeys: [String] {
        recoveryCheckpoint?.attachmentStorageKeys ?? []
    }

    func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentSystemEventRecord {
        AgentSystemEventRecord(
            type: type,
            threadID: threadID,
            turnID: turnID,
            status: status,
            turnSummary: turnSummary,
            error: error,
            recoveryCheckpoint: try recoveryCheckpoint?.decode(using: attachmentStore),
            compaction: compaction,
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
            recoveryCheckpoint: recoveryCheckpoint?.decodeForProjection(),
            compaction: compaction,
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
        case let .systemEvent(event):
            guard let checkpoint = event.recoveryCheckpoint else { return [] }
            return [
                AgentMessage(
                    id: recoveryRequestCarrierID(record.id),
                    threadID: checkpoint.threadID,
                    role: .system,
                    text: "",
                    images: checkpoint.request.images
                ),
                AgentMessage(
                    id: recoveryProviderCarrierID(record.id),
                    threadID: checkpoint.threadID,
                    role: .system,
                    text: "",
                    images: checkpoint.providerAttachments
                ),
            ]
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

    static func recoveryRequestCarrierID(_ recordID: String) -> String {
        carrierID(recordID, kind: "recovery-request")
    }

    static func recoveryProviderCarrierID(_ recordID: String) -> String {
        carrierID(recordID, kind: "recovery-provider")
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
