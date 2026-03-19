import CodexKit
import XCTest

private struct AutoApprovalPresenter: ApprovalPresenting {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        XCTAssertEqual(request.toolInvocation.toolName, "demo_lookup_profile")
        return .approved
    }
}

final class AgentRuntimeTests: XCTestCase {
    func testRuntimeStreamsToolApprovalAndCompletion() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        try await runtime.replaceTool(
            ToolDefinition(
                name: "demo_lookup_profile",
                description: "Lookup profile",
                inputSchema: .object([:]),
                approvalPolicy: .requiresApproval
            ),
            executor: AnyToolExecutor { invocation, _ in
                .success(invocation: invocation, text: "demo-result")
            }
        )

        let thread = try await runtime.createThread()
        let stream = try await runtime.sendMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )

        var sawApproval = false
        var sawToolResult = false
        var sawTurnCompleted = false

        for try await event in stream {
            switch event {
            case .approvalRequested:
                sawApproval = true
            case let .toolCallFinished(result):
                sawToolResult = true
                XCTAssertEqual(result.primaryText, "demo-result")
            case .turnCompleted:
                sawTurnCompleted = true
            default:
                break
            }
        }

        XCTAssertTrue(sawApproval)
        XCTAssertTrue(sawToolResult)
        XCTAssertTrue(sawTurnCompleted)

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(messages.filter { $0.role == .assistant }.count, 1)
    }

    func testConfigurationRegistersInitialTools() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            tools: [
                .init(
                    definition: ToolDefinition(
                        name: "demo_lookup_profile",
                        description: "Lookup profile",
                        inputSchema: .object([:]),
                        approvalPolicy: .requiresApproval
                    ),
                    executor: AnyToolExecutor { invocation, _ in
                        .success(invocation: invocation, text: "demo-result")
                    }
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let stream = try await runtime.sendMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )

        var sawToolResult = false

        for try await event in stream {
            if case let .toolCallFinished(result) = event {
                sawToolResult = true
                XCTAssertEqual(result.primaryText, "demo-result")
            }
        }

        XCTAssertTrue(sawToolResult)
    }
}
