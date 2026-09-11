import Foundation

public struct AgentRuntimeError: Error, LocalizedError, Equatable, Hashable, Sendable, Codable {
    public let code: String
    public let message: String
    public let http: AgentHTTPFailure?
    public let retry: AgentRetryInformation?
    public let interruption: AgentResponseInterruption?

    public init(code: String, message: String, http: AgentHTTPFailure? = nil, retry: AgentRetryInformation? = nil) {
        self.init(code: code, message: message, http: http, retry: retry, interruption: nil)
    }

    public init(code: String, message: String, http: AgentHTTPFailure? = nil, retry: AgentRetryInformation? = nil,
                interruption: AgentResponseInterruption?) {
        self.code = code
        self.message = message
        self.http = http
        self.retry = retry
        self.interruption = interruption
    }

    public init(code: AgentRuntimeErrorCode, message: String, http: AgentHTTPFailure? = nil,
                retry: AgentRetryInformation? = nil, interruption: AgentResponseInterruption? = nil) {
        self.init(code: code.rawValue, message: message, http: http, retry: retry, interruption: interruption)
    }

    public var knownCode: AgentRuntimeErrorCode? { AgentRuntimeErrorCode(rawValue: code) }

    public var errorDescription: String? {
        message
    }

    public static func signedOut() -> AgentRuntimeError {
        AgentRuntimeError(code: .signedOut, message: "No ChatGPT session is available.")
    }

    public static func threadNotFound(_ threadID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .threadNotFound,
            message: "The assistant thread \(threadID) could not be found."
        )
    }

    public static func unauthorized(_ message: String = "The ChatGPT session is no longer authorized.") -> AgentRuntimeError {
        AgentRuntimeError(code: .unauthorized, message: message)
    }

    public static func memoryNotConfigured() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .memoryNotConfigured,
            message: "This runtime was created without a memory store configuration."
        )
    }

    public static func invalidMessageContent() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidMessageContent,
            message: "A request must include text, context, or at least one image attachment."
        )
    }

    public static func invalidClientRequestID() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidClientRequestId,
            message: "A client request ID must be non-empty and at most 1,024 UTF-8 bytes."
        )
    }

    public static func unsupportedImageMimeType(_ mimeType: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .unsupportedImageMimeType,
            message: "Image attachments must use PNG, JPEG, or WebP. Received \(mimeType)."
        )
    }

    public static func assistantResponseMissing() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .assistantResponseMissing,
            message: "The assistant turn completed without returning a final assistant message."
        )
    }

    public static func turnSummaryMissing() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .turnSummaryMissing,
            message: "The assistant turn ended without a completion summary."
        )
    }

    public static func invalidTurnCompletion() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidTurnCompletion,
            message: "The backend completion does not match the active assistant thread and turn."
        )
    }

    public static func invalidTurnStart() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidTurnStart,
            message: "The backend turn has an invalid identifier or does not belong to the active assistant thread."
        )
    }

    public static func invalidBackendTurnEvent() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidBackendTurnEvent,
            message: "A backend event does not match the active assistant thread and turn."
        )
    }

    public static func invalidHistoryCursor() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidHistoryCursor,
            message: "The requested history cursor is invalid for this thread."
        )
    }

    public static func structuredOutputDecodingFailed(
        typeName: String,
        underlyingMessage: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .structuredOutputDecodingFailed,
            message: "The assistant response could not be decoded as \(typeName): \(underlyingMessage)"
        )
    }

    public static func structuredOutputMissing(
        formatName: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .structuredOutputMissing,
            message: "The assistant turn completed without returning structured output for \(formatName)."
        )
    }

    public static func structuredOutputInvalid(
        stage: AgentStructuredOutputValidationStage,
        underlyingMessage: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .structuredOutputInvalid,
            message: "The assistant returned invalid \(stage.rawValue) structured output: \(underlyingMessage)"
        )
    }

    public static func invalidSkillID(_ skillID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidSkillId,
            message: "The skill ID \(skillID) is invalid. Skill IDs must match ^[a-zA-Z0-9_-]+$."
        )
    }

    public static func duplicateSkill(_ skillID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .duplicateSkill,
            message: "A skill with ID \(skillID) is already registered."
        )
    }

    public static func skillsNotFound(_ skillIDs: [String]) -> AgentRuntimeError {
        let joined = skillIDs.sorted().joined(separator: ", ")
        return AgentRuntimeError(
            code: .skillsNotFound,
            message: "The following skills are not registered: \(joined)."
        )
    }

    public static func invalidSkillToolName(
        skillID: String,
        toolName: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidSkillToolName,
            message: "Skill \(skillID) references invalid tool name \(toolName). Tool names must match ^[a-zA-Z0-9_-]+$."
        )
    }

    public static func invalidSkillMaxToolCalls(skillID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .invalidSkillMaxToolCalls,
            message: "Skill \(skillID) has invalid maxToolCalls. It must be 0 or greater."
        )
    }

    public static func skillToolNotAllowed(_ toolName: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .skillToolNotAllowed,
            message: "Tool \(toolName) is not allowed by the active skill policy."
        )
    }

    public static func skillToolSequenceViolation(
        expected: String,
        actual: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .skillToolSequenceViolation,
            message: "Tool \(actual) was requested out of sequence. Expected \(expected)."
        )
    }

    public static func skillToolCallLimitExceeded(_ maxCalls: Int) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .skillToolCallLimitExceeded,
            message: "The active skill policy allows at most \(maxCalls) tool call(s) per turn."
        )
    }

    public static func skillRequiredToolsMissing(_ toolNames: [String]) -> AgentRuntimeError {
        AgentRuntimeError(
            code: .skillRequiredToolsMissing,
            message: "The active skill policy requires tool calls that did not occur: \(toolNames.sorted().joined(separator: ", "))."
        )
    }

    public static func contextCompactionDisabled() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .contextCompactionDisabled,
            message: "Context compaction is not enabled for this runtime."
        )
    }

    public static func contextCompactionUnsupported() -> AgentRuntimeError {
        AgentRuntimeError(
            code: .contextCompactionUnsupported,
            message: "Context compaction could not be performed with the active backend and strategy."
        )
    }
}
