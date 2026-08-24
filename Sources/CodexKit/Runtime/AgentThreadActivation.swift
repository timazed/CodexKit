import Foundation

/// Bounds the model-facing working set hydrated when a durable thread becomes active.
public struct AgentThreadActivationPolicy: Codable, Hashable, Sendable {
    public var maximumMessageCount: Int
    public var maximumEstimatedTokens: Int
    public var maximumHistoryRecordCount: Int

    public init(
        maximumMessageCount: Int = 128,
        maximumEstimatedTokens: Int = 16_000,
        maximumHistoryRecordCount: Int = 512
    ) {
        self.maximumMessageCount = maximumMessageCount
        self.maximumEstimatedTokens = maximumEstimatedTokens
        self.maximumHistoryRecordCount = maximumHistoryRecordCount
    }
}

/// The bounded durable state needed to reactivate one thread.
public struct AgentThreadActivationState: Hashable, Sendable {
    public let thread: AgentThread
    public let summary: AgentThreadSummary
    public let contextState: AgentThreadContextState?
    public let nextHistorySequence: Int
    public let effectiveMessages: [AgentMessage]

    public init(
        thread: AgentThread,
        summary: AgentThreadSummary,
        contextState: AgentThreadContextState?,
        nextHistorySequence: Int,
        effectiveMessages: [AgentMessage]
    ) {
        self.thread = thread
        self.summary = summary
        self.contextState = contextState
        self.nextHistorySequence = nextHistorySequence
        self.effectiveMessages = effectiveMessages
    }
}

enum AgentThreadContextWindow {
    static func reconstructedMessages(from records: [AgentHistoryRecord]) -> [AgentMessage] {
        let relevantRecords: [AgentHistoryRecord]
        if let latestCompactionIndex = records.lastIndex(where: { record in
            guard case let .systemEvent(event) = record.item else { return false }
            return event.type == .contextCompacted && event.compaction != nil
        }) {
            relevantRecords = Array(records[latestCompactionIndex...])
        } else {
            relevantRecords = records
        }
        let toolResultsByInvocationID = Dictionary(
            relevantRecords.compactMap { record -> (String, AgentToolResultRecord)? in
                guard case let .toolResult(result) = record.item else { return nil }
                return (result.result.invocationID, result)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let messageIDs = Set(relevantRecords.compactMap { record -> String? in
            guard case let .message(message) = record.item else { return nil }
            return message.id
        })

        return relevantRecords.compactMap { record -> AgentMessage? in
            switch record.item {
            case let .message(message):
                return message

            case let .toolCall(call):
                guard let result = toolResultsByInvocationID[call.invocation.id] else {
                    return nil
                }
                let resultText = result.result.primaryText
                    ?? result.result.errorMessage
                    ?? (result.result.success ? "completed" : "failed")
                return AgentMessage(
                    id: "activation-tool:\(call.invocation.id)",
                    threadID: call.invocation.threadID,
                    role: .tool,
                    text: "Tool \(call.invocation.toolName) completed: \(resultText)",
                    toolInteraction: AgentToolInteraction(
                        invocation: call.invocation,
                        result: result.result
                    ),
                    createdAt: result.completedAt
                )

            case .toolResult:
                // Emitted atomically with its matching call above.
                return nil

            case let .structuredOutput(output):
                guard output.messageID.map({ !messageIDs.contains($0) }) ?? true else {
                    return nil
                }
                return AgentMessage(
                    id: "activation-structured:\(record.id)",
                    threadID: output.threadID,
                    role: .system,
                    text: "Structured output \(output.metadata.formatName): \(output.metadata.payload.prettyJSONString)",
                    structuredOutput: output.metadata,
                    createdAt: output.committedAt
                )

            case .approval:
                return nil

            case let .systemEvent(event):
                guard event.type == .contextCompacted,
                      let preview = event.compaction?.debugSummaryPreview,
                      !preview.isEmpty
                else {
                    return nil
                }
                return AgentMessage(
                    id: "activation-compaction:\(record.id)",
                    threadID: event.threadID,
                    role: .system,
                    text: "Compacted context: \(preview)",
                    createdAt: event.occurredAt
                )
            }
        }
    }

    static func boundedMessages(
        _ messages: [AgentMessage],
        policy: AgentThreadActivationPolicy,
        requireClosedTurns: Bool
    ) -> [AgentMessage] {
        let maximumMessageCount = max(0, policy.maximumMessageCount)
        let maximumEstimatedTokens = max(0, policy.maximumEstimatedTokens)
        guard maximumMessageCount > 0, maximumEstimatedTokens > 0 else {
            return []
        }

        let units = conversationUnits(from: messages)
        var selectedUnits: [[AgentMessage]] = []
        var selectedMessageCount = 0
        var selectedTokenCount = 0

        for unit in units.reversed() {
            if requireClosedTurns, !isClosed(unit) {
                continue
            }

            let unitMessageCount = unit.reduce(0) { $0 + $1.modelContextItemCount }
            let unitTokenCount = estimatedTokenCount(for: unit)
            guard unitMessageCount <= maximumMessageCount,
                  unitTokenCount <= maximumEstimatedTokens
            else {
                if selectedUnits.isEmpty {
                    // Compact an oversized relationship as one unit. This keeps
                    // activation bounded without exposing only one side of it.
                    selectedUnits.append([
                        compactedMessage(
                            from: unit,
                            maximumEstimatedTokens: maximumEstimatedTokens
                        ),
                    ])
                }
                break
            }
            guard selectedMessageCount + unitMessageCount <= maximumMessageCount,
                  selectedTokenCount + unitTokenCount <= maximumEstimatedTokens
            else {
                break
            }

            selectedUnits.append(unit)
            selectedMessageCount += unitMessageCount
            selectedTokenCount += unitTokenCount
        }

        return selectedUnits.reversed().flatMap { $0 }
    }

    private static func conversationUnits(from messages: [AgentMessage]) -> [[AgentMessage]] {
        var units: [[AgentMessage]] = []
        var current: [AgentMessage] = []

        for message in messages {
            if message.role == .user, !current.isEmpty {
                units.append(current)
                current = []
            }
            current.append(message)
        }
        if !current.isEmpty {
            units.append(current)
        }
        return units
    }

    private static func isClosed(_ unit: [AgentMessage]) -> Bool {
        guard let userIndex = unit.firstIndex(where: { $0.role == .user }) else {
            // Persisted system summaries are self-contained context units.
            return unit.allSatisfy { $0.role == .system }
        }
        return unit[unit.index(after: userIndex)...].contains { $0.role == .assistant }
    }

    private static func estimatedTokenCount(for messages: [AgentMessage]) -> Int {
        guard !messages.isEmpty else { return 0 }
        let characters = messages.reduce(into: 0) { total, message in
            total += message.estimatedContextCharacterCount
        }
        return max(1, characters / 4)
    }

    private static func compactedMessage(
        from unit: [AgentMessage],
        maximumEstimatedTokens: Int
    ) -> AgentMessage {
        let threadID = unit.first?.threadID ?? ""
        let lines = unit.map { message in
            let content = message.text.isEmpty
                ? "[\(message.images.count) image attachment(s)]"
                : message.text
            return "\(message.role.rawValue.capitalized): \(content)"
        }
        let prefix = "Compacted conversation turn:\n"
        let characterBudget: Int
        if maximumEstimatedTokens > Int.max / 4 {
            characterBudget = Int.max
        } else {
            characterBudget = max(1, maximumEstimatedTokens * 4)
        }
        let compactedText = prefix + lines.joined(separator: "\n")
        return AgentMessage(
            threadID: threadID,
            role: .system,
            text: String(compactedText.prefix(characterBudget)),
            createdAt: unit.last?.createdAt ?? Date()
        )
    }
}
