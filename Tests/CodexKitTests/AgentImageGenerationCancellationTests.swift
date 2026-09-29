import CodexKit
import XCTest

final class AgentImageGenerationCancellationTests: XCTestCase {
    func testAlreadyCancelledRequestDoesNotTransmit() async throws {
        let events = ImageStreamEvents()
        PausedImageProtocol.events = events
        defer { PausedImageProtocol.events = nil }
        let urlSession = makeSession()
        defer { urlSession.invalidateAndCancel() }
        let client = AgentImageGenerationClient(urlSession: urlSession)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.generate(prompt: "Draw", session: demoSession())
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events.requestCount, 0)
    }

    func testCancellationBeforeHeadersAndWhileReadingStreamOrHTTPErrorStopsRequest() async throws {
        for mode in [ImageStreamEvents.Mode.beforeHeaders, .provisionalImage, .httpError] {
            let events = ImageStreamEvents(mode: mode)
            PausedImageProtocol.events = events
            let urlSession = makeSession()
            let client = AgentImageGenerationClient(urlSession: urlSession)
            let task = Task { try await client.generate(prompt: "Draw", session: demoSession()) }
            await fulfillment(of: [events.started], timeout: 5)
            task.cancel()
            await fulfillment(of: [events.stopped], timeout: 5)
            do { _ = try await task.value; XCTFail("Cancellation must not return a provisional image") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(events.requestCount, 1)
            urlSession.invalidateAndCancel()
            PausedImageProtocol.events = nil
        }
    }

    func testTerminalCompletionReturnsWithoutWaitingForSocketEOF() async throws {
        let events = ImageStreamEvents(mode: .completed)
        PausedImageProtocol.events = events
        defer { PausedImageProtocol.events = nil }
        let urlSession = makeSession()
        defer { urlSession.invalidateAndCancel() }
        let client = AgentImageGenerationClient(urlSession: urlSession)
        let finished = XCTestExpectation(description: "Image returned on terminal event")
        let task = Task {
            defer { finished.fulfill() }
            return try await client.generate(prompt: "Draw", session: demoSession())
        }
        await fulfillment(of: [finished], timeout: 5)
        // Also bounds failure cleanup if the implementation incorrectly waits for EOF.
        task.cancel()
        let images = try await task.value
        XCTAssertEqual(images.map(\.id), ["image"])
        XCTAssertEqual(images.first?.image.data, Data([1, 2, 3]))
        await fulfillment(of: [events.stopped], timeout: 5)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PausedImageProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ImageStreamEvents: @unchecked Sendable {
    enum Mode { case beforeHeaders, provisionalImage, httpError, completed }
    let mode: Mode
    let started = XCTestExpectation(description: "Request started")
    let stopped = XCTestExpectation(description: "Network task stopped")
    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.withLock { count } }
    func recordRequest() { lock.withLock { count += 1 } }
    init(mode: Mode = .beforeHeaders) { self.mode = mode }
}

private final class PausedImageProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedEvents: ImageStreamEvents?
    static var events: ImageStreamEvents? {
        get { lock.withLock { storedEvents } }
        set { lock.withLock { storedEvents = newValue } }
    }
    private var currentEvents: ImageStreamEvents?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let events = Self.events else { return }
        currentEvents = events
        events.recordRequest()
        if events.mode != .beforeHeaders {
            let response = HTTPURLResponse(url: request.url!, statusCode: events.mode == .httpError ? 400 : 200,
                httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body: Data
            switch events.mode {
            case .completed:
                // Split CRLF events across arbitrary byte boundaries through the real transport.
                body = Data(String(decoding: imageSSE(imageDone(imageItem()), imageCompleted([imageItem()])), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: "\r\n").utf8)
            case .httpError: body = Data(#"{"error":{"message":"unfinished"#.utf8)
            default: body = imageSSE(imageDone(imageItem()))
            }
            for offset in stride(from: 0, to: body.count, by: 7) {
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<min(offset + 7, body.count)))
            }
        }
        events.started.fulfill()
        // Deliberately leave the response open: completion/cancellation must release it.
    }
    override func stopLoading() { currentEvents?.stopped.fulfill() }
}
