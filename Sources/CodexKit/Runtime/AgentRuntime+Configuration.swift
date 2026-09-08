import Foundation

extension AgentRuntime {
    public struct Configuration: Sendable {
        /// Present only for the built-in ChatGPT authentication configuration.
        public let authProvider: ChatGPTAuthProvider?
        public let secureStore: KeychainSessionSecureStore?
        public let sessionProvider: (any AgentSessionProviding)?
        let makeSessionProvider: @Sendable () -> any AgentSessionProviding
        public let backend: any AgentBackend
        public let approvalPresenter: any ApprovalPresenting
        public let stateStore: any RuntimeStateStoring
        public let logging: AgentLoggingConfiguration
        public let memory: AgentMemoryConfiguration?
        public let baseInstructions: String?
        public let maximumParallelToolCalls: Int
        public let maximumBufferedEvents: Int
        public let turnLimits: AgentTurnLimits
        public let tools: [ToolRegistration]
        public let skills: [AgentSkill]
        public let definitionSourceLoader: AgentDefinitionSourceLoader
        public let contextCompaction: AgentContextCompactionConfiguration
        public let threadActivationPolicy: AgentThreadActivationPolicy
        public let backgroundActivityProvider: any AgentBackgroundActivityProviding

        public init(
            authProvider: ChatGPTAuthProvider,
            secureStore: KeychainSessionSecureStore,
            backend: any AgentBackend,
            approvalPresenter: any ApprovalPresenting,
            stateStore: any RuntimeStateStoring,
            logging: AgentLoggingConfiguration = .disabled,
            memory: AgentMemoryConfiguration? = nil,
            baseInstructions: String? = nil,
            maximumParallelToolCalls: Int = 4,
            maximumBufferedEvents: Int = 64,
            turnLimits: AgentTurnLimits = .init(),
            tools: [ToolRegistration] = [],
            skills: [AgentSkill] = [],
            definitionSourceLoader: AgentDefinitionSourceLoader = AgentDefinitionSourceLoader(),
            contextCompaction: AgentContextCompactionConfiguration = AgentContextCompactionConfiguration(),
            threadActivationPolicy: AgentThreadActivationPolicy = AgentThreadActivationPolicy(),
            backgroundActivityProvider: any AgentBackgroundActivityProviding = NoOpAgentBackgroundActivityProvider()
        ) {
            self.sessionProvider = nil
            self.makeSessionProvider = { ChatGPTSessionManager(authProvider: authProvider, secureStore: secureStore, logging: logging) }
            self.authProvider = authProvider
            self.secureStore = secureStore
            self.backend = backend
            self.approvalPresenter = approvalPresenter
            self.stateStore = stateStore
            self.logging = logging
            self.memory = memory
            self.baseInstructions = baseInstructions
            self.maximumParallelToolCalls = max(1, maximumParallelToolCalls)
            self.maximumBufferedEvents = max(1, min(maximumBufferedEvents, 4_096))
            self.turnLimits = turnLimits
            self.tools = tools
            self.skills = skills
            self.definitionSourceLoader = definitionSourceLoader
            self.contextCompaction = contextCompaction
            self.threadActivationPolicy = threadActivationPolicy
            self.backgroundActivityProvider = backgroundActivityProvider
        }
        public init(
            sessionProvider: any AgentSessionProviding,
            backend: any AgentBackend,
            approvalPresenter: any ApprovalPresenting,
            stateStore: any RuntimeStateStoring,
            logging: AgentLoggingConfiguration = .disabled,
            memory: AgentMemoryConfiguration? = nil,
            baseInstructions: String? = nil,
            maximumParallelToolCalls: Int = 4,
            maximumBufferedEvents: Int = 64,
            turnLimits: AgentTurnLimits = .init(),
            tools: [ToolRegistration] = [],
            skills: [AgentSkill] = [],
            definitionSourceLoader: AgentDefinitionSourceLoader = AgentDefinitionSourceLoader(),
            contextCompaction: AgentContextCompactionConfiguration = AgentContextCompactionConfiguration(),
            threadActivationPolicy: AgentThreadActivationPolicy = AgentThreadActivationPolicy(),
            backgroundActivityProvider: any AgentBackgroundActivityProviding = NoOpAgentBackgroundActivityProvider()
        ) {
            self.authProvider = nil
            self.secureStore = nil
            self.sessionProvider = sessionProvider
            self.makeSessionProvider = { sessionProvider }
            self.backend = backend
            self.approvalPresenter = approvalPresenter
            self.stateStore = stateStore
            self.logging = logging
            self.memory = memory
            self.baseInstructions = baseInstructions
            self.maximumParallelToolCalls = max(1, maximumParallelToolCalls)
            self.maximumBufferedEvents = max(1, min(maximumBufferedEvents, 4_096))
            self.turnLimits = turnLimits
            self.tools = tools
            self.skills = skills
            self.definitionSourceLoader = definitionSourceLoader
            self.contextCompaction = contextCompaction
            self.threadActivationPolicy = threadActivationPolicy
            self.backgroundActivityProvider = backgroundActivityProvider
        }
    }
}
