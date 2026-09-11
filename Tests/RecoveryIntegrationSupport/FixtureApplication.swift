import CodexKit
import Foundation

public struct FixtureOutput: AgentStructuredOutput {
    public let value: String
    public static let responseFormat = AgentStructuredOutputFormat(name: "fixture-output",
        schema: .object(properties: ["value": .string()], required: ["value"]))
}
public struct ChangedFixtureOutput: AgentStructuredOutput {
    public let result: String
    public static let responseFormat = AgentStructuredOutputFormat(name: "fixture-output-v2",
        schema: .object(properties: ["result": .string()], required: ["result"]))
}
public actor FixtureSession: AgentSessionProviding {
    private var account = "fixture-account"
    private var token = "fixture-token"
    private var connected = true
    public private(set) var renewals = 0
    public init() {}
    public func currentSession() async -> ChatGPTSession? {
        guard connected else { return nil }
        return .init(accessToken: token, account: .init(id: account, email: "fixture@example.test", plan: .unknown))
    }
    public func recoverUnauthorizedSession(previousAccessToken: String?) async throws -> ChatGPTSession {
        renewals += 1; token = "renewed"
        guard let session = await currentSession() else { throw ChatGPTSessionError.disconnected }
        return session
    }
    public func rotateToken() { token = "rotated" }
    public func switchAccount() { account = "other-account" }
    public func signOut() { connected = false }
}
public actor PurposeSelector: CodexModelSelecting {
    public private(set) var purposes: [String] = []
    private var model: String
    public init(model: String = "gpt-5.6-sol") { self.model = model }
    public func changeModel(_ value: String) { model = value }
    public func selectModel(for context: CodexModelSelectionContext) async throws -> CodexModelSelection {
        purposes.append(context.purpose ?? "default")
        return .init(configuration: .init(model: model, reasoningEffort: context.purpose == "news" ? .high : .medium),
                     policyID: "fixture-purpose")
    }
}
public struct RejectingSelector: CodexModelSelecting {
    public init() {}
    public func selectModel(for context: CodexModelSelectionContext) async throws -> CodexModelSelection {
        throw AgentModelSelectionError.configurationUnavailable
    }
}
public struct FixtureApprovals: ApprovalPresenting {
    public init() {}
    public func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision { .denied }
}

/// An ordinary external wrapper, compiled without @testable or access to internal transport state.
public struct FixtureBackend: AgentBackend, AgentBackendRequestPreparing, AgentBackendStructuredRecoverySupporting,
    AgentBackendModelDiscovering, AgentBackendRateLimitProviding, AgentBackendProviderContextSupporting {
    public let wrapped: CodexResponsesBackend
    public init(_ wrapped: CodexResponsesBackend) { self.wrapped = wrapped }
    public var baseInstructions: String? { get async { await wrapped.baseInstructions } }
    public var defaultThreadConfiguration: AgentThreadConfiguration? { get async { await wrapped.defaultThreadConfiguration } }
    public var structuredRecoveryAdapter: AgentStructuredRecoveryAdapter { get async throws { await wrapped.structuredRecoveryAdapter } }
    public func createThread(session: ChatGPTSession) async throws -> AgentThread { try await wrapped.createThread(session: session) }
    public func resumeThread(id: String, session: ChatGPTSession) async throws -> AgentThread { try await wrapped.resumeThread(id: id, session: session) }
    public func prepareModelSelection(for request: Request, in thread: AgentThread,
        responseFormat: AgentStructuredOutputFormat?, session: ChatGPTSession) async throws -> CodexModelSelection {
        try await wrapped.prepareModelSelection(for: request, in: thread, responseFormat: responseFormat, session: session)
    }
    public func listModels(session: ChatGPTSession, policy: CodexModelRefreshPolicy) async throws -> CodexModelCatalogSnapshot {
        try await wrapped.listModels(session: session, policy: policy)
    }
    public func rateLimits(session: ChatGPTSession) async -> [AgentRateLimitSnapshot] { await wrapped.rateLimits(session: session) }
    public func beginTurn(thread: AgentThread, history: [AgentMessage], message: Request, instructions: String,
        responseFormat: AgentStructuredOutputFormat?, streamedStructuredOutput: AgentStreamedStructuredOutputRequest?,
        tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        try await wrapped.beginTurn(thread: thread, history: history, message: message, instructions: instructions,
            responseFormat: responseFormat, streamedStructuredOutput: streamedStructuredOutput, tools: tools, session: session)
    }
    public func beginTurn(thread: AgentThread, history: [AgentMessage], providerContext: AgentProviderContext?,
        message: Request, instructions: String, responseFormat: AgentStructuredOutputFormat?,
        streamedStructuredOutput: AgentStreamedStructuredOutputRequest?, tools: [ToolDefinition], session: ChatGPTSession) async throws -> AgentTurnStream {
        try await wrapped.beginTurn(thread: thread, history: history, providerContext: providerContext, message: message,
            instructions: instructions, responseFormat: responseFormat, streamedStructuredOutput: streamedStructuredOutput,
            tools: tools, session: session)
    }
}

public func fixtureRuntime(selector: (any CodexModelSelecting)? = nil, wrapper: Bool = true,
    session: FixtureSession = FixtureSession(), logging: AgentLoggingConfiguration = .disabled,
    maximumDuration: TimeInterval? = nil,
    background: any AgentBackgroundActivityProviding = NoOpAgentBackgroundActivityProvider()) throws -> AgentRuntime {
    let responses = CodexResponsesBackend(configuration: .init(enableWebSearch: true, enableImageGeneration: true,
        requestRetryPolicy: .init(maxAttempts: 9, initialBackoff: 0, maxBackoff: 0)),
        urlSession: FixtureTransport.session(), modelSelector: selector)
    let backend: any AgentBackend = wrapper ? FixtureBackend(responses) : responses
    return try .init(configuration: .init(sessionProvider: session, backend: backend,
        approvalPresenter: FixtureApprovals(), stateStore: InMemoryRuntimeStateStore(), logging: logging,
        turnLimits: .init(maximumDuration: maximumDuration), backgroundActivityProvider: background))
}

public actor FixtureHostStore {
    public struct Job: Codable, Sendable {
        public let id: String
        public let revision: String
        public var handle: AgentStructuredRecoveryHandle
        public var committedValue: String?
        public var commitCount = 0
    }
    private let path: URL
    private var jobs: [String: Job]
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("host.json")
        jobs = FileManager.default.fileExists(atPath: path.path)
            ? try JSONDecoder().decode([String: Job].self, from: Data(contentsOf: path)) : [:]
    }
    public func register(_ id: String, revision: String = "1", handle: AgentStructuredRecoveryHandle) throws {
        if var job = jobs[id] {
            guard job.revision == revision, job.committedValue == nil else { throw HostError.inapplicable }
            job.handle = handle; jobs[id] = job
        } else { jobs[id] = Job(id: id, revision: revision, handle: handle) }
        try persist()
    }
    @discardableResult
    public func commit(_ output: FixtureOutput, jobID: String, revision: String = "1", active: Bool = true) throws -> Bool {
        guard active, var job = jobs[jobID], job.revision == revision else { throw HostError.inapplicable }
        if job.committedValue != nil { return false }
        job.committedValue = output.value; job.commitCount += 1; jobs[jobID] = job
        try persist()
        return true
    }
    public func job(_ id: String) -> Job? { jobs[id] }
    private func persist() throws { try JSONEncoder().encode(jobs).write(to: path, options: .atomic) }
    public enum HostError: Error { case inapplicable }
}
