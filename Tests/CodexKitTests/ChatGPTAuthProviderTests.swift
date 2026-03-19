import CodexKit
import XCTest

private struct StubDeviceCodePresenter: ChatGPTDeviceCodePresenting {
    func present(prompt _: ChatGPTDeviceCodePrompt) async {}
    func clear() async {}
}

final class ChatGPTAuthProviderTests: XCTestCase {
    func testDeviceCodeAuthRequiresPresenter() {
        XCTAssertThrowsError(
            try ChatGPTAuthProvider(
                method: .deviceCode
            )
        ) { error in
            let runtimeError = error as? AgentRuntimeError
            XCTAssertEqual(runtimeError?.code, "device_code_presenter_missing")
        }
    }

    func testDeviceCodeAuthCanBeConstructedWithPresenter() throws {
        XCTAssertNoThrow(
            try ChatGPTAuthProvider(
                method: .deviceCode,
                deviceCodePresenter: StubDeviceCodePresenter()
            )
        )
    }

    func testOAuthCanBeConstructedWithLoopbackRedirect() throws {
        XCTAssertNoThrow(
            try ChatGPTAuthProvider(
                method: .oauth(
                    redirectURI: URL(string: "http://localhost:1455/auth/callback")!
                )
            )
        )
    }
}
