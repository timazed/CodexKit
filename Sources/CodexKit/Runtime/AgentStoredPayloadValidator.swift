import Foundation

package enum AgentStoredPayloadValidator {
    package static func validateMessage(_ message: AgentMessage) throws {
        if let metadata = message.structuredOutput {
            try validateStructuredMetadata(metadata)
        }
        guard let interaction = message.toolInteraction else { return }
        try validateInvocation(interaction.invocation, expectedThreadID: message.threadID)
        try validateResult(interaction.result)
        guard interaction.result.invocationID == interaction.invocation.id,
              interaction.result.toolName == interaction.invocation.toolName else {
            throw invalid("tool interaction result does not match its invocation")
        }
    }

    package static func validateHistoryItem(
        _ item: AgentHistoryItem,
        expectedThreadID: String
    ) throws {
        switch item {
        case .message:
            return
        case let .toolCall(record):
            try validateInvocation(record.invocation, expectedThreadID: expectedThreadID)
        case let .toolResult(record):
            try validateIdentifier(record.turnID, name: "tool-result turnID")
            try validateResult(record.result)
        case let .structuredOutput(record):
            if record.turnID.isEmpty {
                guard record.messageID != nil else {
                    throw invalid(
                        "structured-output turnID may be empty only for a message-derived output"
                    )
                }
            } else {
                try validateIdentifier(record.turnID, name: "structured-output turnID")
            }
            if let messageID = record.messageID {
                try validateIdentifier(messageID, name: "structured-output messageID")
            }
            try validateStructuredMetadata(record.metadata)
        case let .approval(record):
            try validateApproval(record, expectedThreadID: expectedThreadID)
        case let .systemEvent(record):
            if let turnID = record.turnID {
                try validateIdentifier(turnID, name: "system-event turnID")
            }
            if let summary = record.turnSummary {
                try validateIdentifier(summary.threadID, name: "turn-summary threadID")
                try validateIdentifier(summary.turnID, name: "turn-summary turnID")
            }
            if let error = record.error {
                try validateIdentifier(error.code, name: "runtime error code")
                try validateText(error.message, name: "runtime error message")
            }
            if let preview = record.compaction?.debugSummaryPreview {
                try validateText(preview, name: "compaction preview")
            }
            if let application = record.memoryApplication {
                guard record.type == .turnCompleted,
                      let summary = record.turnSummary,
                      summary.threadID == expectedThreadID,
                      summary.turnID == record.turnID,
                      application.threadID == expectedThreadID,
                      application.turnID == summary.turnID else {
                    throw invalid("memory application does not match its completed turn")
                }
                try validateMemoryApplication(application)
            }
            if let application = record.memoryCompactionApplication {
                guard record.type == .contextCompacted,
                      application.threadID == expectedThreadID,
                      application.generation == record.compaction?.generation,
                      application.reason == record.compaction?.reason else {
                    throw invalid("memory compaction application does not match its marker")
                }
                try validateMemoryCompactionApplication(application)
            }
        }
    }

    package static func validateMemoryApplication(
        _ application: MemoryApplicationSnapshot
    ) throws {
        try validateIdentifier(application.threadID, name: "memory application threadID")
        try validateIdentifier(application.turnID, name: "memory application turnID")
        try validateMemoryAttribution(
            clientRequestID: application.clientRequestID,
            model: application.model,
            reasoningEffort: application.reasoningEffort,
            activeSkillIDs: application.activeSkillIDs,
            rendererIdentifier: application.promptRendererIdentifier,
            instructionsHash: application.compiledInstructionsSHA256,
            query: application.query,
            result: application.result,
            renderedInstructions: application.renderedInstructions,
            includedRecordIDs: application.includedRecordIDs
        )
        try validateMemoryAttributionEncodedSize(application)
    }

    /// Validates the bounded store result before host rendering or observation.
    package static func validateMemoryQueryResult(
        query: MemoryQuery,
        result: MemoryQueryResult,
        validatesCurrentEligibility: Bool = false
    ) throws {
        try MemoryQueryEngine.validate(query)
        guard result.matches.count <= query.limit,
              result.matches.count <= MemoryStoreLimits.maximumQueryResultCount else {
            throw invalid("memory query result exceeds its declared result limit")
        }
        guard result.nextCursor == nil || result.truncated else {
            throw invalid("memory query result has a cursor without truncation")
        }
        if let cursor = result.nextCursor {
            var cursorQuery = query
            cursorQuery.cursor = cursor
            try MemoryQueryEngine.validate(cursorQuery)
        }
        let queryTokens = Set(MemoryQueryEngine.uniqueTokens(query.text))
        let requiredTextMatchCount = MemoryQueryEngine.requiredTextMatchCount(
            policy: query.textMatchPolicy,
            queryTokenCount: queryTokens.count
        )
        let now = Date()
        var renderedCharacterCount = 0
        for (index, match) in result.matches.enumerated() {
            try MemoryQueryEngine.validate(match.record)
            let actualMatchedTokenCount = MemoryQueryEngine.matchedTokenCount(
                for: match.record,
                queryTokens: queryTokens
            )
            guard memoryRecord(
                      match.record,
                      matches: query,
                      now: validatesCurrentEligibility ? now : nil
                  ),
                  match.explanation.rankingProfile == query.ranking,
                  match.explanation.matchedTokenCount == actualMatchedTokenCount,
                  match.explanation.queryTokenCount == queryTokens.count,
                  actualMatchedTokenCount >= requiredTextMatchCount,
                  match.explanation.recencyScore.isFinite,
                  (0 ... 1).contains(match.explanation.recencyScore),
                  match.explanation.importanceScore.isFinite,
                  match.explanation.importanceScore == match.record.importance else {
                throw invalid("memory query result contains invalid match metadata")
            }
            if let cursor = query.cursor,
               !MemoryQueryEngine.isAfterCursor(
                   match.record,
                   cursor: cursor,
                   profile: query.ranking
                ) {
                throw invalid("memory query result contains a record before its cursor")
            }
            let separatorCost = index == 0 ? 0 : 1
            let matchCharacterCount = MemoryQueryEngine.renderedCharacterCount(
                for: match.record
            )
            guard separatorCost <= query.maxCharacters - renderedCharacterCount,
                  matchCharacterCount <= query.maxCharacters
                    - renderedCharacterCount
                    - separatorCost else {
                throw invalid("memory query result exceeds its declared character budget")
            }
            renderedCharacterCount += matchCharacterCount + separatorCost
        }
        let selectedRecordIDs = Set(result.matches.map(\.record.id))
        guard selectedRecordIDs.count == result.matches.count else {
            throw invalid("memory query result contains duplicate record IDs")
        }
        for (previous, current) in zip(result.matches, result.matches.dropFirst()) {
            guard !MemoryQueryEngine.ordered(
                current.record,
                before: previous.record,
                profile: query.ranking
            ) else {
                throw invalid("memory query result is not in its declared ranking order")
            }
        }
        if let nextCursor = result.nextCursor {
            guard let lastRecord = result.matches.last?.record else {
                throw invalid("memory query result has a cursor without a final record")
            }
            guard nextCursor == MemoryQueryEngine.cursor(for: lastRecord, query: query) else {
                throw invalid("memory query result cursor does not match its final record")
            }
        }
        let encoded = try JSONEncoder().encode(result)
        guard encoded.count <= AgentStoreLimits.maximumEmbeddedPayloadByteCount else {
            throw invalid("memory query result exceeds its bounded encoded payload limit")
        }
    }

    private static func memoryRecord(
        _ record: MemoryRecord,
        matches query: MemoryQuery,
        now: Date?
    ) -> Bool {
        guard record.namespace == query.namespace,
              query.includeArchived || record.status != .archived,
              query.scopes.isEmpty || query.scopes.contains(record.scope),
              query.categories.isEmpty || query.categories.contains(record.category),
              query.tags.isEmpty || record.tags.contains(where: query.tags.contains),
              query.relatedIDs.isEmpty || record.relatedIDs.contains(where: query.relatedIDs.contains),
              query.minImportance.map({ record.importance >= $0 }) ?? true else {
            return false
        }
        guard let now else {
            return true
        }
        if !record.isPinned,
           let expiresAt = record.expiresAt,
           expiresAt <= now.addingTimeInterval(-1) {
            return false
        }
        if let recencyWindow = query.recencyWindow,
           now.timeIntervalSince(record.effectiveDate) > recencyWindow + 1 {
            return false
        }
        return true
    }

    private static func validateMemoryCompactionApplication(
        _ application: MemoryCompactionApplicationSnapshot
    ) throws {
        try validateIdentifier(
            application.threadID,
            name: "memory compaction application threadID"
        )
        guard application.generation > 0 else {
            throw invalid("memory compaction generation must be positive")
        }
        try validateMemoryAttribution(
            clientRequestID: application.clientRequestID,
            model: application.model,
            reasoningEffort: application.reasoningEffort,
            activeSkillIDs: application.activeSkillIDs,
            rendererIdentifier: application.promptRendererIdentifier,
            instructionsHash: application.compiledInstructionsSHA256,
            query: application.query,
            result: application.result,
            renderedInstructions: application.renderedInstructions,
            includedRecordIDs: application.includedRecordIDs
        )
        try validateMemoryAttributionEncodedSize(application)
    }

    private static func validateMemoryAttributionEncodedSize<Value: Encodable>(
        _ application: Value
    ) throws {
        let encoded = try JSONEncoder().encode(application)
        guard encoded.count <= AgentStoreLimits.maximumEmbeddedPayloadByteCount else {
            throw invalid("memory attribution exceeds its bounded encoded payload limit")
        }
    }

    private static func validateMemoryAttribution(
        clientRequestID: String?,
        model: String?,
        reasoningEffort: ReasoningEffort?,
        activeSkillIDs: [String],
        rendererIdentifier: String,
        instructionsHash: String,
        query: MemoryQuery,
        result: MemoryQueryResult,
        renderedInstructions: String,
        includedRecordIDs: [String]
    ) throws {
        if let clientRequestID {
            guard !clientRequestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("memory client request ID must not be blank")
            }
            try validateIdentifier(clientRequestID, name: "memory client request ID")
        }
        try validateOptionalIdentifier(model, name: "memory model")
        try validateOptionalIdentifier(
            reasoningEffort?.rawValue,
            name: "memory reasoning effort"
        )
        guard activeSkillIDs.count <= AgentStoreLimits.maximumQueryFilterValueCount else {
            throw invalid("memory attribution contains too many active skill IDs")
        }
        try activeSkillIDs.forEach {
            try validateIdentifier($0, name: "memory active skill ID")
        }
        try validateIdentifier(rendererIdentifier, name: "memory renderer identifier")
        guard instructionsHash.count == 64,
              instructionsHash.allSatisfy({ $0.isHexDigit }) else {
            throw invalid("memory instructions hash must be a SHA-256 hex digest")
        }
        try validateMemoryQueryResult(query: query, result: result)
        guard !renderedInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("rendered memory instructions must not be blank")
        }
        try validateText(renderedInstructions, name: "rendered memory instructions")
        let selectedRecordIDs = Set(result.matches.map(\.record.id))
        guard includedRecordIDs.count == Set(includedRecordIDs).count,
              includedRecordIDs.allSatisfy(selectedRecordIDs.contains) else {
            throw invalid("included memory record IDs must be unique selected results")
        }
        try includedRecordIDs.forEach {
            try validateIdentifier($0, name: "included memory record ID")
        }
    }

    package static func validateSummary(_ summary: AgentThreadSummary) throws {
        if let preview = summary.latestAssistantMessagePreview {
            try validateText(preview, name: "assistant preview")
        }
        if let metadata = summary.latestStructuredOutputMetadata {
            try validateStructuredMetadata(metadata)
        }
        if let snapshot = summary.latestPartialStructuredOutput {
            try validatePartialSnapshot(snapshot)
        }
        if let toolState = summary.latestToolState {
            try validateIdentifier(toolState.invocationID, name: "tool-state invocationID")
            try validateIdentifier(toolState.turnID, name: "tool-state turnID")
            try validateIdentifier(toolState.toolName, name: "tool-state toolName")
            try validateOptionalIdentifier(toolState.sessionID, name: "tool-state sessionID")
            try validateOptionalIdentifier(toolState.sessionStatus, name: "tool-state sessionStatus")
            if let metadata = toolState.metadata {
                try validateJSON(metadata, name: "tool-state metadata")
            }
            if let preview = toolState.resultPreview {
                try validateText(preview, name: "tool-state result preview")
            }
        }
        if let pendingState = summary.pendingState {
            try validatePendingState(
                pendingState,
                expectedThreadID: summary.threadID
            )
        }
    }

    package static func validateContext(_ state: AgentThreadContextState) throws {
        try validateOptionalIdentifier(state.latestMarkerID, name: "context marker ID")
        guard let context = state.providerContext else { return }
        try validateIdentifier(context.providerID, name: "provider ID")
        try validateJSON(context.payload, name: "provider context")
    }

    package static func validatePartialSnapshot(
        _ snapshot: AgentPartialStructuredOutputSnapshot
    ) throws {
        try validateIdentifier(snapshot.turnID, name: "partial-output turnID")
        try validateIdentifier(snapshot.formatName, name: "partial-output format")
        try validateJSON(snapshot.payload, name: "partial structured output")
    }

    package static func validateToolSession(_ session: AgentToolSessionRecord) throws {
        try validateOptionalIdentifier(session.sessionID, name: "tool-session sessionID")
        try validateOptionalIdentifier(session.sessionStatus, name: "tool-session status")
        if let metadata = session.metadata {
            try validateJSON(metadata, name: "tool-session metadata")
        }
    }

    package static func validatePendingState(
        _ state: AgentThreadPendingState,
        expectedThreadID: String
    ) throws {
        switch state {
        case let .approval(approval):
            try validateApprovalRequest(
                approval.request,
                expectedThreadID: expectedThreadID
            )
        case let .userInput(input):
            try validateIdentifier(input.requestID, name: "user-input requestID")
            try validateIdentifier(input.turnID, name: "user-input turnID")
            try validateText(input.title, name: "user-input title")
            try validateText(input.message, name: "user-input message")
        case let .toolWait(wait):
            try validateIdentifier(wait.invocationID, name: "tool-wait invocationID")
            try validateIdentifier(wait.turnID, name: "tool-wait turnID")
            try validateIdentifier(wait.toolName, name: "tool-wait toolName")
            try validateOptionalIdentifier(wait.sessionID, name: "tool-wait sessionID")
            try validateOptionalIdentifier(wait.sessionStatus, name: "tool-wait status")
            if let metadata = wait.metadata {
                try validateJSON(metadata, name: "tool-wait metadata")
            }
        }
    }

    private static func validateInvocation(
        _ invocation: ToolInvocation,
        expectedThreadID: String
    ) throws {
        guard invocation.threadID == expectedThreadID else {
            throw invalid("tool invocation belongs to a different thread")
        }
        try validateIdentifier(invocation.id, name: "tool invocation ID")
        try validateIdentifier(invocation.turnID, name: "tool invocation turnID")
        try validateIdentifier(invocation.toolName, name: "tool name")
        try validateJSON(invocation.arguments, name: "tool arguments")
    }

    private static func validateResult(_ result: ToolResultEnvelope) throws {
        try validateIdentifier(result.invocationID, name: "tool-result invocationID")
        try validateIdentifier(result.toolName, name: "tool-result toolName")
        guard result.content.count <= AgentStoreLimits.maximumToolResultContentCount else {
            throw invalid(
                "tool result must not exceed \(AgentStoreLimits.maximumToolResultContentCount) content items"
            )
        }
        var byteCount = 0
        for content in result.content {
            switch content {
            case let .text(text):
                try add(text.utf8.count, to: &byteCount, name: "tool result")
            case let .image(url):
                try add(url.absoluteString.utf8.count, to: &byteCount, name: "tool result")
            }
        }
        if let error = result.errorMessage {
            try add(error.utf8.count, to: &byteCount, name: "tool result")
        }
        if let session = result.session {
            try validateIdentifier(session.sessionID, name: "result sessionID")
            try validateIdentifier(session.status, name: "result session status")
            if let metadata = session.metadata {
                try validateJSON(metadata, name: "result session metadata")
            }
        }
    }

    private static func validateStructuredMetadata(
        _ metadata: AgentStructuredOutputMetadata
    ) throws {
        try validateIdentifier(metadata.formatName, name: "structured-output format")
        try validateJSON(metadata.payload, name: "structured-output payload")
    }

    private static func validateApproval(
        _ record: AgentApprovalRecord,
        expectedThreadID: String
    ) throws {
        if let request = record.request {
            try validateApprovalRequest(request, expectedThreadID: expectedThreadID)
        }
        if let resolution = record.resolution {
            guard resolution.threadID == expectedThreadID else {
                throw invalid("approval resolution belongs to a different thread")
            }
            try validateIdentifier(resolution.requestID, name: "approval requestID")
            try validateIdentifier(resolution.turnID, name: "approval turnID")
        }
    }

    private static func validateApprovalRequest(
        _ request: ApprovalRequest,
        expectedThreadID: String
    ) throws {
        guard request.threadID == expectedThreadID else {
            throw invalid("approval request belongs to a different thread")
        }
        try validateIdentifier(request.id, name: "approval requestID")
        try validateIdentifier(request.turnID, name: "approval turnID")
        try validateInvocation(request.toolInvocation, expectedThreadID: expectedThreadID)
        try validateText(request.title, name: "approval title")
        try validateText(request.message, name: "approval message")
    }

    private static func validateJSON(_ root: JSONValue, name: String) throws {
        var stack: [(JSONValue, Int)] = [(root, 1)]
        var nodeCount = 0
        var byteCount = 0
        while let (value, depth) = stack.popLast() {
            nodeCount += 1
            guard depth <= AgentStoreLimits.maximumEmbeddedPayloadDepth,
                  nodeCount <= AgentStoreLimits.maximumEmbeddedPayloadNodeCount else {
                throw invalid(
                    "\(name) exceeds the embedded payload depth or value limit"
                )
            }
            switch value {
            case let .string(string):
                try add(string.utf8.count, to: &byteCount, name: name)
            case let .number(number):
                guard number.isFinite else { throw invalid("\(name) contains a non-finite number") }
            case let .object(object):
                try reserveChildren(object.count, current: nodeCount, queued: stack.count, name: name)
                for (key, child) in object {
                    try add(key.utf8.count, to: &byteCount, name: name)
                    stack.append((child, depth + 1))
                }
            case let .array(array):
                try reserveChildren(array.count, current: nodeCount, queued: stack.count, name: name)
                for child in array { stack.append((child, depth + 1)) }
            case .bool, .null:
                break
            }
        }
    }

    private static func reserveChildren(
        _ count: Int,
        current: Int,
        queued: Int,
        name: String
    ) throws {
        let remaining = AgentStoreLimits.maximumEmbeddedPayloadNodeCount - current
        guard queued <= remaining, count <= remaining - queued else {
            throw invalid("\(name) exceeds the embedded payload value limit")
        }
    }

    private static func add(_ amount: Int, to total: inout Int, name: String) throws {
        let (updated, overflow) = total.addingReportingOverflow(amount)
        guard !overflow, updated <= AgentStoreLimits.maximumEmbeddedPayloadByteCount else {
            throw invalid(
                "\(name) must not exceed \(AgentStoreLimits.maximumEmbeddedPayloadByteCount) bytes"
            )
        }
        total = updated
    }

    private static func validateText(_ value: String, name: String) throws {
        guard value.utf8.count <= AgentStoreLimits.maximumMessageTextByteCount else {
            throw invalid(
                "\(name) must not exceed \(AgentStoreLimits.maximumMessageTextByteCount) UTF-8 bytes"
            )
        }
    }

    private static func validateOptionalIdentifier(_ value: String?, name: String) throws {
        if let value { try validateIdentifier(value, name: name) }
    }

    private static func validateIdentifier(_ value: String, name: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
            throw invalid(
                "\(name) must be nonempty and at most \(AgentStoreLimits.maximumIdentifierByteCount) UTF-8 bytes"
            )
        }
    }

    private static func invalid(_ message: String) -> AgentStoreError {
        .invalidInput(message)
    }
}
