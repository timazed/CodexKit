import Foundation

public struct AgentRuntimeError: Error, LocalizedError, Equatable, Hashable, Sendable, Codable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message
    }

    public static func signedOut() -> AgentRuntimeError {
        AgentRuntimeError(code: "signed_out", message: "No ChatGPT session is available.")
    }

    public static func threadNotFound(_ threadID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "thread_not_found",
            message: "The assistant thread \(threadID) could not be found."
        )
    }

    public static func unauthorized(_ message: String = "The ChatGPT session is no longer authorized.") -> AgentRuntimeError {
        AgentRuntimeError(code: "unauthorized", message: message)
    }

    public static func memoryNotConfigured() -> AgentRuntimeError {
        AgentRuntimeError(
            code: "memory_not_configured",
            message: "This runtime was created without a memory store configuration."
        )
    }

    public static func invalidMessageContent() -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_message_content",
            message: "A request must include text, context, or at least one image attachment."
        )
    }

    public static func assistantResponseMissing() -> AgentRuntimeError {
        AgentRuntimeError(
            code: "assistant_response_missing",
            message: "The assistant turn completed without returning a final assistant message."
        )
    }

    public static func invalidHistoryCursor() -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_history_cursor",
            message: "The requested history cursor is invalid for this thread."
        )
    }

    public static func structuredOutputDecodingFailed(
        typeName: String,
        underlyingMessage: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "structured_output_decoding_failed",
            message: "The assistant response could not be decoded as \(typeName): \(underlyingMessage)"
        )
    }

    public static func structuredOutputMissing(
        formatName: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "structured_output_missing",
            message: "The assistant turn completed without returning structured output for \(formatName)."
        )
    }

    public static func structuredOutputInvalid(
        stage: AgentStructuredOutputValidationStage,
        underlyingMessage: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "structured_output_invalid",
            message: "The assistant returned invalid \(stage.rawValue) structured output: \(underlyingMessage)"
        )
    }

    public static func invalidSkillID(_ skillID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_skill_id",
            message: "The skill ID \(skillID) is invalid. Skill IDs must match ^[a-zA-Z0-9_-]+$."
        )
    }

    public static func duplicateSkill(_ skillID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "duplicate_skill",
            message: "A skill with ID \(skillID) is already registered."
        )
    }

    public static func skillsNotFound(_ skillIDs: [String]) -> AgentRuntimeError {
        let joined = skillIDs.sorted().joined(separator: ", ")
        return AgentRuntimeError(
            code: "skills_not_found",
            message: "The following skills are not registered: \(joined)."
        )
    }

    public static func invalidSkillToolName(
        skillID: String,
        toolName: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_skill_tool_name",
            message: "Skill \(skillID) references invalid tool name \(toolName). Tool names must match ^[a-zA-Z0-9_-]+$."
        )
    }

    public static func invalidSkillMaxToolCalls(skillID: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "invalid_skill_max_tool_calls",
            message: "Skill \(skillID) has invalid maxToolCalls. It must be 0 or greater."
        )
    }

    public static func skillToolNotAllowed(_ toolName: String) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "skill_tool_not_allowed",
            message: "Tool \(toolName) is not allowed by the active skill policy."
        )
    }

    public static func skillToolSequenceViolation(
        expected: String,
        actual: String
    ) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "skill_tool_sequence_violation",
            message: "Tool \(actual) was requested out of sequence. Expected \(expected)."
        )
    }

    public static func skillToolCallLimitExceeded(_ maxCalls: Int) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "skill_tool_call_limit_exceeded",
            message: "The active skill policy allows at most \(maxCalls) tool call(s) per turn."
        )
    }

    public static func skillRequiredToolsMissing(_ toolNames: [String]) -> AgentRuntimeError {
        AgentRuntimeError(
            code: "skill_required_tools_missing",
            message: "The active skill policy requires tool calls that did not occur: \(toolNames.sorted().joined(separator: ", "))."
        )
    }

    public static func contextCompactionDisabled() -> AgentRuntimeError {
        AgentRuntimeError(
            code: "context_compaction_disabled",
            message: "Context compaction is not enabled for this runtime."
        )
    }

    public static func contextCompactionUnsupported() -> AgentRuntimeError {
        AgentRuntimeError(
            code: "context_compaction_unsupported",
            message: "Context compaction could not be performed with the active backend and strategy."
        )
    }
}
