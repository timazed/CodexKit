import CodexKit
import CodexKitDemo
import CodexKitUI
import XCTest

@MainActor
final class AgentRuntimeStoreTests: XCTestCase {
    func testStoreRestoresSignsInAndStreamsMessages() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: ApprovalInbox(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        let store = AgentRuntimeStore(runtime: runtime)

        await store.restore()
        XCTAssertNil(store.session)

        await store.signIn()
        XCTAssertEqual(store.session?.account.email, "demo@example.com")

        await store.sendMessage("hello")

        XCTAssertEqual(store.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(store.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertTrue(store.streamingText.isEmpty)
        XCTAssertNil(store.lastError)
    }
}
