import Foundation

/// A validated, immutable snapshot of the format's execution configuration.
/// Generation and persistence use the same instructions and schema identity.
struct AgentPreparedOutput<Format: AgentOutputFormat>: Sendable {
    let format: Format
    let instructions: String
    let schema: String?
    let persistence: AgentOutputPersistence<Format.Output>?

    init(_ format: Format, isEphemeral: Bool) throws {
        try format.limits.validate()
        let instructions = try format.formatInstructions
        let schema = try format.schemaRepresentation
        let persistence = try format.persistence

        guard !format.name.isEmpty,
            format.name.utf8.count <= 1_024,
            instructions.utf8.count <= format.limits.maximumSchemaBytes,
            (schema?.utf8.count ?? 0) <= format.limits.maximumSchemaBytes
        else {
            throw AgentOutputError.invalidFormat("Output name, schema, or instructions exceed limits.")
        }
        guard isEphemeral || persistence != nil else {
            throw AgentOutputError.persistenceUnavailable
        }

        self.format = format
        self.instructions = instructions
        self.schema = schema
        self.persistence = persistence
    }
}
