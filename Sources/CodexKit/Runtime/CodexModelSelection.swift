import Foundation

/// Host constraints, not prompt content. Unknown capabilities are never treated as confirmed support.
public struct AgentModelRequirements: Codable, Hashable, Sendable {
    public var minimumContextWindowTokenCount: Int?
    public init(minimumContextWindowTokenCount: Int? = nil) {
        self.minimumContextWindowTokenCount = minimumContextWindowTokenCount
    }
}

public struct CodexModelSelection: Codable, Hashable, Sendable {
    public let configuration: AgentThreadConfiguration
    public let policyID: String
    public init(configuration: AgentThreadConfiguration, policyID: String = "host") {
        self.configuration = configuration
        self.policyID = String(policyID.prefix(128))
    }
}

/// An immutable description of one request. No access or refresh tokens are exposed.
public struct CodexModelSelectionContext: Sendable {
    public let purpose: String?
    public let responseFormat: AgentStructuredOutputFormat?
    public let defaultConfiguration: AgentThreadConfiguration
    public let requiresImages: Bool
    public let requirements: AgentModelRequirements
    public let accountBinding: ChatGPTSessionBinding
    private let discover: @Sendable (CodexModelRefreshPolicy) async throws -> CodexModelCatalogSnapshot

    init(request: Request, responseFormat: AgentStructuredOutputFormat?, defaults: AgentThreadConfiguration,
         binding: ChatGPTSessionBinding,
         discover: @escaping @Sendable (CodexModelRefreshPolicy) async throws -> CodexModelCatalogSnapshot) {
        purpose = request.selectionPurpose
        self.responseFormat = responseFormat
        defaultConfiguration = defaults
        requiresImages = !request.images.isEmpty
        requirements = request.modelRequirements ?? .init()
        accountBinding = binding
        self.discover = discover
    }

    /// Discovery is lazy: fixed policies do not need to make a catalog request.
    public func models(policy: CodexModelRefreshPolicy = .preferCached) async throws -> CodexModelCatalogSnapshot {
        try await discover(policy)
    }

    public func supports(_ configuration: AgentThreadConfiguration, model: CodexAvailableModel) -> Bool {
        guard model.model.rawValue == configuration.model,
              model.supportedReasoningEfforts.contains(configuration.reasoningEffort),
              !requiresImages || model.inputModalities.contains(.image) else { return false }
        if let minimum = requirements.minimumContextWindowTokenCount {
            guard let window = model.contextWindowTokenCount, window >= minimum else { return false }
        }
        return true
    }
}

public protocol CodexModelSelecting: Sendable {
    func selectModel(for context: CodexModelSelectionContext) async throws -> CodexModelSelection
}

public struct AnyCodexModelSelector: CodexModelSelecting {
    private let select: @Sendable (CodexModelSelectionContext) async throws -> CodexModelSelection
    public init(_ select: @escaping @Sendable (CodexModelSelectionContext) async throws -> CodexModelSelection) {
        self.select = select
    }
    public func selectModel(for context: CodexModelSelectionContext) async throws -> CodexModelSelection {
        try await select(context)
    }
}

public struct FixedCodexModelSelector: CodexModelSelecting {
    public let configuration: AgentThreadConfiguration
    public init(_ configuration: AgentThreadConfiguration) { self.configuration = configuration }
    public func selectModel(for context: CodexModelSelectionContext) async throws -> CodexModelSelection {
        .init(configuration: configuration, policyID: "fixed")
    }
}

/// Candidates are explicit model/effort pairs, in host preference order. No hidden quality ranking.
public struct PreferredAvailableCodexModelSelector: CodexModelSelecting {
    public let candidates: [AgentThreadConfiguration]
    public let refreshPolicy: CodexModelRefreshPolicy
    public let allowsStaleCatalog: Bool
    public init(candidates: [AgentThreadConfiguration], refreshPolicy: CodexModelRefreshPolicy = .preferCached,
                allowsStaleCatalog: Bool = false) {
        self.candidates = candidates
        self.refreshPolicy = refreshPolicy
        self.allowsStaleCatalog = allowsStaleCatalog
    }
    public func selectModel(for context: CodexModelSelectionContext) async throws -> CodexModelSelection {
        let catalog = try await context.models(policy: refreshPolicy)
        guard allowsStaleCatalog || !catalog.isStale else { throw AgentModelSelectionError.catalogUnavailable }
        for candidate in candidates {
            if catalog.models.contains(where: { context.supports(candidate, model: $0) }) {
                return .init(configuration: candidate, policyID: "preferred_available")
            }
        }
        throw AgentModelSelectionError.configurationUnavailable
    }
}

public enum AgentModelSelectionError: String, Error, Codable, Sendable, LocalizedError {
    case configurationUnavailable, catalogUnavailable, invalidConfiguration
    public var errorDescription: String? {
        switch self {
        case .configurationUnavailable: "No permitted model configuration satisfies this request."
        case .catalogUnavailable: "A sufficiently fresh account model catalog is unavailable."
        case .invalidConfiguration: "The selected model configuration is invalid."
        }
    }
}

/// Optional capability. Wrappers implement or delegate this before execution, not inside beginTurn.
public protocol AgentBackendRequestPreparing: AgentBackend {
    func prepareModelSelection(for request: Request, in thread: AgentThread,
        responseFormat: AgentStructuredOutputFormat?, session: ChatGPTSession) async throws -> CodexModelSelection
}

extension CodexResponsesBackend: AgentBackendRequestPreparing {
    public func prepareModelSelection(for request: Request, in thread: AgentThread,
        responseFormat: AgentStructuredOutputFormat?, session: ChatGPTSession) async throws -> CodexModelSelection {
        if let resolved = request.resolvedModelSelection { return resolved }
        let defaults = thread.configuration ?? configuration.defaultThreadConfiguration
        let selection: CodexModelSelection
        if let override = request.modelOverride {
            selection = .init(configuration: override, policyID: "request_override")
        } else if let modelSelector {
            let context = CodexModelSelectionContext(request: request, responseFormat: responseFormat,
                defaults: defaults, binding: session.binding, discover: { [self] policy in
                    try await self.listModels(session: session, policy: policy)
                })
            selection = try await modelSelector.selectModel(for: context)
        } else {
            selection = .init(configuration: defaults, policyID: "configured")
        }
        try Task.checkCancellation()
        guard !selection.configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selection.configuration.model.utf8.count <= 256 else { throw AgentModelSelectionError.invalidConfiguration }
        if modelSelector != nil || request.modelOverride != nil || request.modelRequirements != nil {
            let known = selection.configuration.codexModel.info
            let remote = modelCatalogs[session.binding.cacheKey]?.models.first { $0.model.rawValue == selection.configuration.model }
            let efforts = remote?.supportedReasoningEfforts ?? known?.supportedReasoningEfforts ?? []
            if !efforts.isEmpty, !efforts.contains(selection.configuration.reasoningEffort) {
                throw AgentModelSelectionError.configurationUnavailable
            }
            let modalities = remote?.inputModalities ?? known?.inputModalities
            if !request.images.isEmpty, let modalities, !modalities.contains(.image) {
                throw AgentModelSelectionError.configurationUnavailable
            }
            if let minimum = request.modelRequirements?.minimumContextWindowTokenCount {
                guard minimum > 0 else { throw AgentModelSelectionError.invalidConfiguration }
                guard let window = remote?.contextWindowTokenCount ?? known?.contextWindowTokenCount,
                      window >= minimum else { throw AgentModelSelectionError.configurationUnavailable }
            }
        }
        logger.info(.runtime, "Model configuration selected.", metadata: [
            "event": "model.selected", "model": selection.configuration.model,
            "reasoning_effort": selection.configuration.reasoningEffort.rawValue,
            "policy_id": selection.policyID
        ])
        return selection
    }
}
