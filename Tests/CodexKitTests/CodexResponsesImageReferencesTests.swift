@testable import CodexKit
import XCTest

extension CodexResponsesBackendTests {
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
