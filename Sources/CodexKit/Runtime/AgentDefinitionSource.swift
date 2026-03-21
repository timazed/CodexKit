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
}

public actor AgentDefinitionSourceLoader {
    private struct SkillDocument: Codable {
        var id: String?
        var name: String?
        var instructions: String
        var executionPolicy: AgentSkillExecutionPolicy?
    }

    private let urlSession: URLSession
    private let decoder = JSONDecoder()

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
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
        let decodedDocument = decodeSkillDocument(from: text)

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
        let data: Data
        switch source {
        case let .file(url):
            data = try Data(contentsOf: url)
        case let .remote(url):
            let (responseData, response) = try await urlSession.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200 ... 299).contains(httpResponse.statusCode) {
                throw AgentDefinitionSourceError.unsupportedRemoteResponse(httpResponse.statusCode)
            }
            data = responseData
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentDefinitionSourceError.unreadableContent()
        }

        return text
    }

    private func decodeSkillDocument(from text: String) -> SkillDocument? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }

        if let decoded = try? decoder.decode(SkillDocument.self, from: data) {
            return decoded
        }

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        guard let instructions = object["instructions"] as? String else {
            return nil
        }

        let executionPolicy: AgentSkillExecutionPolicy? = if let policyObject = object["executionPolicy"],
                                                             JSONSerialization.isValidJSONObject(policyObject),
                                                             let policyData = try? JSONSerialization.data(withJSONObject: policyObject) {
            try? decoder.decode(AgentSkillExecutionPolicy.self, from: policyData)
        } else {
            nil
        }

        return SkillDocument(
            id: object["id"] as? String,
            name: object["name"] as? String,
            instructions: instructions,
            executionPolicy: executionPolicy
        )
    }
}
