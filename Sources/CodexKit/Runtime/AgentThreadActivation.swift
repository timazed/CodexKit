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

package enum AgentThreadContextWindow {
    package struct HistoryProjection: Sendable {
        package let storageKey: String
        package let sequenceNumber: Int
        package let relationshipKey: String?

        package init(
            storageKey: String,
            sequenceNumber: Int,
            relationshipKey: String?
        ) {
            self.storageKey = storageKey
            self.sequenceNumber = sequenceNumber
            self.relationshipKey = relationshipKey
        }
    }

    /// Selects complete history relationships from an already database-bounded
    /// candidate set. This is packing only; filtering and companion lookup stay
    /// in the persistence adapter and use indexed database queries.
    package static func completeHistoryStorageKeys(
        from projections: [HistoryProjection],
        limit: Int
    ) throws -> Set<String> {
        guard limit > 0 else { return [] }
        var groups: [String: [HistoryProjection]] = [:]
        for projection in projections {
            let groupKey = projection.relationshipKey
                ?? "standalone:\(projection.storageKey)"
            groups[groupKey, default: []].append(projection)
        }
        guard groups.values.allSatisfy({ $0.count <= 2 }) else {
            throw AgentStoreError.invalidInput(
                "a stored history relationship contains more than two records"
            )
        }

        let newestFirst = groups.values.sorted { lhs, rhs in
            let left = lhs.map(\.sequenceNumber).max() ?? 0
            let right = rhs.map(\.sequenceNumber).max() ?? 0
            if left == right {
                return (lhs.first?.storageKey ?? "") > (rhs.first?.storageKey ?? "")
            }
            return left > right
        }
        var selected = Set<String>()
        for group in newestFirst where selected.count + group.count <= limit {
            selected.formUnion(group.map(\.storageKey))
            if selected.count == limit { break }
        }
        return selected
    }

    package static func reconstructedMessages(from records: [AgentHistoryRecord]) -> [AgentMessage] {
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
        let structuredOutputsByMessageID = Dictionary(
            relevantRecords.compactMap { record -> (String, AgentStructuredOutputMetadata)? in
                guard case let .structuredOutput(output) = record.item,
                      let messageID = output.messageID else { return nil }
                return (messageID, output.metadata)
            },
            uniquingKeysWith: { _, latest in latest }
        )

        return relevantRecords.compactMap { record -> AgentMessage? in
            switch record.item {
            case let .message(message):
                guard message.structuredOutput == nil,
                      let metadata = structuredOutputsByMessageID[message.id] else {
                    return message
                }
                var hydrated = message
                hydrated.structuredOutput = metadata
                return hydrated

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
                // Linked output is meaningful only with its owning message.
                // It is attached to that message above, never synthesized as a
                // misleading standalone system message.
                if output.messageID != nil { return nil }
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

    package static func boundedMessages(
        _ messages: [AgentMessage],
        policy: AgentThreadActivationPolicy,
        requireClosedTurns: Bool
    ) -> [AgentMessage] {
        let maximumMessageCount = min(
            max(0, policy.maximumMessageCount),
            AgentStoreLimits.maximumActivationMessageCount
        )
        let maximumEstimatedTokens = min(
            max(0, policy.maximumEstimatedTokens),
            AgentStoreLimits.maximumActivationEstimatedTokenCount
        )
        guard maximumMessageCount > 0, maximumEstimatedTokens > 0 else {
            return []
        }

        let boundedSource = messages.suffix(
            AgentStoreLimits.maximumActivationHistoryRecordCount
        )
        let units = conversationUnits(from: Array(boundedSource))
        var selectedUnits: [[AgentMessage]] = []
        var selectedMessageCount = 0
        var selectedTokenCount = 0

        for unit in units.reversed() {
            if requireClosedTurns, !isClosed(unit) {
                continue
            }

            let unitMessageCount = unit.reduce(0) {
                AgentCounter.saturatingAdd($0, $1.modelContextItemCount)
            }
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
            selectedMessageCount = AgentCounter.saturatingAdd(
                selectedMessageCount,
                unitMessageCount
            )
            selectedTokenCount = AgentCounter.saturatingAdd(
                selectedTokenCount,
                unitTokenCount
            )
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
        let characters = messages.reduce(0) {
            AgentCounter.saturatingAdd($0, $1.estimatedContextCharacterCount)
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
