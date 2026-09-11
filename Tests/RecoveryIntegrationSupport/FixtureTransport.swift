import CodexKit
import Foundation

public final class FixtureTransport: URLProtocol, @unchecked Sendable {
    public enum Reply: Sendable {
        case complete(String), disconnect, hold, http(Int, [String: String]), catalog(Data), invalid
    }
    public struct Capture: Sendable {
        public let purpose: String
        public let body: Data
        public let model: String
        public let effort: String
        public let requestID: String?
        public let authorization: String?
        public let method: String?
    }
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var plans: [String: [Reply]] = [:]
        var captures: [Capture] = []
        var held: [FixtureTransport] = []
        var log: URL?
    }
    private static let storage = Storage()
    public static func configure(_ plans: [String: [Reply]], log: URL? = nil) {
        storage.lock.withLock {
            storage.plans = plans; storage.captures = []; storage.held = []; storage.log = log
        }
    }
    public static var captures: [Capture] { storage.lock.withLock { storage.captures } }
    public static var generationCount: Int { captures.filter { $0.method == "POST" }.count }
    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureTransport.self]
        return URLSession(configuration: config)
    }
    public static func releaseHeld() {
        let held = storage.lock.withLock { let value = storage.held; storage.held = []; return value }
        for transport in held { transport.client?.urlProtocol(transport, didFailWithError: URLError(.networkConnectionLost)) }
    }
    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    public override func startLoading() {
        let data = Self.body(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let input = json["input"] as? [[String: Any]] ?? []
        let purpose = request.httpMethod == "GET" ? "catalog" : input.reversed().compactMap { item -> String? in
            let content = item["content"] as? [[String: Any]]
            return content?.first?["text"] as? String
        }.first ?? "unknown"
        let capture = Capture(purpose: purpose, body: data, model: json["model"] as? String ?? "",
            effort: (json["reasoning"] as? [String: Any])?["effort"] as? String ?? "",
            requestID: request.value(forHTTPHeaderField: "x-client-request-id"),
            authorization: request.value(forHTTPHeaderField: "Authorization"), method: request.httpMethod)
        let reply: Reply = Self.storage.lock.withLock {
            Self.storage.captures.append(capture)
            if let log = Self.storage.log, request.httpMethod == "POST" {
                var previous = (try? Data(contentsOf: log)) ?? Data()
                previous.append(Data((purpose + "\n").utf8))
                try? previous.write(to: log, options: .atomic)
            }
            if var replies = Self.storage.plans[purpose], !replies.isEmpty {
                let result = replies.removeFirst()
                Self.storage.plans[purpose] = replies
                return result
            }
            return .http(599, [:])
        }
        var headers = ["Content-Type": "text/event-stream"]
        var status = 200
        if case let .http(code, values) = reply { status = code; headers.merge(values) { _, new in new } }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch reply {
        case let .complete(value):
            emitCompletion(["value": value])
        case .invalid:
            emitCompletion(["unexpected": true])
        case .disconnect, .hold:
            emit(["type": "response.created", "sequence_number": 0, "response": ["id": "interrupted"]])
            emit(["type": "response.output_text.delta", "sequence_number": 1, "delta": "discard"])
            if case .hold = reply { Self.storage.lock.withLock { Self.storage.held.append(self) }; return }
        case .http:
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
        case let .catalog(data):
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    private func emitCompletion(_ payload: [String: Any]) {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        emit(["type": "response.created", "sequence_number": 0, "response": ["id": "saved-response"]])
        emit(["type": "response.output_item.done", "sequence_number": 1,
              "item": ["id": "message", "type": "message", "role": "assistant",
                       "content": [["type": "output_text", "text": text]]]])
        emit(["type": "response.completed", "sequence_number": 2, "response": ["id": "saved-response"]])
    }
    private func emit(_ value: [String: Any]) {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        client?.urlProtocol(self, didLoad: Data(("data: " + text + "\n\n").utf8))
    }
    public override func stopLoading() {
        Self.storage.lock.withLock { Self.storage.held.removeAll { $0 === self } }
    }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { return data }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}
