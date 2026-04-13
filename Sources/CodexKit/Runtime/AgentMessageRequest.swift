import Foundation

public struct AgentStructuredInput: Codable, Hashable, Sendable {
    public var schemaName: String?
    public var payload: JSONValue

    public init(
        schemaName: String? = nil,
        payload: JSONValue
    ) {
        self.schemaName = schemaName
        self.payload = payload
    }
}

public struct AgentStructuredSection: Codable, Hashable, Sendable {
    public var name: String
    public var schemaName: String?
    public var payload: JSONValue

    public init(
        name: String,
        schemaName: String? = nil,
        payload: JSONValue
    ) {
        self.name = name
        self.schemaName = schemaName
        self.payload = payload
    }
}

public struct AgentMessageRequest<Input: Encodable & Sendable>: Sendable {
    public var text: String
    public var images: [AgentImageAttachment]
    public var structuredInput: Input?
    public var structuredInputSchemaName: String?
    public var structuredSections: [AgentStructuredSection]
    public var personaOverride: AgentPersonaStack?
    public var skillOverrideIDs: [String]?
    public var memorySelection: MemorySelection?

    public init(
        text: String,
        images: [AgentImageAttachment] = [],
        structuredInput: Input? = nil,
        structuredInputSchemaName: String? = nil,
        structuredSections: [AgentStructuredSection] = [],
        personaOverride: AgentPersonaStack? = nil,
        skillOverrideIDs: [String]? = nil,
        memorySelection: MemorySelection? = nil
    ) {
        self.text = text
        self.images = images
        self.structuredInput = structuredInput
        self.structuredInputSchemaName = structuredInputSchemaName
        self.structuredSections = structuredSections
        self.personaOverride = personaOverride
        self.skillOverrideIDs = skillOverrideIDs
        self.memorySelection = memorySelection
    }

    public init(
        prompt: String? = nil,
        importedContent: AgentImportedContent,
        structuredInput: Input? = nil,
        structuredInputSchemaName: String? = nil,
        structuredSections: [AgentStructuredSection] = [],
        personaOverride: AgentPersonaStack? = nil,
        skillOverrideIDs: [String]? = nil,
        memorySelection: MemorySelection? = nil
    ) {
        self.init(
            text: importedContent.composedText(prompt: prompt),
            images: importedContent.images,
            structuredInput: structuredInput,
            structuredInputSchemaName: structuredInputSchemaName,
            structuredSections: structuredSections,
            personaOverride: personaOverride,
            skillOverrideIDs: skillOverrideIDs,
            memorySelection: memorySelection
        )
    }

    public func resolved(
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> UserMessageRequest {
        let resolvedStructuredInput = try structuredInput.map {
            AgentStructuredInput(
                schemaName: structuredInputSchemaName,
                payload: try JSONValue.encoding($0, encoder: encoder)
            )
        }

        return UserMessageRequest(
            text: text,
            images: images,
            structuredInput: resolvedStructuredInput,
            structuredSections: structuredSections,
            personaOverride: personaOverride,
            skillOverrideIDs: skillOverrideIDs,
            memorySelection: memorySelection
        )
    }
}
