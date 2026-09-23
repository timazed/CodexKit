import Foundation

extension CodexResponsesBackendConfiguration {
    var webSearchCapabilities: AgentWebSearchCapabilities {
        .init(defaultPolicy: enableWebSearch ? (webSearchPolicy ?? .init(mode: .live)) : .init(mode: .disabled),
            supportedModes: Set(AgentWebSearchPolicy.Mode.allCases), supportsAllowedDomains: true)
    }
}

extension CodexResponsesBackend {
    public var webSearchCapabilities: AgentWebSearchCapabilities? { configuration.webSearchCapabilities }
}
