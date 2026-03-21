import CodexKit
import Foundation
import XCTest

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class AgentDefinitionSourceLoaderTests: XCTestCase {
    func testLoaderBuildsPersonaStackFromPlainTextFile() async throws {
        let text = "You are a direct planning assistant focused on tradeoffs."
        let fileURL = try temporaryFile(with: text)
        let loader = AgentDefinitionSourceLoader()

        let stack = try await loader.loadPersonaStack(
            from: .file(fileURL),
            defaultLayerName: "file_persona"
        )

        XCTAssertEqual(stack.layers.count, 1)
        XCTAssertEqual(stack.layers[0].name, "file_persona")
        XCTAssertEqual(stack.layers[0].instructions, text)
    }

    func testLoaderBuildsSkillFromJSONFile() async throws {
        let json = """
        {
          "id": "travel_planner",
          "name": "Travel Planner",
          "instructions": "Build practical itineraries with logistics.",
          "executionPolicy": {
            "maxToolCalls": 0
          }
        }
        """
        let fileURL = try temporaryFile(with: json)
        let loader = AgentDefinitionSourceLoader()

        let skill = try await loader.loadSkill(from: .file(fileURL))

        XCTAssertEqual(skill.id, "travel_planner")
        XCTAssertEqual(skill.name, "Travel Planner")
        XCTAssertTrue(skill.instructions.contains("itineraries"))
        XCTAssertEqual(skill.executionPolicy?.maxToolCalls, 0)
    }

    func testLoaderBuildsSkillFromRemoteSource() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let loader = AgentDefinitionSourceLoader(urlSession: session)
        let url = URL(string: "https://example.com/skills/health.json")!

        StubURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, url)
            let body = """
            {
              "id": "health_coach",
              "name": "Health Coach",
              "instructions": "Drive daily step execution."
            }
            """
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(body.utf8)
            )
        }
        defer {
            StubURLProtocol.requestHandler = nil
        }

        let skill = try await loader.loadSkill(from: .remote(url))

        XCTAssertEqual(skill.id, "health_coach")
        XCTAssertEqual(skill.name, "Health Coach")
    }

    private func temporaryFile(with content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }
}
