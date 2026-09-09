import CodexKit
import XCTest

private struct StubDeviceCodePresenter: ChatGPTDeviceCodePresenting {
    func present(prompt _: ChatGPTDeviceCodePrompt) async {}
    func clear() async {}
}

final class ChatGPTAuthProviderTests: XCTestCase {
    override func tearDown() async throws {
        await TestURLProtocol.reset()
        try await super.tearDown()
    }

    func testRefreshReadsOptionalIDTokenNameForBothAuthenticationMethods() async throws {
        let cases: [(claims: [String: Any], name: String?, displayName: String)] = [
            ([:], nil, "user@example.com"),
            (["name": NSNull()], nil, "user@example.com"),
            (["name": ""], "", "user@example.com"),
            (["name": " \n "], " \n ", "user@example.com"),
            (["name": "Zoë 李"], "Zoë 李", "Zoë 李"),
        ]
        for method in [ChatGPTAuthenticationMethod.oauth, .deviceCode] {
            let provider = try ChatGPTAuthProvider(
                method: method,
                urlSession: makeTestURLSession(),
                deviceCodePresenter: StubDeviceCodePresenter()
            )
            for testCase in cases {
                var idClaims: [String: Any] = [
                    "email": "user@example.com",
                    "chatgpt_account_id": "workspace",
                    "chatgpt_plan_type": "plus",
                ]
                idClaims.merge(testCase.claims) { _, new in new }
                await TestURLProtocol.enqueue(.init(body: try JSONEncoder().encode([
                    "id_token": makeUnsignedJWT(claims: idClaims),
                    "access_token": makeUnsignedJWT(claims: ["name": "Access Token Name"]),
                ])))

                let refreshed = try await provider.refresh(
                    session: ChatGPTSession(
                        accessToken: "old-access",
                        refreshToken: "test-refresh",
                        account: ChatGPTAccount(id: "workspace", email: "user@example.com", plan: .plus, name: "Old Name")
                    ),
                    reason: .unauthorized
                )

                XCTAssertEqual(refreshed.account.name, testCase.name, "Auth method: \(method)")
                XCTAssertEqual(refreshed.account.displayName, testCase.displayName, "Auth method: \(method)")
                XCTAssertEqual(refreshed.refreshToken, "test-refresh")
            }
        }
    }

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

    func testOAuthCanBeConstructed() throws {
        XCTAssertNoThrow(
            try ChatGPTAuthProvider(
                method: .oauth
            )
        )
    }
}
