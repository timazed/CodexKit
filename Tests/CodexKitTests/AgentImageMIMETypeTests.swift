@testable import CodexKit
import CodexKitSQLite
import CodexKitRealm
import XCTest

final class AgentImageMIMETypeTests: XCTestCase {
    func testTypedAndLegacyConstructorsShareTheSameRepresentation() throws {
        let data = Data([1, 2, 3])
        let typed = AgentImageAttachment(id: "image", mimeType: .png, data: data, detail: .original)
        let legacy = AgentImageAttachment(id: "image", mimeType: "image/png", data: data, detail: .original)
        XCTAssertEqual(typed, legacy)
        XCTAssertEqual(typed.mimeType, .png)
        XCTAssertEqual(typed.dataURLString, "data:image/png;base64,AQID")
        XCTAssertEqual(AgentImageAttachment(base64String: "AQID", mimeType: .png)?.mimeType, .png)
        XCTAssertEqual(AgentImageAttachment(base64String: "AQID")?.mimeType, .png)
        XCTAssertEqual(AgentImageAttachment(dataURLString: typed.dataURLString)?.mimeType, .png)
        let oldConstructor: (String, String, Data, AgentImageGenerationMetadata?) -> AgentImageAttachment = AgentImageAttachment.init
        XCTAssertEqual(oldConstructor("image", "image/png", data, nil).mimeType, .png)
    }

    func testFileExtensionsResolveToTheSharedMIMEType() {
        XCTAssertEqual(AgentImageMIMEType(pathExtension: "JPG"), .jpeg)
        XCTAssertEqual(AgentImageMIMEType(pathExtension: "png"), .png)
        XCTAssertEqual(AgentImageMIMEType(pathExtension: "heif"), .heif)
        XCTAssertNil(AgentImageMIMEType(pathExtension: "txt"))
    }

    func testKnownAndFutureMIMETypesEncodeAsPlainStrings() throws {
        let types: [AgentImageMIMEType] = [.png, .jpeg, .gif, .webp, .heic, .heif, .init(rawValue: "image/avif")]
        for type in types {
            let encoded = try JSONEncoder().encode(type)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: encoded), type.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(AgentImageMIMEType.self, from: encoded), type)
            let attachment = AgentImageAttachment(mimeType: type, data: Data([1]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any])
            XCTAssertEqual(object["mimeType"] as? String, type.rawValue)
        }
        let legacy = Data(#"{"id":"old","mimeType":"image/png","data":"AQID"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentImageAttachment.self, from: legacy).mimeType, .png)
    }

    func testTypedAndCustomMIMETypesSurviveAllPersistenceAdapters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = [AgentImageAttachment(mimeType: .png, data: Data([1, 2, 3])),
            AgentImageAttachment(mimeType: AgentImageMIMEType(rawValue: "image/avif"), data: Data([4, 5, 6]))]
        for adapter in [TestStorageBackend.file, .sqlite, .realm] {
            let url = root.appendingPathComponent(adapter.rawValue)
            let open: () throws -> any RuntimeStateStoring = {
                return try adapter.open(at: url)
            }
            let store = try open()
            try await store.saveState(.init(threads: [.init(id: "thread")], messagesByThread: ["thread": [
                .init(threadID: "thread", role: .user, text: "Images", images: images)
            ]]))
            let state = try await open().loadState()
            XCTAssertEqual(state.messagesByThread["thread"]?.first?.images, images)
        }
    }
}
