import Foundation

extension AgentThreadPendingState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case approval
        case userInput
        case toolWait
    }

    private enum Kind: String, Codable {
        case approval
        case userInput
        case toolWait
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .approval:
            self = .approval(try container.decode(AgentPendingApprovalState.self, forKey: .approval))
        case .userInput:
            self = .userInput(try container.decode(AgentPendingUserInputState.self, forKey: .userInput))
        case .toolWait:
            self = .toolWait(try container.decode(AgentPendingToolWaitState.self, forKey: .toolWait))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .approval(state):
            try container.encode(Kind.approval, forKey: .kind)
            try container.encode(state, forKey: .approval)
        case let .userInput(state):
            try container.encode(Kind.userInput, forKey: .kind)
            try container.encode(state, forKey: .userInput)
        case let .toolWait(state):
            try container.encode(Kind.toolWait, forKey: .kind)
            try container.encode(state, forKey: .toolWait)
        }
    }
}

extension AgentHistoryItem: Codable {
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .message:
            self = .message(try container.decode(AgentMessage.self, forKey: .message))
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

    public func encode(to encoder: Encoder) throws {
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

extension AgentHistoryFilter {
    func matches(_ item: AgentHistoryItem) -> Bool {
        switch item {
        case .message:
            return includeMessages
        case .toolCall:
            return includeToolCalls
        case .toolResult:
            return includeToolResults
        case .structuredOutput:
            return includeStructuredOutputs
        case .approval:
            return includeApprovals
        case let .systemEvent(record):
            if record.type == .contextCompacted {
                return includeSystemEvents && includeCompactionEvents
            }
            return includeSystemEvents
        }
    }
}

extension AgentHistoryItem {
    var kind: AgentHistoryItemKind {
        switch self {
        case .message:
            .message
        case .toolCall:
            .toolCall
        case .toolResult:
            .toolResult
        case .structuredOutput:
            .structuredOutput
        case .approval:
            .approval
        case .systemEvent:
            .systemEvent
        }
    }

    var turnID: String? {
        switch self {
        case let .message(message):
            return message.structuredOutput == nil ? nil : nil
        case let .toolCall(record):
            return record.invocation.turnID
        case let .toolResult(record):
            return record.turnID
        case let .structuredOutput(record):
            return record.turnID
        case let .approval(record):
            return record.request?.turnID ?? record.resolution?.turnID
        case let .systemEvent(record):
            return record.turnID
        }
    }

    var defaultRecordID: String {
        switch self {
        case let .message(message):
            return "message:\(message.id)"
        case let .toolCall(record):
            return "toolCall:\(record.invocation.id)"
        case let .toolResult(record):
            return "toolResult:\(record.result.invocationID)"
        case let .structuredOutput(record):
            return "structuredOutput:\(record.messageID ?? record.turnID)"
        case let .approval(record):
            return "approval:\(record.request?.id ?? record.resolution?.requestID ?? UUID().uuidString)"
        case let .systemEvent(record):
            if record.type == .contextCompacted,
               let generation = record.compaction?.generation {
                return "systemEvent:\(record.type.rawValue):\(record.threadID):\(generation)"
            }
            return "systemEvent:\(record.type.rawValue):\(record.turnID ?? record.threadID)"
        }
    }

    public var isCompactionMarker: Bool {
        guard case let .systemEvent(record) = self else {
            return false
        }
        return record.type == .contextCompacted
    }
}

extension AgentHistoryRecord {
    func redacted(reason: AgentRedactionReason?) -> AgentHistoryRecord {
        AgentHistoryRecord(
            id: id,
            sequenceNumber: sequenceNumber,
            createdAt: createdAt,
            item: item.redactedPayload(),
            redaction: AgentHistoryRedaction(reason: reason)
        )
    }
}

private extension AgentHistoryItem {
    func redactedPayload() -> AgentHistoryItem {
        switch self {
        case let .message(message):
            return .message(
                AgentMessage(
                    id: message.id,
                    threadID: message.threadID,
                    role: message.role,
                    text: "[Redacted]",
                    images: [],
                    structuredOutput: message.structuredOutput.map {
                        AgentStructuredOutputMetadata(
                            formatName: $0.formatName,
                            payload: .object(["redacted": .bool(true)])
                        )
                    },
                    createdAt: message.createdAt
                )
            )

        case let .toolCall(record):
            return .toolCall(
                AgentToolCallRecord(
                    invocation: ToolInvocation(
                        id: record.invocation.id,
                        threadID: record.invocation.threadID,
                        turnID: record.invocation.turnID,
                        toolName: record.invocation.toolName,
                        arguments: .object(["redacted": .bool(true)])
                    ),
                    requestedAt: record.requestedAt
                )
            )

        case let .toolResult(record):
            return .toolResult(
                AgentToolResultRecord(
                    threadID: record.threadID,
                    turnID: record.turnID,
                    result: ToolResultEnvelope(
                        invocationID: record.result.invocationID,
                        toolName: record.result.toolName,
                        success: record.result.success,
                        content: [.text("[Redacted]")],
                        errorMessage: record.result.errorMessage == nil ? nil : "[Redacted]",
                        session: record.result.session
                    ),
                    completedAt: record.completedAt
                )
            )

        case let .structuredOutput(record):
            return .structuredOutput(
                AgentStructuredOutputRecord(
                    threadID: record.threadID,
                    turnID: record.turnID,
                    messageID: record.messageID,
                    metadata: AgentStructuredOutputMetadata(
                        formatName: record.metadata.formatName,
                        payload: .object(["redacted": .bool(true)])
                    ),
                    committedAt: record.committedAt
                )
            )

        case let .approval(record):
            let request = record.request.map {
                ApprovalRequest(
                    id: $0.id,
                    threadID: $0.threadID,
                    turnID: $0.turnID,
                    toolInvocation: ToolInvocation(
                        id: $0.toolInvocation.id,
                        threadID: $0.toolInvocation.threadID,
                        turnID: $0.toolInvocation.turnID,
                        toolName: $0.toolInvocation.toolName,
                        arguments: .object(["redacted": .bool(true)])
                    ),
                    title: "[Redacted]",
                    message: "[Redacted]"
                )
            }
            return .approval(
                AgentApprovalRecord(
                    kind: record.kind,
                    request: request,
                    resolution: record.resolution,
                    occurredAt: record.occurredAt
                )
            )

        case let .systemEvent(record):
            return .systemEvent(
                AgentSystemEventRecord(
                    type: record.type,
                    threadID: record.threadID,
                    turnID: record.turnID,
                    status: record.status,
                    turnSummary: record.turnSummary,
                    error: record.error.map {
                        AgentRuntimeError(code: $0.code, message: "[Redacted]")
                    },
                    occurredAt: record.occurredAt
                )
            )
        }
    }
}
