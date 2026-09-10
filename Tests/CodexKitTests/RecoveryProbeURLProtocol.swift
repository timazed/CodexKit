import Foundation

/// Delivery is gated by the consumer, so an injected error cannot erase the
/// initial bytes before URLSession.AsyncBytes has handed them to the SDK.
final class RecoveryProbeURLProtocol: URLProtocol {
    private final class Reference: @unchecked Sendable {
        let value: RecoveryProbeURLProtocol
        init(_ value: RecoveryProbeURLProtocol) { self.value = value }
    }
    struct Reply: Sendable {
        let body: String
        var holdOpen = false
    }

    private final class Storage: @unchecked Sendable {
        let queue = DispatchQueue(label: "CodexKitTests.recovery-transport")
        var replies: [Reply] = []
        var requests: [URLRequest] = []
        var held: RecoveryProbeURLProtocol?
    }
    private static let storage = Storage()

    static func configure(_ replies: [Reply]) {
        storage.queue.sync {
            storage.replies = replies
            storage.requests = []
            storage.held = nil
        }
    }

    static var requests: [URLRequest] { storage.queue.sync { storage.requests } }

    static func endHeldConnection(_ code: URLError.Code? = nil) {
        storage.queue.sync {
            guard let held = storage.held else { return }
            storage.held = nil
            if let code { held.client?.urlProtocol(held, didFailWithError: URLError(code)) }
            else { held.client?.urlProtocolDidFinishLoading(held) }
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reference = Reference(self)
        Self.storage.queue.async {
            let instance = reference.value
            var captured = instance.request
            captured.httpBody = try? requestBodyData(for: instance.request)
            Self.storage.requests.append(captured)
            guard !Self.storage.replies.isEmpty else {
                instance.client?.urlProtocol(instance, didFailWithError: URLError(.badServerResponse))
                return
            }
            let reply = Self.storage.replies.removeFirst()
            if reply.holdOpen { Self.storage.held = instance }
            let response = HTTPURLResponse(url: instance.request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
            instance.client?.urlProtocol(instance, didLoad: Data(reply.body.utf8))
            if !reply.holdOpen { instance.client?.urlProtocolDidFinishLoading(instance) }
        }
    }

    override func stopLoading() {
        let reference = Reference(self)
        Self.storage.queue.async {
            if Self.storage.held === reference.value { Self.storage.held = nil }
        }
    }
}
