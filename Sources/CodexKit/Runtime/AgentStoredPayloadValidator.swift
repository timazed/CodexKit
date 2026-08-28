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
            if let checkpoint = record.recoveryCheckpoint {
                try validateRecoveryCheckpoint(
                    checkpoint,
                    expectedThreadID: expectedThreadID
                )
            }
        }
    }

    private static func validateRecoveryCheckpoint(
        _ checkpoint: AgentTurnRecoveryCheckpoint,
        expectedThreadID: String
    ) throws {
        guard checkpoint.threadID == expectedThreadID else {
            throw invalid("turn recovery checkpoint belongs to a different thread")
        }
        try validateIdentifier(checkpoint.providerID, name: "recovery provider ID")
        try validateIdentifier(checkpoint.turnID, name: "recovery turnID")
        try validateText(checkpoint.request.text, name: "recovery request text")
        if let context = checkpoint.request.context {
            try validateOptionalIdentifier(context.schemaName, name: "recovery context schema")
            try validateJSON(context.payload, name: "recovery request context")
        }
        if let options = checkpoint.request.options {
            try validateOptionalIdentifier(options.schemaName, name: "recovery options schema")
            try validateText(options.mode, name: "recovery options mode")
            for requirement in options.requirements {
                try validateText(requirement, name: "recovery option requirement")
            }
        }
        try validateJSON(checkpoint.payload, name: "recovery provider payload")
        guard checkpoint.createdAt.timeIntervalSince1970.isFinite else {
            throw invalid("recovery checkpoint date must be finite")
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
