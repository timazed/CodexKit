import Foundation

/// Controls where rendered memory is inserted without changing the relative
/// order of the runtime's existing base, persona, and skill instructions.
public enum MemoryInstructionPlacement: String, Codable, Hashable, Sendable {
    /// Inserts memory after base instructions, when present, and before all
    /// persona and skill sections.
    case beforePersonas

    /// Inserts memory immediately before the first skill section. When no
    /// skills are active, memory follows the effective persona or base section.
    case beforeSkills

    /// Inserts memory after all existing instruction sections.
    case afterSkills
}

/// The prompt text produced by a memory renderer and the selected records that
/// contributed to it.
public struct RenderedMemoryPrompt: Codable, Hashable, Sendable {
    public var instructions: String
    public var includedRecordIDs: [String]

    public init(
        instructions: String,
        includedRecordIDs: [String]
    ) {
        self.instructions = instructions
        self.includedRecordIDs = includedRecordIDs
    }
}

/// Memory-specific details from resolving an instruction preview.
public struct ResolvedMemoryInstructionsPreview: Codable, Hashable, Sendable {
    public let query: MemoryQuery
    public let result: MemoryQueryResult
    public let renderedInstructions: String
    public let includedRecordIDs: [String]
    public let placement: MemoryInstructionPlacement

    public init(
        query: MemoryQuery,
        result: MemoryQueryResult,
        renderedInstructions: String,
        includedRecordIDs: [String],
        placement: MemoryInstructionPlacement
    ) {
        self.query = query
        self.result = result
        self.renderedInstructions = renderedInstructions
        self.includedRecordIDs = includedRecordIDs
        self.placement = placement
    }
}

/// The complete instruction preview plus the memory details used to build it.
public struct ResolvedAgentInstructionsPreview: Codable, Hashable, Sendable {
    public let instructions: String
    public let memory: ResolvedMemoryInstructionsPreview?

    public init(
        instructions: String,
        memory: ResolvedMemoryInstructionsPreview?
    ) {
        self.instructions = instructions
        self.memory = memory
    }
}

/// Why a successful runtime turn did not apply memory instructions.
public enum MemoryApplicationOmissionReason: String, Codable, Hashable, Sendable {
    /// The runtime was created without a memory configuration.
    case notConfigured

    /// Memory was explicitly disabled for this request.
    case disabled

    /// The request and thread did not provide an effective memory namespace.
    case noSelectionContext

    /// The memory query completed successfully but selected no records, and
    /// the renderer did not produce any instructions independently.
    case noMatches

    /// Records were selected, but the renderer produced no instructions.
    case rendererOmittedAll

    /// The configured memory store could not complete the query.
    case unavailable

    /// CodexKit rejected an invalid query, result, or rendered attribution.
    case rejected

    /// Attribution was not supplied, such as by a manually initialized result.
    case notReported
}

/// The memory attribution attached to a successfully completed runtime turn.
public enum MemoryApplicationOutcome: Codable, Hashable, Sendable {
    /// Memory instructions were included in the model input.
    case applied(MemoryApplicationSnapshot)

    /// No memory instructions were included in the model input.
    case notApplied(MemoryApplicationOmissionReason)

    /// The exact applied snapshot, or `nil` when memory was not applied.
    public var snapshot: MemoryApplicationSnapshot? {
        guard case let .applied(snapshot) = self else { return nil }
        return snapshot
    }

    /// The reason memory was not applied, or `nil` when it was applied.
    public var omissionReason: MemoryApplicationOmissionReason? {
        guard case let .notApplied(reason) = self else { return nil }
        return reason
    }
}

/// An exact snapshot of the rendered memory attached to a successfully
/// completed runtime turn. Failed, cancelled, and runtime-rejected turns do
/// not produce an application snapshot.
public struct MemoryApplicationSnapshot: Codable, Hashable, Sendable {
    public let threadID: String
    public let turnID: String
    public let clientRequestID: String?
    public let model: String?
    public let reasoningEffort: ReasoningEffort?
    public let activeSkillIDs: [String]
    public let promptRendererIdentifier: String
    public let compiledInstructionsSHA256: String
    public let query: MemoryQuery
    public let result: MemoryQueryResult
    public let renderedInstructions: String
    public let includedRecordIDs: [String]
    public let placement: MemoryInstructionPlacement

    public init(
        threadID: String,
        turnID: String,
        clientRequestID: String? = nil,
        model: String? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        activeSkillIDs: [String] = [],
        promptRendererIdentifier: String,
        compiledInstructionsSHA256: String,
        query: MemoryQuery,
        result: MemoryQueryResult,
        renderedInstructions: String,
        includedRecordIDs: [String],
        placement: MemoryInstructionPlacement
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.clientRequestID = clientRequestID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.activeSkillIDs = activeSkillIDs
        self.promptRendererIdentifier = promptRendererIdentifier
        self.compiledInstructionsSHA256 = compiledInstructionsSHA256
        self.query = query
        self.result = result
        self.renderedInstructions = renderedInstructions
        self.includedRecordIDs = includedRecordIDs
        self.placement = placement
    }
}

/// An exact snapshot of rendered memory used by a successful context
/// compaction. Threaded compactions persist this beside the compaction marker.
public struct MemoryCompactionApplicationSnapshot: Codable, Hashable, Sendable {
    public let threadID: String
    public let generation: Int
    public let reason: AgentContextCompactionReason
    public let clientRequestID: String?
    public let model: String?
    public let reasoningEffort: ReasoningEffort?
    public let activeSkillIDs: [String]
    public let promptRendererIdentifier: String
    public let compiledInstructionsSHA256: String
    public let query: MemoryQuery
    public let result: MemoryQueryResult
    public let renderedInstructions: String
    public let includedRecordIDs: [String]
    public let placement: MemoryInstructionPlacement

    public init(
        threadID: String,
        generation: Int,
        reason: AgentContextCompactionReason,
        clientRequestID: String? = nil,
        model: String? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        activeSkillIDs: [String] = [],
        promptRendererIdentifier: String,
        compiledInstructionsSHA256: String,
        query: MemoryQuery,
        result: MemoryQueryResult,
        renderedInstructions: String,
        includedRecordIDs: [String],
        placement: MemoryInstructionPlacement
    ) {
        self.threadID = threadID
        self.generation = generation
        self.reason = reason
        self.clientRequestID = clientRequestID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.activeSkillIDs = activeSkillIDs
        self.promptRendererIdentifier = promptRendererIdentifier
        self.compiledInstructionsSHA256 = compiledInstructionsSHA256
        self.query = query
        self.result = result
        self.renderedInstructions = renderedInstructions
        self.includedRecordIDs = includedRecordIDs
        self.placement = placement
    }
}

public extension MemoryPromptRendering {
    /// Existing renderers remain source compatible. Attribution is empty unless
    /// a renderer explicitly declares the records it included.
    func renderWithMetadata(
        result: MemoryQueryResult,
        budget: MemoryReadBudget
    ) -> RenderedMemoryPrompt {
        RenderedMemoryPrompt(
            instructions: render(result: result, budget: budget),
            includedRecordIDs: []
        )
    }
}

public extension MemoryObserving {
    /// Non-blocking notification sent after a threaded turn's durable record is
    /// written. Ephemeral turns have no durable record, so their notification
    /// is best effort. Recover threaded attribution from runtime history.
    func handle(application _: MemoryApplicationSnapshot) async {}

    /// Non-blocking notification sent after memory used by a compaction is
    /// durably recorded. The default keeps existing observers compatible.
    func handle(compactionApplication _: MemoryCompactionApplicationSnapshot) async {}
}
