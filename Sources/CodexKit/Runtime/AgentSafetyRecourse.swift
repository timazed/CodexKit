import Foundation

/// Validated provider guidance for a matching terminal policy failure.
/// Suggestions are display data. Submit only after an explicit user choice.
public struct AgentSafetyRecourse: Codable, Hashable, Sendable {
    public enum Domain: String, Codable, Sendable { case bio, cyber }
    public struct Suggestion: Codable, Hashable, Sendable {
        public let label: String
        public let promptText: String
    }
    public let domain: Domain
    public let topic: String
    public let suggestions: [Suggestion]

    public var explanation: String {
        let concern = Self.topics[domain]?[topic] ?? "activities covered by its safety policy"
        return "The provider blocked this request because it concerns \(concern)."
    }

    static func parse(_ metadata: JSONValue?) -> Self? {
        guard let value = metadata?.objectValue?["openai_chatgpt_moderation_metadata"]?.objectValue?["safety_recourse"]?.objectValue,
              Set(value.keys) == ["schema_version", "domain", "source", "source_message", "topic", "suggestions"],
              value["schema_version"] == .number(1),
              let domain = value["domain"]?.stringValue.flatMap(Domain.init(rawValue:)),
              let topic = value["topic"]?.stringValue, topics[domain]?[topic] != nil,
              let source = value["source"]?.stringValue,
              let message = value["source_message"]?.objectValue,
              Set(message.keys) == ["id", "kind", "role"],
              valid(message["id"]?.stringValue, max: 256),
              let kind = message["kind"]?.stringValue, let role = message["role"]?.stringValue,
              sources.contains("\(source)/\(kind)/\(role)"),
              case let .array(raw) = value["suggestions"], raw.count == 3 else { return nil }
        var suggestions: [Suggestion] = []
        var labels = Set<String>(), prompts = Set<String>()
        for entry in raw {
            guard let fields = entry.objectValue, Set(fields.keys) == ["label", "prompt_text"],
                  let label = fields["label"]?.stringValue, valid(label, max: 80),
                  let prompt = fields["prompt_text"]?.stringValue, valid(prompt, max: 2_000) else { return nil }
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard prompts.insert(cleanPrompt).inserted else { return nil }
            // Do not offer command-like suggestions as chat actions.
            guard cleanPrompt.utf8.count <= 1_000, !cleanPrompt.hasPrefix("/"), !cleanPrompt.hasPrefix("!"),
                  !cleanPrompt.contains("plugin://"), !cleanPrompt.contains("app://"),
                  !cleanPrompt.contains("$"), !cleanPrompt.contains("<"),
                  !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }),
                  cleanLabel.lowercased() != "enable daybreak",
                  labels.insert(cleanLabel.lowercased()).inserted else { continue }
            suggestions.append(.init(label: cleanLabel, promptText: cleanPrompt))
        }
        return .init(domain: domain, topic: topic, suggestions: suggestions)
    }

    private static func valid(_ value: String?, max: Int) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= max
    }

    private static let sources: Set<String> = [
        "user_request/ordinary_message/user", "assistant_response/ordinary_message/assistant",
        "file_content/file_tool_call/assistant", "file_content/file_tool_result/tool",
        "web_search_result/web_tool_call/assistant", "web_search_result/web_tool_result/tool",
        "other_tool/other_tool_call/assistant", "other_tool/other_tool_result/tool"
    ]
    private static let topics: [Domain: [String: String]] = [
        .bio: [
            "biological_agent_access_and_safeguards": "access to biological materials and related safety controls",
            "biological_agent_growth_or_production": "growing or producing biological agents",
            "risky_biological_experimentation_or_modification": "biological experimentation or modification that could pose safety risks",
            "harmful_biological_exposure_or_release": "biological exposure or release that could cause harm",
            "risky_biological_activities": "biological activities that could pose safety risks"
        ],
        .cyber: [
            "unauthorized_account_or_system_access": "access to accounts or systems beyond permitted scope",
            "high_risk_cybersecurity_tools": "system disruption or high-risk cyber tools",
            "sensitive_data_or_private_communications": "sensitive data collection or private communications monitoring",
            "software_vulnerabilities_or_security_weaknesses": "techniques for bypassing security controls",
            "risky_cybersecurity_activities": "cyber activities that pose security or safety risks"
        ]
    ]
}

/// One HTTP response only: never carries guidance into another request or tool round.
struct CodexSafetyRecourseState {
    private var pending: AgentSafetyRecourse?
    private var lastSequence: Int?

    mutating func consume(_ event: CodexResponsesStreamEvent) -> CodexResponsesStreamEvent {
        if let sequence = event.sequenceNumber {
            if let lastSequence, sequence <= lastSequence { return event }
            lastSequence = sequence
        }
        if let recourse = event.safetyRecourse { pending = recourse }
        switch event.kind {
        case .responseCreated: pending = nil
        case .completed: pending = nil
        case let .failed(error, responseID):
            defer { pending = nil }
            guard let pending, error.http?.providerCode == "\(pending.domain.rawValue)_policy" else { return event }
            var result = event
            result.kind = .failed(error.withSafetyRecourse(pending), responseID: responseID)
            return result
        default: break
        }
        return event
    }
}

extension AgentRuntimeError {
    func withSafetyRecourse(_ value: AgentSafetyRecourse?) -> Self {
        .init(code: code, message: message, http: http, retry: retry, interruption: interruption,
              imageGeneration: imageGeneration, safetyRecourse: value)
    }
}
