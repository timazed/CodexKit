import Foundation

public enum AgentDefinitionSource: Hashable, Sendable {
    case file(URL)
    case remote(URL)
}

public struct AgentDefinitionSourceError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message
    }

    public static func unsupportedRemoteResponse(_ statusCode: Int) -> AgentDefinitionSourceError {
        AgentDefinitionSourceError(
            code: "unsupported_remote_response",
            message: "Remote definition request failed with status code \(statusCode)."
        )
    }

    public static func unreadableContent() -> AgentDefinitionSourceError {
        AgentDefinitionSourceError(
            code: "unreadable_content",
            message: "The definition content could not be decoded as UTF-8 text."
        )
    }

    public static func emptyInstructions() -> AgentDefinitionSourceError {
        AgentDefinitionSourceError(
            code: "empty_instructions",
            message: "The definition did not contain any usable instructions."
        )
    }

    public static func missingSkillIdentity() -> AgentDefinitionSourceError {
        AgentDefinitionSourceError(
            code: "missing_skill_identity",
            message: "A skill loaded from this source must include an id and name, or they must be provided by the caller."
        )
    }

    public static func invalidSkillID(_ skillID: String) -> AgentDefinitionSourceError {
        AgentDefinitionSourceError(
            code: "invalid_skill_id",
            message: "The skill ID \(skillID) is invalid. Skill IDs must match ^[a-zA-Z0-9_-]+$."
        )
    }

    public static func invalidSkillDefinition() -> AgentDefinitionSourceError {
        .init(code: "invalid_skill_definition", message: "The JSON skill definition or its execution policy is invalid. Check field names, value types, tool names, and nonnegative tool-call limits.")
    }

    public static func definitionTooLarge(maximumBytes: Int) -> AgentDefinitionSourceError {
        .init(code: "definition_too_large", message: "Definition content exceeds the configured limit of \(maximumBytes) bytes.")
    }
}

public actor AgentDefinitionSourceLoader {
    private struct SkillDocument: Decodable {
        var id: String?
        var name: String?
        var instructions: String
        var executionPolicy: AgentSkillExecutionPolicy?

        private enum CodingKeys: String, CodingKey { case id, name, instructions, executionPolicy }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: DefinitionField.self).allKeys
            guard fields.allSatisfy({ CodingKeys(rawValue: $0.stringValue) != nil }) else {
                throw AgentDefinitionSourceError.invalidSkillDefinition()
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            instructions = try container.decode(String.self, forKey: .instructions)
            if container.contains(.executionPolicy), try !container.decodeNil(forKey: .executionPolicy) {
                let policyDecoder = try container.superDecoder(forKey: .executionPolicy)
                let fields = try policyDecoder.container(keyedBy: DefinitionField.self).allKeys
                let supported = Set(["allowedToolNames", "requiredToolNames", "toolSequence", "maxToolCalls"])
                guard fields.allSatisfy({ supported.contains($0.stringValue) }) else {
                    throw AgentDefinitionSourceError.invalidSkillDefinition()
                }
                let policy = try AgentSkillExecutionPolicy(from: policyDecoder)
                let names = (policy.allowedToolNames ?? []) + policy.requiredToolNames + (policy.toolSequence ?? [])
                guard policy.maxToolCalls.map({ $0 >= 0 }) ?? true,
                      names.allSatisfy(ToolDefinition.isValidName) else {
                    throw AgentDefinitionSourceError.invalidSkillDefinition()
                }
                executionPolicy = policy
            }
        }
    }

    private struct DefinitionField: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private let urlSession: URLSession
    private let decoder = JSONDecoder()
    public let maximumDefinitionBytes: Int

    /// Applies to both files and remote bodies, before text or JSON decoding.
    public init(urlSession: URLSession = .shared, maximumDefinitionBytes: Int = 1_024 * 1_024) {
        self.urlSession = urlSession
        self.maximumDefinitionBytes = maximumDefinitionBytes
    }

    public func loadPersonaStack(
        from source: AgentDefinitionSource,
        defaultLayerName: String = "dynamic_persona"
    ) async throws -> AgentPersonaStack {
        let text = try await loadText(from: source)
        if let jsonData = text.data(using: .utf8),
           let stack = try? decoder.decode(AgentPersonaStack.self, from: jsonData),
           !stack.layers.isEmpty {
            return stack
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentDefinitionSourceError.emptyInstructions()
        }

        return AgentPersonaStack(layers: [
            .init(name: defaultLayerName, instructions: trimmed),
        ])
    }

    public func loadSkill(
        from source: AgentDefinitionSource,
        id: String? = nil,
        name: String? = nil
    ) async throws -> AgentSkill {
        let text = try await loadText(from: source)
        let decodedDocument = try decodeSkillDocument(from: text)

        let resolvedInstructions = (decodedDocument?.instructions ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedInstructions.isEmpty else {
            throw AgentDefinitionSourceError.emptyInstructions()
        }

        let resolvedID = (id ?? decodedDocument?.id)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (name ?? decodedDocument?.name)?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let finalID = resolvedID, !finalID.isEmpty else {
            throw AgentDefinitionSourceError.missingSkillIdentity()
        }
        guard AgentSkill.isValidID(finalID) else {
            throw AgentDefinitionSourceError.invalidSkillID(finalID)
        }

        let finalName = (resolvedName?.isEmpty == false) ? resolvedName! : finalID

        return AgentSkill(
            id: finalID,
            name: finalName,
            instructions: resolvedInstructions,
            executionPolicy: decodedDocument?.executionPolicy
        )
    }

    public func loadText(from source: AgentDefinitionSource) async throws -> String {
        try Task.checkCancellation()
        guard maximumDefinitionBytes > 0 else {
            throw AgentDefinitionSourceError(code: "invalid_definition_limit", message: "The definition byte limit must be positive.")
        }
        let data: Data
        switch source {
        case let .file(url):
            data = try readFile(url)
        case let .remote(url):
            data = try await readRemote(url)
        }

        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentDefinitionSourceError.unreadableContent()
        }

        return text
    }

    private func decodeSkillDocument(from text: String) throws -> SkillDocument? {
        // JSON object definitions must not fall back to unrestricted plain text.
        let jsonText = text.first == "\u{FEFF}" ? text.dropFirst() : text[...]
        guard jsonText.first(where: { !$0.isWhitespace }) == "{" else { return nil }
        do { return try decoder.decode(SkillDocument.self, from: Data(jsonText.utf8)) }
        catch { throw AgentDefinitionSourceError.invalidSkillDefinition() }
    }

    private func readFile(_ url: URL) throws -> Data {
        guard url.isFileURL else {
            throw AgentDefinitionSourceError(code: "invalid_definition_file", message: "A file definition must be a regular local file.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw AgentDefinitionSourceError(code: "invalid_definition_file", message: "A file definition must be a regular local file.")
        }
        guard (values.fileSize ?? 0) <= maximumDefinitionBytes else { throw sizeError() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = maximumDefinitionBytes - data.count
            let chunk = try handle.read(upToCount: max(1, min(65_536, remaining))) ?? Data()
            if chunk.isEmpty { return data }
            guard chunk.count <= remaining else { throw sizeError() }
            data.append(chunk)
        }
    }

    private func readRemote(_ url: URL) async throws -> Data {
        let (bytes, response) = try await urlSession.bytes(from: url)
        defer { bytes.task.cancel() }
        if let response = response as? HTTPURLResponse, !(200 ... 299).contains(response.statusCode) {
            throw AgentDefinitionSourceError.unsupportedRemoteResponse(response.statusCode)
        }
        guard response.expectedContentLength <= Int64(maximumDefinitionBytes) else { throw sizeError() }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumDefinitionBytes else { throw sizeError() }
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        return data
    }

    private func sizeError() -> AgentDefinitionSourceError {
        .definitionTooLarge(maximumBytes: maximumDefinitionBytes)
    }
}
