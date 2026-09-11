import Foundation

public enum CodexModelRefreshPolicy: Sendable {
    /// Use a fresh cache, otherwise refresh; fall back to stale or bundled data on failure.
    case preferCached
    /// Require a successful refresh (or a not-modified response).
    case refresh
    /// Never perform network I/O.
    case cachedOnly
}

public struct CodexAvailableModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String { model.rawValue }
    public let model: CodexModel
    public let displayName: String
    public let summary: String
    public let defaultReasoningEffort: ReasoningEffort
    public let supportedReasoningEfforts: [ReasoningEffort]
    public let inputModalities: [CodexModelInputModality]
    public let contextWindowTokenCount: Int?
    public let hidden: Bool
    public let supportsParallelToolCalls: Bool?
    public let supportsImageDetailOriginal: Bool?

    public init(model: CodexModel, displayName: String, summary: String,
                defaultReasoningEffort: ReasoningEffort, supportedReasoningEfforts: [ReasoningEffort],
                inputModalities: [CodexModelInputModality], contextWindowTokenCount: Int? = nil,
                hidden: Bool = false, supportsParallelToolCalls: Bool? = nil,
                supportsImageDetailOriginal: Bool?) {
        self.model = model
        self.displayName = displayName
        self.summary = summary
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.inputModalities = inputModalities
        self.contextWindowTokenCount = contextWindowTokenCount
        self.hidden = hidden
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.supportsImageDetailOriginal = supportsImageDetailOriginal
    }

    public init(model: CodexModel, displayName: String, summary: String,
        defaultReasoningEffort: ReasoningEffort, supportedReasoningEfforts: [ReasoningEffort],
        inputModalities: [CodexModelInputModality], contextWindowTokenCount: Int? = nil,
        hidden: Bool = false, supportsParallelToolCalls: Bool? = nil) {
        self.init(model: model, displayName: displayName, summary: summary,
            defaultReasoningEffort: defaultReasoningEffort, supportedReasoningEfforts: supportedReasoningEfforts,
            inputModalities: inputModalities, contextWindowTokenCount: contextWindowTokenCount,
            hidden: hidden, supportsParallelToolCalls: supportsParallelToolCalls, supportsImageDetailOriginal: nil)
    }

}

public struct CodexModelCatalogSnapshot: Sendable {
    public enum Source: String, Codable, Hashable, Sendable { case remote, cache, bundled }
    public let models: [CodexAvailableModel]
    public let source: Source
    public let fetchedAt: Date?
    public let isStale: Bool
    public var visibleModels: [CodexAvailableModel] { models.filter { !$0.hidden } }

    public init(models: [CodexAvailableModel], source: Source, fetchedAt: Date? = nil, isStale: Bool = false) {
        self.models = models
        self.source = source
        self.fetchedAt = fetchedAt
        self.isStale = isStale
    }
}

public protocol AgentBackendModelDiscovering: AgentBackend {
    func listModels(session: ChatGPTSession, policy: CodexModelRefreshPolicy) async throws -> CodexModelCatalogSnapshot
}

public protocol AgentBackendRateLimitProviding: AgentBackend {
    func rateLimits(session: ChatGPTSession) async -> [AgentRateLimitSnapshot]
}

extension AgentRuntime {
    public func listModels(policy: CodexModelRefreshPolicy = .preferCached) async throws -> CodexModelCatalogSnapshot {
        guard let backend = backend as? any AgentBackendModelDiscovering else {
            return .bundled
        }
        let session = try await sessionManager.requireSession()
        return try await withUnauthorizedRecovery(initialSession: session) {
            try await backend.listModels(session: $0, policy: policy)
        }.result
    }

    /// Latest limits observed for the signed-in account, including failed HTTP requests.
    public func rateLimits() async throws -> [AgentRateLimitSnapshot] {
        guard let backend = backend as? any AgentBackendRateLimitProviding else { return [] }
        return try await backend.rateLimits(session: sessionManager.requireSession())
    }
}

struct CodexModelCacheEntry: Sendable {
    let models: [CodexAvailableModel]
    let fetchedAt: Date
    let etag: String?
}

extension CodexResponsesBackend: AgentBackendModelDiscovering, AgentBackendRateLimitProviding {
    public func listModels(session: ChatGPTSession,
                           policy: CodexModelRefreshPolicy = .preferCached) async throws -> CodexModelCatalogSnapshot {
        let accountID = session.account.id
        let cacheKey = session.binding.cacheKey
        catalogAccountID = cacheKey
        let cached = modelCatalogs[cacheKey]
        let fresh = cached.map { Date().timeIntervalSince($0.fetchedAt) < 300 } ?? false
        if case .cachedOnly = policy { return cachedSnapshot(cached, stale: !fresh) }
        if case .preferCached = policy, fresh { return cachedSnapshot(cached, stale: false) }
        do {
            var components = URLComponents(url: configuration.baseURL.appendingPathComponent("models"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "client_version", value: configuration.modelClientVersion)]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = configuration.streamIdleTimeout
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            request.setValue(configuration.originator, forHTTPHeaderField: "originator")
            request.setValue(cached?.etag, forHTTPHeaderField: "If-None-Match")
            for (key, value) in configuration.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw AgentRuntimeError(code: "models_invalid_response", message: "Invalid model catalog response.")
            }
            await rateLimitStore.update(CodexRateLimitParser.headers(response), accountID: cacheKey)
            if response.statusCode == 304, let cached {
                let updated = CodexModelCacheEntry(models: cached.models, fetchedAt: Date(), etag: cached.etag)
                modelCatalogs[cacheKey] = updated
                return cachedSnapshot(updated, stale: false)
            }
            guard (200..<300).contains(response.statusCode) else {
                var errorBody = Data()
                for try await byte in bytes {
                    if errorBody.count == AgentStoreLimits.maximumResponseErrorBodyByteCount { break }
                    errorBody.append(byte)
                }
                throw AgentRuntimeError.httpFailure(response: response, body: errorBody, prefix: "models",
                    message: "Model discovery failed with status \(response.statusCode).")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 8 * 1_024 * 1_024 else {
                    throw AgentRuntimeError(code: "models_response_too_large", message: "Model catalog exceeded 8 MiB.")
                }
                data.append(byte)
            }
            let models = try Self.decodeModels(data)
            let entry = CodexModelCacheEntry(models: models, fetchedAt: Date(),
                                            etag: response.value(forHTTPHeaderField: "ETag"))
            modelCatalogs[cacheKey] = entry
            return .init(models: models, source: .remote, fetchedAt: entry.fetchedAt, isStale: false)
        } catch {
            try Task.checkCancellation()
            if case .refresh = policy { throw error }
            if let error = error as? AgentRuntimeError, error.code == AgentRuntimeError.unauthorized().code { throw error }
            return cachedSnapshot(cached, stale: true)
        }
    }

    public func rateLimits(session: ChatGPTSession) async -> [AgentRateLimitSnapshot] {
        await rateLimitStore.snapshots(accountID: session.binding.cacheKey)
    }

    private func cachedSnapshot(_ entry: CodexModelCacheEntry?, stale: Bool) -> CodexModelCatalogSnapshot {
        guard let entry else { return .bundled }
        return .init(models: entry.models, source: .cache, fetchedAt: entry.fetchedAt, isStale: stale)
    }

    static func decodeModels(_ data: Data) throws -> [CodexAvailableModel] {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let models = value.objectValue?["models"]?.arrayValue else {
            throw AgentRuntimeError(code: "models_invalid_catalog", message: "Model catalog has no models array.")
        }
        var seen: Set<String> = []
        var catalog: [CodexAvailableModel] = []
        catalog.reserveCapacity(models.count)
        for model in models {
            guard let m = model.objectValue, let slug = m["slug"]?.stringValue,
                  !slug.isEmpty, seen.insert(slug).inserted else { continue }
            let identifier = CodexModel(rawValue: slug)
            let known = identifier.info
            let remoteLevels: [ReasoningEffort]? = m["supported_reasoning_levels"]?.arrayValue?.compactMap {
                $0.objectValue?["effort"]?.stringValue.flatMap(ReasoningEffort.init(rawValue:))
            }
            let levels = remoteLevels ?? known?.supportedReasoningEfforts ?? []
            let defaultEffort: ReasoningEffort = m["default_reasoning_level"]?.stringValue
                .flatMap(ReasoningEffort.init(rawValue:)) ?? .medium
            let modalities: [CodexModelInputModality] = m["input_modalities"]?.arrayValue?.compactMap {
                $0.stringValue.flatMap(CodexModelInputModality.init(rawValue:))
            } ?? [.text, .image]
            let context: Int? = {
                guard case let .number(n) = m["context_window"], n > 0 else { return known?.contextWindowTokenCount }
                return Int(exactly: n)
            }()
            let parallel: Bool? = { if case let .bool(b) = m["supports_parallel_tool_calls"] { return b }; return nil }()
            catalog.append(CodexAvailableModel(
                model: identifier, displayName: m["display_name"]?.stringValue ?? slug,
                summary: m["description"]?.stringValue ?? "", defaultReasoningEffort: defaultEffort,
                supportedReasoningEfforts: levels, inputModalities: modalities,
                contextWindowTokenCount: context, hidden: m["visibility"]?.stringValue != "list",
                supportsParallelToolCalls: parallel,
                supportsImageDetailOriginal: m["supports_image_detail_original"] == .bool(true)
            ))
        }
        return catalog
    }
}

extension CodexModelCatalogSnapshot {
    static var bundled: Self {
        .init(models: CodexModel.catalog.map {
            .init(model: $0.model, displayName: $0.displayName, summary: $0.summary,
                  defaultReasoningEffort: $0.defaultReasoningEffort, supportedReasoningEfforts: $0.supportedReasoningEfforts,
                  inputModalities: $0.inputModalities, contextWindowTokenCount: $0.contextWindowTokenCount,
                  hidden: !CodexModel.userFacingModels.contains($0.model),
                  supportsImageDetailOriginal: $0.supportsImageDetailOriginal)
        }, source: .bundled, fetchedAt: nil, isStale: true)
    }
}

actor CodexRateLimitStore {
    private var accounts: [String: [String: AgentRateLimitSnapshot]] = [:]
    func update(_ snapshots: [AgentRateLimitSnapshot], accountID: String) {
        for snapshot in snapshots { accounts[accountID, default: [:]][snapshot.limitID] = snapshot }
    }
    func snapshots(accountID: String) -> [AgentRateLimitSnapshot] {
        (accounts[accountID] ?? [:]).values.sorted { $0.limitID < $1.limitID }
    }
}
