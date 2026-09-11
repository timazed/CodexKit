import Foundation

public enum RequestExecutionMode: String, Codable, Hashable, Sendable {
    case threaded
    case ephemeral
}

public enum AgentSkillSelection: Codable, Hashable, Sendable {
    case none
    case replace([String])
    case append([String])
}

public struct Request: Codable, Hashable, Sendable {
    public var text: String
    public var images: [AgentImageAttachment]
    /// Host-owned correlation identifier. CodexKit stores it with durable
    /// memory-application attribution but never sends it to the model.
    public var clientRequestID: String?
    public var executionMode: RequestExecutionMode
    public var personaOverride: AgentPersonaStack?
    public var skillSelection: AgentSkillSelection
    public var memorySelection: MemorySelection?
    /// Host-only routing information. Never added to model input.
    public var selectionPurpose: String?
    /// A binding per-request override; a selector cannot replace it.
    public var modelOverride: AgentThreadConfiguration?
    public var modelRequirements: AgentModelRequirements?
    var resolvedModelSelection: CodexModelSelection?
    var context: CompiledRequestContext?
    var options: CompiledRequestOptions?

    public init(
        text: String,
        images: [AgentImageAttachment] = [],
        executionMode: RequestExecutionMode = .threaded,
        personaOverride: AgentPersonaStack? = nil,
        skillSelection: AgentSkillSelection = .none,
        memorySelection: MemorySelection? = nil
    ) {
        self.text = text
        self.images = images
        clientRequestID = nil
        self.executionMode = executionMode
        context = nil
        options = nil
        self.personaOverride = personaOverride
        self.skillSelection = skillSelection
        self.memorySelection = memorySelection
        self.selectionPurpose = nil
        self.modelOverride = nil
        self.modelRequirements = nil
        self.resolvedModelSelection = nil
    }

    public init<Context: Encodable & Sendable, Options: RequestOptionsRepresentable>(
        text: String,
        images: [AgentImageAttachment] = [],
        context: Context?,
        options: Options? = nil,
        contextSchemaName: String? = nil,
        optionsSchemaName: String? = nil,
        executionMode: RequestExecutionMode = .threaded,
        personaOverride: AgentPersonaStack? = nil,
        skillSelection: AgentSkillSelection = .none,
        memorySelection: MemorySelection? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        self.init(
            text: text,
            images: images,
            executionMode: executionMode,
            personaOverride: personaOverride,
            skillSelection: skillSelection,
            memorySelection: memorySelection
        )
        self.context = try context.map {
                CompiledRequestContext(
                    schemaName: contextSchemaName,
                    payload: try JSONValue.encoding($0, encoder: encoder)
                )
            }
        self.options = options.map { options in
            CompiledRequestOptions(
                schemaName: optionsSchemaName ?? Options.schemaName,
                mode: options.mode.naturalLanguage,
                requirements: options.requirements.map(\.naturalLanguage)
            )
        }
    }

    public init<Context: Encodable & Sendable>(
        text: String,
        images: [AgentImageAttachment] = [],
        context: Context?,
        contextSchemaName: String? = nil,
        executionMode: RequestExecutionMode = .threaded,
        personaOverride: AgentPersonaStack? = nil,
        skillSelection: AgentSkillSelection = .none,
        memorySelection: MemorySelection? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        self.init(
            text: text,
            images: images,
            executionMode: executionMode,
            personaOverride: personaOverride,
            skillSelection: skillSelection,
            memorySelection: memorySelection
        )
        self.context = try context.map {
            CompiledRequestContext(
                schemaName: contextSchemaName,
                payload: try JSONValue.encoding($0, encoder: encoder)
            )
        }
    }

    public init<Options: RequestOptionsRepresentable>(
        text: String,
        images: [AgentImageAttachment] = [],
        options: Options?,
        optionsSchemaName: String? = nil,
        executionMode: RequestExecutionMode = .threaded,
        personaOverride: AgentPersonaStack? = nil,
        skillSelection: AgentSkillSelection = .none,
        memorySelection: MemorySelection? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        self.init(
            text: text,
            images: images,
            executionMode: executionMode,
            personaOverride: personaOverride,
            skillSelection: skillSelection,
            memorySelection: memorySelection
        )
        self.options = options.map { options in
            CompiledRequestOptions(
                schemaName: optionsSchemaName ?? Options.schemaName,
                mode: options.mode.naturalLanguage,
                requirements: options.requirements.map(\.naturalLanguage)
            )
        }
    }

    public init(
        prompt: String? = nil,
        importedContent: AgentImportedContent,
        executionMode: RequestExecutionMode = .threaded,
        personaOverride: AgentPersonaStack? = nil,
        skillSelection: AgentSkillSelection = .none
    ) {
        self.init(
            prompt: prompt,
            importedContent: importedContent,
            compiledContext: nil,
            compiledOptions: nil,
            executionMode: executionMode,
            personaOverride: personaOverride,
            skillSelection: skillSelection
        )
    }

    init(
        prompt: String? = nil,
        importedContent: AgentImportedContent,
        compiledContext: CompiledRequestContext? = nil,
        compiledOptions: CompiledRequestOptions? = nil,
        executionMode: RequestExecutionMode = .threaded,
        personaOverride: AgentPersonaStack? = nil,
        skillSelection: AgentSkillSelection = .none
    ) {
        self.init(
            text: importedContent.composedText(prompt: prompt),
            images: importedContent.images,
            executionMode: executionMode,
            personaOverride: personaOverride,
            skillSelection: skillSelection
        )
        context = compiledContext
        options = compiledOptions
    }

    public var hasContent: Bool {
        hasVisibleContent || context != nil
    }

    public var hasVisibleContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    public var isEphemeral: Bool {
        executionMode == .ephemeral
    }

    /// Returns a copy carrying a host-only correlation identifier. The value is
    /// persisted with memory attribution and is not included in model input.
    public func correlated(with clientRequestID: String?) -> Request {
        var request = self
        request.clientRequestID = clientRequestID
        return request
    }

    enum CodingKeys: String, CodingKey {
        case selectionPurpose, modelOverride, modelRequirements
        case text
        case images
        case clientRequestID
        case executionMode
        case context
        case options
        case personaOverride
        case skillSelection
        case memorySelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decodeIfPresent([AgentImageAttachment].self, forKey: .images) ?? []
        clientRequestID = try container.decodeIfPresent(String.self, forKey: .clientRequestID)
        executionMode = try container.decodeIfPresent(RequestExecutionMode.self, forKey: .executionMode) ?? .threaded
        context = try container.decodeIfPresent(CompiledRequestContext.self, forKey: .context)
        options = try container.decodeIfPresent(CompiledRequestOptions.self, forKey: .options)
        personaOverride = try container.decodeIfPresent(AgentPersonaStack.self, forKey: .personaOverride)
        skillSelection = try container.decodeIfPresent(AgentSkillSelection.self, forKey: .skillSelection) ?? .none
        memorySelection = try container.decodeIfPresent(MemorySelection.self, forKey: .memorySelection)
        selectionPurpose = try container.decodeIfPresent(String.self, forKey: .selectionPurpose)
        modelOverride = try container.decodeIfPresent(AgentThreadConfiguration.self, forKey: .modelOverride)
        modelRequirements = try container.decodeIfPresent(AgentModelRequirements.self, forKey: .modelRequirements)
        resolvedModelSelection = nil
    }
}
