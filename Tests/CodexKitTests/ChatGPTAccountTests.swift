import CodexKit
import XCTest

final class ChatGPTAccountTests: XCTestCase {
    func testOriginalInitializerRemainsUsableAsAFunction() {
        let makeAccount: (String, String, ChatGPTPlanType) -> ChatGPTAccount = ChatGPTAccount.init(id:email:plan:)
        let account = makeAccount("workspace", "user@example.com", .plus)
        XCTAssertNil(account.name)
        XCTAssertEqual(account.displayName, "user@example.com")
    }

    func testDisplayNameUsesNameAndFallsBackToEmailWhenMissingOrBlank() {
        let cases: [(String?, String)] = [
            (nil, "user@example.com"),
            ("", "user@example.com"),
            (" \n\t ", "user@example.com"),
            ("  Zoë 李\n", "Zoë 李"),
        ]
        for (name, expected) in cases {
            let account = ChatGPTAccount(id: "workspace", email: "user@example.com", plan: .plus, name: name)
            XCTAssertEqual(account.displayName, expected)
            XCTAssertEqual(account.name, name)
        }
    }

    func testLegacySessionWithoutNameStillDecodes() throws {
        let data = Data(#"""
        {
            "accessToken": "test-access",
            "refreshToken": "test-refresh",
            "account": {"id": "workspace", "email": "user@example.com", "plan": "plus"},
            "acquiredAt": 0,
            "isExternallyManaged": false
        }
        """#.utf8)

        let session = try JSONDecoder().decode(ChatGPTSession.self, from: data)
        XCTAssertNil(session.account.name)
        XCTAssertEqual(session.account.displayName, "user@example.com")
        XCTAssertEqual(session.account.id, "workspace")
        XCTAssertEqual(session.account.plan, .plus)
        XCTAssertEqual(session.refreshToken, "test-refresh")
    }

    func testSessionRoundTripPreservesOptionalAccountName() throws {
        for name in [nil, "Zoë 李"] as [String?] {
            let session = ChatGPTSession(
                accessToken: "test-access",
                account: ChatGPTAccount(id: "workspace", email: "user@example.com", plan: .plus, name: name)
            )

            let data = try JSONEncoder().encode(session)
            let restored = try JSONDecoder().decode(ChatGPTSession.self, from: data)
            XCTAssertEqual(restored, session)
            XCTAssertEqual(restored.account.name, name)
        }
    }
}
