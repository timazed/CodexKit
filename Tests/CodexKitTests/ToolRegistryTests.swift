import CodexKit
import XCTest

final class ToolRegistryTests: XCTestCase {
    func testInvalidToolNameIsRejectedDuringRegistration() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: SilentApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        do {
            try await runtime.registerTool(
                ToolDefinition(
                    name: "demo.lookupProfile",
                    description: "Invalid live backend name",
                    inputSchema: .object([:])
                ),
                executor: AnyToolExecutor { invocation, _ in
                    .success(invocation: invocation, text: "ok")
                }
            )
            XCTFail("Expected invalid tool name error")
        } catch let error as ToolRegistryError {
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid tool name demo.lookupProfile. Tool names must match ^[a-zA-Z0-9_-]+$."
            )
        }
    }

    func testDuplicateInitialToolNamesAreRejectedInConfiguration() {
        XCTAssertThrowsError(
            try AgentRuntime(configuration: .init(
                authProvider: DemoChatGPTAuthProvider(),
                secureStore: KeychainSessionSecureStore(
                    service: "CodexKitTests.ChatGPTSession",
                    account: UUID().uuidString
                ),
                backend: InMemoryAgentBackend(),
                approvalPresenter: SilentApprovalPresenter(),
                stateStore: InMemoryRuntimeStateStore(),
                tools: [
                    .init(
                        definition: ToolDefinition(
                            name: "demo_echo",
                            description: "Echo tool",
                            inputSchema: .object([:])
                        ),
                        executor: AnyToolExecutor { invocation, _ in
                            .success(invocation: invocation, text: "ok")
                        }
                    ),
                    .init(
                        definition: ToolDefinition(
                            name: "demo_echo",
                            description: "Echo tool again",
                            inputSchema: .object([:])
                        ),
                        executor: AnyToolExecutor { invocation, _ in
                            .success(invocation: invocation, text: "ok")
                        }
                    ),
                ]
            ))
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "A tool named demo_echo is already registered."
            )
        }
    }
}

private struct SilentApprovalPresenter: ApprovalPresenting {
    func requestApproval(_: ApprovalRequest) async throws -> ApprovalDecision {
        .approved
    }
}
