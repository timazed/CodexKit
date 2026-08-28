import CodexKit
import Foundation
import XCTest

final class TestURLProtocol: URLProtocol {
    struct StubResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let error: Error?
        let completionError: Error?
        let inspect: @Sendable (URLRequest) throws -> Void

        init(
            statusCode: Int = 200,
            headers: [String: String] = [:],
            body: Data,
            error: Error? = nil,
            completionError: Error? = nil,
            inspect: @escaping @Sendable (URLRequest) throws -> Void = { _ in }
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
            self.completionError = completionError
            self.inspect = inspect
        }
    }

    private final class StubStore: @unchecked Sendable {
        private let lock = NSLock()
        private var queuedResponses: [StubResponse] = []

        func enqueue(_ response: StubResponse) {
            lock.lock()
            defer { lock.unlock() }
            queuedResponses.append(response)
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            queuedResponses.removeAll()
        }

        func dequeue() throws -> StubResponse {
            lock.lock()
            defer { lock.unlock() }
            guard !queuedResponses.isEmpty else {
                throw AgentRuntimeError(
                    code: "missing_test_stub",
                    message: "No queued URLProtocol stub was available."
                )
            }
            return queuedResponses.removeFirst()
        }
    }

    private static let store = StubStore()

    static func enqueue(_ response: StubResponse) async {
        store.enqueue(response)
    }

    static func reset() async {
        store.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let stub = try Self.store.dequeue()
            try stub.inspect(request)

            if let error = stub.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            if let completionError = stub.completionError {
                client?.urlProtocol(self, didFailWithError: completionError)
                return
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
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
            throw stream.streamError ?? AgentRuntimeError(
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

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure @escaping () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw an error.", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

func regularFiles(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path),
          let enumerator = FileManager.default.enumerator(
              at: directory,
              includingPropertiesForKeys: [.isRegularFileKey],
              options: [.skipsHiddenFiles]
          )
    else {
        return []
    }
    return try enumerator.compactMap { element -> URL? in
        guard let url = element as? URL else { return nil }
        return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            ? url
            : nil
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
