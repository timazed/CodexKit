import Foundation

public enum MemoryCaptureSource: Sendable {
    case threadHistory(maxMessages: Int = 8)
    case messages([AgentMessage])
    case text(String)
}

public struct MemoryCaptureOptions: Sendable {
    public var defaults: MemoryWriterDefaults
    public var maxMemories: Int
    public var instructions: String?

    public init(
        defaults: MemoryWriterDefaults = .init(),
        maxMemories: Int = 3,
        instructions: String? = nil
    ) {
        self.defaults = defaults
        self.maxMemories = maxMemories
        self.instructions = instructions
    }
}

public struct MemoryCaptureResult: Sendable {
    public var sourceText: String
    public var drafts: [MemoryDraft]
    public var records: [MemoryRecord]

    public init(
        sourceText: String,
        drafts: [MemoryDraft],
        records: [MemoryRecord]
    ) {
        self.sourceText = sourceText
        self.drafts = drafts
        self.records = records
    }
}

struct MemoryExtractionDraftResponse: Decodable, Sendable {
    let memories: [MemoryExtractionDraft]

    static func responseFormat(maxMemories: Int) -> AgentStructuredOutputFormat {
        AgentStructuredOutputFormat(
            name: "memory_extraction_batch",
            description: "Durable memory candidates extracted from app conversation history.",
            schema: .object(
                properties: [
                    "memories": .array(
                        items: .object(
                            properties: [
                                "summary": .string(),
                                "scope": .nullable(.string()),
                                "kind": .nullable(.string()),
                                "evidence": .array(items: .string()),
                                "importance": .number,
                                "tags": .array(items: .string()),
                                "relatedIDs": .array(items: .string()),
                                "dedupeKey": .nullable(.string()),
                            ],
                            required: ["summary", "evidence", "importance", "tags", "relatedIDs", "dedupeKey"],
                            additionalProperties: false
                        )
                    ),
                ],
                required: ["memories"],
                additionalProperties: false
            ),
            strict: true
        )
    }

    static func prompt(
        sourceText: String,
        maxMemories: Int
    ) -> String {
        """
        Extract up to \(maxMemories) durable memory records from the source conversation below.

        Save only information worth carrying into future turns:
        - stable user preferences
        - durable project constraints
        - recurring behavioral guidance
        - persistent goals or important facts

        Do not save:
        - greetings or filler
        - one-off requests
        - temporary status updates
        - details that are too vague to be useful later

        If nothing is worth saving, return an empty `memories` array.

        Source conversation:
        \(sourceText)
        """
    }

    static let instructions = """
    You extract durable app memory from conversations for future turns.
    Return compact memory candidates only. Prefer specific, reusable facts over temporary requests.
    """
}

struct MemoryExtractionDraft: Decodable, Sendable {
    let summary: String
    let scope: String?
    let kind: String?
    let evidence: [String]
    let importance: Double
    let tags: [String]
    let relatedIDs: [String]
    let dedupeKey: String?

    var memoryDraft: MemoryDraft {
        MemoryDraft(
            scope: scope.map(MemoryScope.init(rawValue:)),
            kind: kind,
            summary: summary,
            evidence: evidence,
            importance: importance,
            tags: tags,
            relatedIDs: relatedIDs,
            dedupeKey: dedupeKey
        )
    }
}
