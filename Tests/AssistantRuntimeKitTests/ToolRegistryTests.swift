import AssistantRuntimeKit
import XCTest

final class ToolRegistryTests: XCTestCase {
    func testRegisteredToolExecutesThroughRegistry() async throws {
        let registry = ToolRegistry()
        let definition = ToolDefinition(
            name: "demo.echo",
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
                toolName: "demo.echo",
                arguments: .object([:])
            ),
            session: nil
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.primaryText, "ok")
    }
}
