import Foundation

/// A Codex model identifier.
///
/// Known models are available as static members, while `init(rawValue:)` keeps
/// the type open to server-enabled and future model identifiers.
public struct CodexModel: RawRepresentable, Codable, Hashable, Sendable, Identifiable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
    public var description: String { rawValue }

    public var info: CodexModelInfo? {
        Self.infoByModel[self]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An input modality advertised by a known Codex model.
public enum CodexModelInputModality: String, Codable, Hashable, Sendable {
    case text
    case image
}

/// The catalog-level availability classification for a known Codex model.
///
/// Actual access remains account- and server-dependent.
public enum CodexModelAvailability: String, Codable, Hashable, Sendable {
    case standard
    case researchPreview
    case internalUse
}

/// Static metadata for a model known to this CodexKit release.
public struct CodexModelInfo: Codable, Hashable, Sendable, Identifiable {
    public let model: CodexModel
    public let displayName: String
    public let summary: String
    public let defaultReasoningEffort: ReasoningEffort
    public let supportedReasoningEfforts: [ReasoningEffort]
    public let contextWindowTokenCount: Int
    public let inputModalities: [CodexModelInputModality]
    public let availability: CodexModelAvailability
    public let supportsImageDetailOriginal: Bool

    enum CodingKeys: String, CodingKey {
        case model, displayName, summary, defaultReasoningEffort, supportedReasoningEfforts
        case contextWindowTokenCount, inputModalities, availability
        case supportsImageDetailOriginal
    }

    public var id: CodexModel { model }

    public init(
        model: CodexModel,
        displayName: String,
        summary: String,
        defaultReasoningEffort: ReasoningEffort,
        supportedReasoningEfforts: [ReasoningEffort],
        contextWindowTokenCount: Int,
        inputModalities: [CodexModelInputModality],
        availability: CodexModelAvailability = .standard,
        supportsImageDetailOriginal: Bool
    ) {
        self.model = model
        self.displayName = displayName
        self.summary = summary
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.contextWindowTokenCount = contextWindowTokenCount
        self.inputModalities = inputModalities
        self.availability = availability
        self.supportsImageDetailOriginal = supportsImageDetailOriginal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(model: try c.decode(CodexModel.self, forKey: .model),
            displayName: try c.decode(String.self, forKey: .displayName),
            summary: try c.decode(String.self, forKey: .summary),
            defaultReasoningEffort: try c.decode(ReasoningEffort.self, forKey: .defaultReasoningEffort),
            supportedReasoningEfforts: try c.decode([ReasoningEffort].self, forKey: .supportedReasoningEfforts),
            contextWindowTokenCount: try c.decode(Int.self, forKey: .contextWindowTokenCount),
            inputModalities: try c.decode([CodexModelInputModality].self, forKey: .inputModalities),
            availability: try c.decode(CodexModelAvailability.self, forKey: .availability),
            supportsImageDetailOriginal: try c.decodeIfPresent(Bool.self, forKey: .supportsImageDetailOriginal) ?? false)
    }

    public func supports(_ effort: ReasoningEffort) -> Bool {
        supportedReasoningEfforts.contains(effort)
    }

    public init(model: CodexModel, displayName: String, summary: String,
        defaultReasoningEffort: ReasoningEffort, supportedReasoningEfforts: [ReasoningEffort],
        contextWindowTokenCount: Int, inputModalities: [CodexModelInputModality],
        availability: CodexModelAvailability = .standard) {
        self.init(model: model, displayName: displayName, summary: summary,
            defaultReasoningEffort: defaultReasoningEffort, supportedReasoningEfforts: supportedReasoningEfforts,
            contextWindowTokenCount: contextWindowTokenCount, inputModalities: inputModalities,
            availability: availability, supportsImageDetailOriginal: false)
    }

}

public extension CodexModel {
    static let gpt6Astra = CodexModel(rawValue: "gpt-6-astra")
    static let gpt56Sol = CodexModel(rawValue: "gpt-5.6-sol")
    static let gpt56Terra = CodexModel(rawValue: "gpt-5.6-terra")
    static let gpt56Luna = CodexModel(rawValue: "gpt-5.6-luna")
    static let gpt55 = CodexModel(rawValue: "gpt-5.5")
    static let gpt54 = CodexModel(rawValue: "gpt-5.4")
    static let gpt54Mini = CodexModel(rawValue: "gpt-5.4-mini")
    static let gpt53CodexSpark = CodexModel(rawValue: "gpt-5.3-codex-spark")
    static let gpt52 = CodexModel(rawValue: "gpt-5.2")
    static let codexAutoReview = CodexModel(rawValue: "codex-auto-review")

    /// Models described by this CodexKit release, including internal entries.
    static let catalog: [CodexModelInfo] = [
        CodexModelInfo(
            model: .gpt6Astra,
            displayName: "GPT-6-Astra",
            summary: "Our most capable model for complex, demanding work.",
            defaultReasoningEffort: .low,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh, .max, .ultra],
            contextWindowTokenCount: 272_000,
            inputModalities: [.text, .image],
            supportsImageDetailOriginal: true
        ),
        CodexModelInfo(
            model: .gpt56Sol,
            displayName: "GPT-5.6-Sol",
            summary: "Latest frontier agentic coding model.",
            defaultReasoningEffort: .low,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh, .max, .ultra],
            contextWindowTokenCount: 372_000,
            inputModalities: [.text, .image],
            supportsImageDetailOriginal: true
        ),
        CodexModelInfo(
            model: .gpt56Terra,
            displayName: "GPT-5.6-Terra",
            summary: "Balanced agentic coding model for everyday work.",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh, .max, .ultra],
            contextWindowTokenCount: 372_000,
            inputModalities: [.text, .image],
            supportsImageDetailOriginal: true
        ),
        CodexModelInfo(
            model: .gpt56Luna,
            displayName: "GPT-5.6-Luna",
            summary: "Fast and affordable agentic coding model.",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh, .max],
            contextWindowTokenCount: 372_000,
            inputModalities: [.text, .image],
            supportsImageDetailOriginal: true
        ),
        CodexModelInfo(
            model: .gpt55,
            displayName: "GPT-5.5",
            summary: "Frontier model for complex coding, research, and real-world work.",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh],
            contextWindowTokenCount: 272_000,
            inputModalities: [.text, .image],
            supportsImageDetailOriginal: true
        ),
        CodexModelInfo(
            model: .gpt54,
            displayName: "GPT-5.4",
            summary: "Strong model for everyday coding.",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh],
            contextWindowTokenCount: 272_000,
            inputModalities: [.text, .image],
            supportsImageDetailOriginal: true
        ),
        CodexModelInfo(
            model: .gpt54Mini,
            displayName: "GPT-5.4-Mini",
            summary: "Small, fast, and cost-efficient model for simpler coding tasks.",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh],
            contextWindowTokenCount: 272_000,
            inputModalities: [.text, .image]
        ),
        CodexModelInfo(
            model: .gpt53CodexSpark,
            displayName: "GPT-5.3-Codex-Spark",
            summary: "Ultra-fast coding model.",
            defaultReasoningEffort: .high,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh],
            contextWindowTokenCount: 128_000,
            inputModalities: [.text],
            availability: .researchPreview
        ),
        CodexModelInfo(
            model: .gpt52,
            displayName: "GPT-5.2",
            summary: "Optimized for professional work and long-running agents.",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh],
            contextWindowTokenCount: 272_000,
            inputModalities: [.text, .image]
        ),
        CodexModelInfo(
            model: .codexAutoReview,
            displayName: "Codex Auto Review",
            summary: "Automatic approval review model for Codex.",
            defaultReasoningEffort: .medium,
            supportedReasoningEfforts: [.low, .medium, .high, .extraHigh],
            contextWindowTokenCount: 272_000,
            inputModalities: [.text, .image],
            availability: .internalUse,
            supportsImageDetailOriginal: true
        ),
    ]

    static var knownModels: [CodexModel] {
        catalog.map(\.model)
    }

    /// Catalog models intended for user selection.
    static var userFacingModels: [CodexModel] {
        [
            .gpt6Astra,
            .gpt56Sol,
            .gpt56Terra,
            .gpt56Luna,
            .gpt55,
            .gpt54,
            .gpt54Mini,
            .gpt53CodexSpark,
        ]
    }
}

private extension CodexModel {
    static let infoByModel = Dictionary(
        uniqueKeysWithValues: catalog.map { ($0.model, $0) }
    )
}
