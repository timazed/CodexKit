#if DEBUG
import CodexKit
import CryptoKit
import Foundation

enum LocalCloudDemoMode: String, Codable, CaseIterable, Identifiable {
    case fixture, live
    var id: String { rawValue }
}

enum LocalCloudDemoError: LocalizedError {
    case address, packet, response, mode, authentication, api(Int, String), tooLarge
    var errorDescription: String? {
        switch self {
        case .address: "Use http://127.0.0.1:<port> for the local test API."
        case .packet: "CodexKit did not produce a supported request packet."
        case .response: "The local API returned an invalid response."
        case .mode: "The API mode does not match the selected test mode. Restart the API with the matching option."
        case .authentication: "Sign in again before running a live test."
        case let .api(status, code): "Local API returned HTTP \(status): \(code)."
        case .tooLarge: "The local test exceeded its payload limit."
        }
    }

    static func address(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let port = url.port, (1...65535).contains(port) else {
            throw Self.address
        }
        return url
    }
}

/// Demo-only adapter: captures the SDK's final URLRequest without rebuilding its provider JSON.
/// The production SDK request-export and remote-execution APIs remain separate work.
final class LocalCloudDemoTransport: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var operationTask: Task<Void, Never>?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.path == "/responses"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let operation = Task { @Sendable [self] in
            do {
                guard let url = request.url else { throw LocalCloudDemoError.address }
                let packet = try Self.packet(from: request)
                var api = URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("v1/execute"))
                api.httpMethod = "POST"
                api.setValue("application/json", forHTTPHeaderField: "Content-Type")
                api.httpBody = try JSONEncoder().encode(packet)
                let data = try await LocalCloudHTTP.data(for: api)
                let reply = try JSONDecoder().decode(Reply.self, from: data)
                guard reply.version == 1, reply.result.status == "completed" else { throw LocalCloudDemoError.response }
                // Replay validated completed items so the existing SDK result decoder handles the response.
                // Item events also cover providers that omit output from their terminal event.
                var stream = Data()
                for item in reply.result.output {
                    let event = ItemEvent(type: .outputItemDone, item: item)
                    Self.appendEvent(String(decoding: try JSONEncoder().encode(event), as: UTF8.self), to: &stream)
                }
                Self.appendEvent(reply.result.completedEvent, to: &stream)
                try Task.checkCancellation()
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]) else { throw LocalCloudDemoError.response }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: stream)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
        lock.withLock {
            if stopped { operation.cancel() } else { operationTask = operation }
        }
    }

    override func stopLoading() {
        lock.withLock { stopped = true; operationTask?.cancel(); operationTask = nil }
    }

    private static func packet(from request: URLRequest) throws -> Packet {
        guard request.httpMethod == "POST",
              let authorization = request.value(forHTTPHeaderField: "Authorization"), authorization.hasPrefix("Bearer "),
              let account = request.value(forHTTPHeaderField: "ChatGPT-Account-ID"),
              let session = request.value(forHTTPHeaderField: "session_id"),
              let requestID = request.value(forHTTPHeaderField: "x-client-request-id"),
              let originator = request.value(forHTTPHeaderField: "originator") else { throw LocalCloudDemoError.packet }
        let body = try body(of: request)
        guard !body.isEmpty, body.count <= 4 * 1024 * 1024 else { throw LocalCloudDemoError.tooLarge }
        return Packet(preparedRequest: .init(bodyBase64: body.base64EncodedString(),
            sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
            sessionId: session, clientRequestId: requestID, originator: originator),
            authentication: .init(accessToken: String(authorization.dropFirst(7)), accountId: account))
    }

    private static func body(of request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw LocalCloudDemoError.packet }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Every iteration returns, throws, or advances toward the byte limit.
        while data.count <= 4 * 1024 * 1024 {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw LocalCloudDemoError.packet }
            if count == 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
            if data.count > 4 * 1024 * 1024 { throw LocalCloudDemoError.tooLarge }
        }
        throw LocalCloudDemoError.tooLarge
    }

    private static func appendEvent(_ text: String, to data: inout Data) {
        data.append(Data((text.components(separatedBy: "\n").map { "data: " + $0 }.joined(separator: "\n") + "\n\n").utf8))
    }

    private struct Packet: Encodable {
        let version = 1
        let preparedRequest: Prepared
        let authentication: Authentication
        struct Prepared: Encodable {
            let bodyBase64, sha256, sessionId, clientRequestId, originator: String
        }
        struct Authentication: Encodable { let accessToken, accountId: String }
    }
    private struct Reply: Decodable {
        let version: Int
        let result: Result
        struct Result: Decodable { let status, completedEvent: String; let output: [JSONValue] }
    }
    private struct ItemEvent: Encodable {
        enum Kind: String, Encodable { case outputItemDone = "response.output_item.done" }
        let type: Kind
        let item: JSONValue
    }
}

/// Separate session prevents recursively intercepting the packet request. Redirects are refused.
final class LocalCloudHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func data(for request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 100
        let session = URLSession(configuration: configuration, delegate: LocalCloudHTTP(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalCloudDemoError.response }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw LocalCloudDemoError.tooLarge }
            data.append(byte)
        }
        guard http.statusCode == 200 else {
            let error = try? JSONDecoder().decode(Failure.self, from: data)
            throw LocalCloudDemoError.api(http.statusCode, error?.error.code ?? "request_failed")
        }
        return data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private struct Failure: Decodable {
        let error: Detail
        struct Detail: Decodable { let code: String }
    }
}
#endif
