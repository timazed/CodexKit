import AssistantRuntimeKit
import XCTest

@MainActor
private final class RecordingDeviceCodePresenter: ChatGPTDeviceCodePresenting, @unchecked Sendable {
    private(set) var prompts: [ChatGPTDeviceCodePrompt] = []
    private(set) var clearCount = 0

    func present(prompt: ChatGPTDeviceCodePrompt) async {
        prompts.append(prompt)
    }

    func clear() async {
        clearCount += 1
    }

    func snapshot() -> (prompt: ChatGPTDeviceCodePrompt?, clearCount: Int) {
        (prompts.first, clearCount)
    }
}

final class ChatGPTDeviceCodeAuthProviderTests: XCTestCase {
    override func tearDown() {
        let expectation = XCTestExpectation(description: "reset protocol stubs")
        Task {
            await TestURLProtocol.reset()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        super.tearDown()
    }

    func testDeviceCodeSignInRequestsPromptPollsAndExchangesTokens() async throws {
        let presenter = RecordingDeviceCodePresenter()
        let session = makeTestURLSession()
        let provider = ChatGPTDeviceCodeAuthProvider(
            configuration: ChatGPTOAuthConfiguration(
                redirectURI: URL(string: "assistantdemoapp://oauth/callback")!
            ),
            urlSession: session,
            presenter: presenter
        )

        let now = Date()
        let idToken = try makeUnsignedJWT(
            claims: [
                "email": "device@example.com",
                "chatgpt_account_id": "workspace-device",
                "chatgpt_plan_type": "plus",
                "iat": Int(now.timeIntervalSince1970),
                "exp": Int(now.addingTimeInterval(3600).timeIntervalSince1970),
            ]
        )
        let accessToken = try makeUnsignedJWT(
            claims: [
                "chatgpt_account_id": "workspace-device",
                "chatgpt_plan_type": "plus",
                "iat": Int(now.timeIntervalSince1970),
                "exp": Int(now.addingTimeInterval(1800).timeIntervalSince1970),
            ]
        )

        await TestURLProtocol.enqueue(
            .init(
                body: #"{"device_auth_id":"device-123","user_code":"ABCD-EFGH","interval":"1"}"#.data(using: .utf8)!,
                inspect: { request in
                    XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/api/accounts/deviceauth/usercode")
                }
            )
        )
        await TestURLProtocol.enqueue(
            .init(
                body: #"{"authorization_code":"auth-code-123","code_challenge":"challenge-1","code_verifier":"verifier-1"}"#.data(using: .utf8)!,
                inspect: { request in
                    XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/api/accounts/deviceauth/token")
                }
            )
        )
        await TestURLProtocol.enqueue(
            .init(
                body: try JSONEncoder().encode([
                    "id_token": idToken,
                    "access_token": accessToken,
                    "refresh_token": "refresh-device",
                ]),
                inspect: { request in
                    XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/token")
                    let body = try XCTUnwrap(requestBodyData(for: request))
                    let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
                    XCTAssertEqual(json?["grant_type"], "authorization_code")
                    XCTAssertEqual(json?["code"], "auth-code-123")
                    XCTAssertEqual(json?["redirect_uri"], "https://auth.openai.com/deviceauth/callback")
                    XCTAssertEqual(json?["code_verifier"], "verifier-1")
                }
            )
        )

        let signedIn = try await provider.signInInteractively()

        let snapshot = await presenter.snapshot()
        let prompt = snapshot.prompt
        let clearCount = snapshot.clearCount
        XCTAssertEqual(prompt?.userCode, "ABCD-EFGH")
        XCTAssertEqual(prompt?.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(signedIn.account.email, "device@example.com")
        XCTAssertEqual(signedIn.account.id, "workspace-device")
        XCTAssertEqual(signedIn.refreshToken, "refresh-device")
    }
}
