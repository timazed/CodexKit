import Foundation

struct RuntimeAttachmentStore: Sendable {
    let rootURL: URL

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func reset() throws {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        try prepare()
    }

    func removeThread(_ threadID: String) throws {
        let threadURL = rootURL.appendingPathComponent(sanitizedPathComponent(threadID), isDirectory: true)
        guard FileManager.default.fileExists(atPath: threadURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: threadURL)
    }

    func persist(
        _ attachment: AgentImageAttachment,
        threadID: String,
        recordID: String,
        index: Int
    ) throws -> PersistedImageAttachment {
        try prepare()

        let threadComponent = sanitizedPathComponent(threadID)
        let recordComponent = sanitizedPathComponent(recordID)
        let fileName = "\(index)-\(sanitizedPathComponent(attachment.id)).\(fileExtension(for: attachment.mimeType))"
        let relativePath = threadComponent + "/" + recordComponent + "/" + fileName
        let fileURL = rootURL
            .appendingPathComponent(threadComponent, isDirectory: true)
            .appendingPathComponent(recordComponent, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try attachment.data.write(to: fileURL, options: .atomic)

        return PersistedImageAttachment(
            id: attachment.id,
            mimeType: attachment.mimeType,
            storageKey: relativePath
        )
    }

    func load(_ attachment: PersistedImageAttachment) throws -> AgentImageAttachment {
        let fileURL = rootURL.appendingPathComponent(attachment.storageKey, isDirectory: false)
        let data = try Data(contentsOf: fileURL)
        return AgentImageAttachment(
            id: attachment.id,
            mimeType: attachment.mimeType,
            data: data
        )
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/heic":
            return "heic"
        default:
            return "bin"
        }
    }

    private func sanitizedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let result = String(scalars)
        return result.isEmpty ? UUID().uuidString : result
    }
}

struct PersistedImageAttachment: Codable, Hashable {
    let id: String
    let mimeType: String
    let storageKey: String
}

struct PersistedAgentMessage: Codable, Hashable {
    let id: String
    let threadID: String
    let role: AgentRole
    let text: String
    let images: [PersistedImageAttachment]
    let structuredOutput: AgentStructuredOutputMetadata?
    let createdAt: Date

    init(
        message: AgentMessage,
        attachmentStore: RuntimeAttachmentStore
    ) throws {
        self.id = message.id
        self.threadID = message.threadID
        self.role = message.role
        self.text = message.text
        self.images = try message.images.enumerated().map { index, attachment in
            try attachmentStore.persist(
                attachment,
                threadID: message.threadID,
                recordID: message.id,
                index: index
            )
        }
        self.structuredOutput = message.structuredOutput
        self.createdAt = message.createdAt
    }

    func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentMessage {
        AgentMessage(
            id: id,
            threadID: threadID,
            role: role,
            text: text,
            images: try images.map { try attachmentStore.load($0) },
            structuredOutput: structuredOutput,
            createdAt: createdAt
        )
    }
}

enum PersistedAgentHistoryItem: Hashable {
    case message(PersistedAgentMessage)
    case toolCall(AgentToolCallRecord)
    case toolResult(AgentToolResultRecord)
    case structuredOutput(AgentStructuredOutputRecord)
    case approval(AgentApprovalRecord)
    case systemEvent(AgentSystemEventRecord)

    init(
        item: AgentHistoryItem,
        attachmentStore: RuntimeAttachmentStore
    ) throws {
        switch item {
        case let .message(message):
            self = .message(try PersistedAgentMessage(
                message: message,
                attachmentStore: attachmentStore
            ))
        case let .toolCall(record):
            self = .toolCall(record)
        case let .toolResult(record):
            self = .toolResult(record)
        case let .structuredOutput(record):
            self = .structuredOutput(record)
        case let .approval(record):
            self = .approval(record)
        case let .systemEvent(record):
            self = .systemEvent(record)
        }
    }

    func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentHistoryItem {
        switch self {
        case let .message(message):
            return .message(try message.decode(using: attachmentStore))
        case let .toolCall(record):
            return .toolCall(record)
        case let .toolResult(record):
            return .toolResult(record)
        case let .structuredOutput(record):
            return .structuredOutput(record)
        case let .approval(record):
            return .approval(record)
        case let .systemEvent(record):
            return .systemEvent(record)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .message:
            self = .message(try container.decode(PersistedAgentMessage.self, forKey: .message))
        case .toolCall:
            self = .toolCall(try container.decode(AgentToolCallRecord.self, forKey: .toolCall))
        case .toolResult:
            self = .toolResult(try container.decode(AgentToolResultRecord.self, forKey: .toolResult))
        case .structuredOutput:
            self = .structuredOutput(try container.decode(AgentStructuredOutputRecord.self, forKey: .structuredOutput))
        case .approval:
            self = .approval(try container.decode(AgentApprovalRecord.self, forKey: .approval))
        case .systemEvent:
            self = .systemEvent(try container.decode(AgentSystemEventRecord.self, forKey: .systemEvent))
        }
    }

    func encode(to encoder: Encoder) throws {
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

struct PersistedAgentHistoryRecord: Codable, Hashable {
    let id: String
    let sequenceNumber: Int
    let createdAt: Date
    let item: PersistedAgentHistoryItem
    let redaction: AgentHistoryRedaction?

    init(
        record: AgentHistoryRecord,
        attachmentStore: RuntimeAttachmentStore
    ) throws {
        self.id = record.id
        self.sequenceNumber = record.sequenceNumber
        self.createdAt = record.createdAt
        self.item = try PersistedAgentHistoryItem(
            item: record.item,
            attachmentStore: attachmentStore
        )
        self.redaction = record.redaction
    }

    func decode(using attachmentStore: RuntimeAttachmentStore) throws -> AgentHistoryRecord {
        AgentHistoryRecord(
            id: id,
            sequenceNumber: sequenceNumber,
            createdAt: createdAt,
            item: try item.decode(using: attachmentStore),
            redaction: redaction
        )
    }
}
