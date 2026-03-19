import CodexKit
import XCTest

final class ToolRegistryTests: XCTestCase {
    func testRegisteredToolExecutesThroughRegistry() async throws {
        let registry = ToolRegistry()
        let definition = ToolDefinition(
            name: "demo_echo",
            description: "Echo tool",
            inputSchema: .object([:])
        )

        try await registry.register(definition, executor: AnyToolExecutor { invocation, _ in
            .success(invocation: invocation, text: "ok")
        })

        let result = await registry.execute(
            ToolInvocation(
                id: "call-1",
                threadID: "thread-1",
                turnID: "turn-1",
                toolName: "demo_echo",
                arguments: .object([:])
            ),
            session: nil
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.primaryText, "ok")
    }

    func testInvalidToolNameIsRejectedBeforeRegistration() async {
        let registry = ToolRegistry()

        do {
            try await registry.register(
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
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
