@testable import CodexKit
import XCTest

extension CodexResponsesBackendTests {
    func testImageReferenceValidationChecksNestedArraysAndBothEncodings() throws {
        let image = AgentImageAttachment.png(Data("retained image".utf8))
        let other = AgentImageAttachment.png(Data("another image".utf8))
        let stored = try CodexResponsesImageReferences.externalize([
            .object(["image_url": .string(image.dataURLString)]),
            .object(["b64_json": .string(other.data.base64EncodedString())]),
        ])
        let first = try XCTUnwrap(stored[0].objectValue?["image_url"])
        let second = try XCTUnwrap(stored[1].objectValue?["b64_json"])
        let nested: [JSONValue] = [.object(["nested": .array([first, .array([second, first])])])]
        XCTAssertNoThrow(try CodexResponsesImageReferences.validate(nested, using: [image, image, other]))
        for retained in [[], [image], [other]] {
            XCTAssertThrowsError(try CodexResponsesImageReferences.validate(nested, using: retained)) { error in
                XCTAssertEqual((error as? AgentRuntimeError)?.code, "responses_missing_persisted_image")
            }
        }
    }

    func testImageReferenceValidationAllowsOrdinaryValuesAndRejectsEmptyReferences() throws {
        let plain: [JSONValue] = [.null, .bool(true), .number(2), .string("ordinary text"),
            .object(["image_url": .string("https://example.com/image.png")])]
        XCTAssertNoThrow(try CodexResponsesImageReferences.validate(plain, using: []))
        for reference in ["codexkit-image-ref:data-url:", "codexkit-image-ref:base64:"] {
            XCTAssertThrowsError(try CodexResponsesImageReferences.validate([.string(reference)], using: [])) { error in
                XCTAssertEqual((error as? AgentRuntimeError)?.code, "responses_missing_persisted_image")
            }
        }
    }

    func testResponsesImageReferencesExternalizeAndRestoreEveryImageBody() throws {
        let requestImage = AgentImageAttachment.png(
            Data("REQUEST_IMAGE_BYTES".utf8),
            id: "request-image"
        )
        let generatedImage = AgentImageAttachment.png(
            Data("GENERATED_IMAGE_BYTES".utf8),
            id: "generated-image"
        )
        let original: [JSONValue] = [
            WorkingHistoryItem.userMessage(AgentMessage(
                threadID: "image-reference-thread",
                role: .user,
                text: "Inspect this image",
                images: [requestImage]
            )).jsonValue,
            .object([
                "type": .string("image_generation_call"),
                "result": .string(generatedImage.data.base64EncodedString()),
            ]),
        ]

        let externalized = try CodexResponsesImageReferences.externalize(original)
        let persistedText = String(
            decoding: try JSONEncoder().encode(externalized),
            as: UTF8.self
        )
        XCTAssertFalse(persistedText.contains("data:image"))
        XCTAssertFalse(persistedText.contains(requestImage.data.base64EncodedString()))
        XCTAssertFalse(persistedText.contains(generatedImage.data.base64EncodedString()))

        let restored = try CodexResponsesImageReferences.restore(
            externalized,
            using: [requestImage, generatedImage]
        )
        XCTAssertEqual(restored, original)
    }
}
