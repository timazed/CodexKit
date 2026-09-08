import CodexKit
import XCTest

/// Compile ordinary initializer call shapes used by the previous alpha release
/// without @testable access. Exact initializer-function references require the
/// closure adaptation documented in the migration guide.
final class PublicAPICompatibilityTests: XCTestCase {
    func testPreviousInitializerCallShapesRemainAvailable() async throws {
        let loader = AgentDefinitionSourceLoader(urlSession: makeTestURLSession())
        let maximumDefinitionBytes = await loader.maximumDefinitionBytes
        XCTAssertEqual(maximumDefinitionBytes, 1_024 * 1_024)
        let error = AgentRuntimeError(code: "compatibility", message: "Example")
        XCTAssertNil(error.http)
        XCTAssertNil(error.retry)
        let stream = AgentTurnStream(events: AsyncThrowingStream { $0.finish() },
            steer: nil, interrupt: {}, submitToolResult: { _, _ in })
        try await stream.waitUntilReady()

        let configuration = AgentRuntime.Configuration(authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(service: "CodexKitTests.Compatibility", account: UUID().uuidString),
            backend: DesignBackend(), approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore(),
            logging: .disabled, memory: nil, baseInstructions: nil, maximumParallelToolCalls: 4,
            tools: [], skills: [], definitionSourceLoader: loader, contextCompaction: .init(),
            threadActivationPolicy: .init(), backgroundActivityProvider: NoOpAgentBackgroundActivityProvider())
        XCTAssertNotNil(configuration.authProvider)
        XCTAssertNotNil(configuration.secureStore)
        XCTAssertEqual(configuration.maximumBufferedEvents, 64)
        let stringModel = CodexResponsesBackendConfiguration(model: "custom-model", requestRetryPolicy: .disabled, logging: .disabled)
        let typedModel = CodexResponsesBackendConfiguration(model: CodexModel.gpt56Sol, requestRetryPolicy: .disabled, logging: .disabled)
        XCTAssertEqual(stringModel.maximumResponseBytes, 256 * 1_024 * 1_024)
        XCTAssertEqual(typedModel.maximumModelPasses, 32)
        let query = HistoryItemsQuery(threadID: "thread", turnID: "turn", includeRedacted: true, includeCompactionEvents: true)
        XCTAssertEqual(query.threadID, "thread")
        XCTAssertEqual(query.turnID, "turn")
    }

    func testDocumentedFunctionReferenceAndConfigurationInspectionAdaptations() {
        let makeError: (String, String) -> AgentRuntimeError = { AgentRuntimeError(code: $0, message: $1) }
        XCTAssertEqual(makeError("code", "message").code, "code")
        let configuration = AgentRuntime.Configuration(sessionProvider: DesignReadOnlyProvider(), backend: DesignBackend(),
            approvalPresenter: AutoApprovalPresenter(), stateStore: InMemoryRuntimeStateStore())
        XCTAssertNil(configuration.authProvider)
        XCTAssertNil(configuration.secureStore)
        XCTAssertNotNil(configuration.sessionProvider)
    }
}
