@testable import CodexKit
import XCTest

final class ChatGPTSessionMetadataTests: XCTestCase {
    func testMalformedOptionalFieldsDoNotDiscardValidNeighbors() throws {
        let token = try makeUnsignedJWT(claims: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "workspace",
                "chatgpt_plan_type": "plus",
                "chatgpt_user_id": 42,
                "user_id": "legacy-user",
            ],
            "https://api.openai.com/profile": ["email": "fixture@example.test", "name": 42],
            "iat": true,
            "exp": 4_000_000_000,
        ])
        let metadata = try ChatGPTSessionMetadata(token: token)
        XCTAssertEqual(metadata.chatGPTAccountID, "workspace")
        XCTAssertEqual(metadata.planType, "plus")
        XCTAssertEqual(metadata.userID, "legacy-user")
        XCTAssertEqual(metadata.email, "fixture@example.test")
        XCTAssertNil(metadata.name)
        XCTAssertNil(metadata.issuedAt)
        XCTAssertEqual(metadata.expiresAt, Date(timeIntervalSince1970: 4_000_000_000))
    }

    func testAbsentNamespaceFieldsAllowLegacyFallbackButMalformedFieldsDoNot() throws {
        for namespace: Any in [NSNull(), "invalid", ["chatgpt_plan_type": NSNull()]] {
            let token = try makeUnsignedJWT(claims: [
                "https://api.openai.com/auth": namespace,
                "chatgpt_plan_type": "free",
            ])
            let metadata = try ChatGPTSessionMetadata(token: token)
            XCTAssertTrue(metadata.hasPlan)
            XCTAssertNil(metadata.planType)
        }
        let emptyNamespace = try makeUnsignedJWT(claims: [
            "https://api.openai.com/auth": [String: String](),
            "chatgpt_plan_type": "free",
        ])
        XCTAssertEqual(try ChatGPTSessionMetadata(token: emptyNamespace).planType, "free")
        let absent = try makeUnsignedJWT(claims: [:])
        XCTAssertFalse(try ChatGPTSessionMetadata(token: absent).hasPlan)
    }

    func testMalformedProfileCannotExposeLegacyValues() throws {
        for profile: Any in [NSNull(), "invalid", ["email": 42, "name": false]] {
            let token = try makeUnsignedJWT(claims: [
                "https://api.openai.com/profile": profile,
                "email": "legacy@example.test", "name": "Legacy Name",
            ])
            let metadata = try ChatGPTSessionMetadata(token: token)
            XCTAssertNil(metadata.email)
            XCTAssertNil(metadata.name)
        }
    }

    func testInvalidTokenStructureReturnsOnlyTheDomainError() throws {
        for token in ["invalid", ".payload.", "header.%%%.", "header.W10."] {
            XCTAssertThrowsError(try ChatGPTSessionMetadata(token: token)) { error in
                XCTAssertEqual(error as? ChatGPTSessionError, .malformedCredentials)
            }
        }
    }
}
