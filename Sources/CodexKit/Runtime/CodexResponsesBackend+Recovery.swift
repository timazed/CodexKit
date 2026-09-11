import CryptoKit
import Foundation

/// Wrappers delegate this value from their underlying Responses backend. They cannot replace its transport gates.
public protocol AgentBackendStructuredRecoverySupporting: AgentBackend {
    var structuredRecoveryAdapter: AgentStructuredRecoveryAdapter { get async throws }
}

public struct AgentStructuredRecoveryAdapter: Sendable {
    let backend: CodexResponsesBackend
    init(backend: CodexResponsesBackend) { self.backend = backend }

    func prepare(thread: AgentThread, request: Request, instructions: String,
                 format: AgentStructuredOutputFormat, session: ChatGPTSession) async throws -> AgentRecoveryPreparedRequest {
        let config = backend.configuration
        guard let scheme = config.baseURL.scheme, let host = config.baseURL.host,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              config.baseURL.user == nil, config.baseURL.password == nil,
              config.baseURL.query == nil, config.baseURL.fragment == nil else {
            throw AgentModelSelectionError.invalidConfiguration
        }
        var items: [WorkingHistoryItem] = []
        var sections: [String] = []
        if let context = request.context {
            sections.append(RequestContextTransport(schemaName: context.schemaName, payload: context.payload).formattedText)
        }
        if let options = request.options {
            sections.append(RequestOptionsTransport(mode: options.mode, requirements: options.requirements).formattedText)
        }
        if !sections.isEmpty { items.append(.developerMessage(sections.joined(separator: "\n\n"))) }
        if request.hasVisibleContent {
            items.append(.userMessage(.init(threadID: thread.id, role: .user, text: request.text, images: request.images)))
        }
        let wire = try CodexResponsesRequestFactory(configuration: config, encoder: JSONEncoder()).buildURLRequest(
            threadConfiguration: thread.configuration ?? config.defaultThreadConfiguration, instructions: instructions,
            responseContract: .init(format: format, deliveryMode: .oneShot), threadID: thread.id,
            items: items, tools: [], session: session, recoveryMode: true)
        guard let body = wire.httpBody else { throw AgentRecoveryError.stateInvalid }
        return .init(endpoint: config.baseURL, body: body,
                     digest: Self.digest(body), enableReasoningSummaries: config.enableReasoningSummaries)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct AgentRecoveryPreparedRequest: Codable, Sendable {
    let endpoint: URL
    let body: Data
    let digest: String
    let enableReasoningSummaries: Bool
    func validate() throws {
        guard AgentStructuredRecoveryAdapter.digest(body) == digest,
              let value = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tools = value["tools"] as? [Any], tools.isEmpty,
              value["tool_choice"] as? String == "none", value["store"] as? Bool == false,
              value["stream"] as? Bool == true else { throw AgentRecoveryError.stateInvalid }
    }
}

extension CodexResponsesBackend: AgentBackendStructuredRecoverySupporting {
    public var structuredRecoveryAdapter: AgentStructuredRecoveryAdapter { .init(backend: self) }
}
