import AssistantRuntimeKit
import Foundation

final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let inspect: @Sendable (URLRequest) throws -> Void

        init(
            statusCode: Int = 200,
            headers: [String: String] = [:],
            body: Data,
            inspect: @escaping @Sendable (URLRequest) throws -> Void = { _ in }
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.inspect = inspect
        }
    }

    private actor StubStore {
        private var queuedResponses: [StubResponse] = []

        func enqueue(_ response: StubResponse) {
            queuedResponses.append(response)
        }

        func reset() {
            queuedResponses.removeAll()
        }

        func dequeue() throws -> StubResponse {
            guard !queuedResponses.isEmpty else {
                throw AssistantRuntimeError(
                    code: "missing_test_stub",
                    message: "No queued URLProtocol stub was available."
                )
            }
            return queuedResponses.removeFirst()
        }
    }

    private static let store = StubStore()

    static func enqueue(_ response: StubResponse) async {
        await store.enqueue(response)
    }

    static func reset() async {
        await store.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            do {
                let stub = try await Self.store.dequeue()
                try stub.inspect(request)

                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: stub.statusCode,
                    httpVersion: nil,
                    headerFields: stub.headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: stub.body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

func makeTestURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestURLProtocol.self]
    return URLSession(configuration: configuration)
}

func makeUnsignedJWT(claims: [String: Any]) throws -> String {
    let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
    let payload = try JSONSerialization.data(withJSONObject: claims)
    return [
        header.base64URLEncodedString(),
        payload.base64URLEncodedString(),
        "",
    ].joined(separator: ".")
}

func requestBodyData(for request: URLRequest) throws -> Data? {
    if let httpBody = request.httpBody {
        return httpBody
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 1024
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? AssistantRuntimeError(
                code: "request_body_read_failed",
                message: "Failed to read the stubbed request body."
            )
        }
        if count == 0 {
            break
        }
        data.append(buffer, count: count)
    }

    return data
}

func parseFormURLEncodedBody(_ data: Data) -> [String: String] {
    guard let body = String(data: data, encoding: .utf8), !body.isEmpty else {
        return [:]
    }

    return body
        .split(separator: "&")
        .reduce(into: [String: String]()) { partial, pair in
            let components = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = components.first else {
                return
            }
            let value = components.count > 1 ? components[1] : ""
            partial[decodeFormComponent(key)] = decodeFormComponent(value)
        }
}

private func decodeFormComponent(_ value: String) -> String {
    value
        .replacingOccurrences(of: "+", with: " ")
        .removingPercentEncoding ?? value
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
