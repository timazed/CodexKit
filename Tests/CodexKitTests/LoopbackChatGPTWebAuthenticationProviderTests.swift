@testable import CodexKit
import Foundation
import XCTest
import Darwin
#if canImport(Network)
import Network
#endif

#if canImport(Network)
@available(iOS 13.0, macOS 10.15, *)
final class LoopbackChatGPTWebAuthenticationProviderTests: XCTestCase {
    private actor CallbackCapture {
        private var url: URL?

        func set(_ url: URL) {
            self.url = url
        }

        func get() -> URL? {
            url
        }
    }

    func testLoopbackServerRequires127001Binding() throws {
        let port = try Self.findAvailablePort()
        let redirectURL = URL(string: "http://localhost:\(port)/auth/callback")!
        let server = try LoopbackCallbackServer(redirectURL: redirectURL)

        guard case let .hostPort(host, endpointPort)? = server.requiredLocalEndpoint else {
            return XCTFail("Expected an explicit loopback local endpoint.")
        }

        XCTAssertEqual(String(describing: host), "127.0.0.1")
        XCTAssertEqual(String(describing: endpointPort), "\(port)")
    }

    func testLoopbackServerCapturesCallbackURL() async throws {
        let port = try Self.findAvailablePort()
        let redirectURL = URL(string: "http://localhost:\(port)/auth/callback")!
        let server = try LoopbackCallbackServer(redirectURL: redirectURL)

        try await server.start()

        async let callbackURL = server.waitForCallback()
        let requestURL = URL(string: "http://127.0.0.1:\(port)/auth/callback?code=test-code&state=test-state")!
        let (_, response) = try await URLSession.shared.data(from: requestURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            XCTFail("Expected HTTPURLResponse")
            return
        }

        XCTAssertEqual(httpResponse.statusCode, 200)
        let capturedURL = try await callbackURL
        XCTAssertEqual(capturedURL.scheme, "http")
        XCTAssertEqual(capturedURL.host, "localhost")
        XCTAssertEqual(capturedURL.port, port)

        let components = URLComponents(url: capturedURL, resolvingAgainstBaseURL: false)
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "code" })?.value,
            "test-code"
        )
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "state" })?.value,
            "test-state"
        )

        server.stop()
    }

    func testLoopbackServerWaitsForCompleteHTTPHeadersBeforeCompletingCallback() async throws {
        let port = try Self.findAvailablePort()
        let redirectURL = URL(string: "http://localhost:\(port)/auth/callback")!
        let server = try LoopbackCallbackServer(redirectURL: redirectURL)

        try await server.start()
        defer { server.stop() }

        let callbackReceived = expectation(description: "callback received")
        let capture = CallbackCapture()
        Task {
            let callbackURL = try await server.waitForCallback()
            await capture.set(callbackURL)
            callbackReceived.fulfill()
        }

        let socket = try Self.connect(to: port)
        defer { close(socket) }

        try Self.write("GET /auth/callback?code=test", to: socket)
        try await Task.sleep(for: .milliseconds(100))
        let earlyCapture = await capture.get()
        XCTAssertNil(earlyCapture)

        try Self.write("-code&state=test-state HTTP/1.1\r\n", to: socket)
        try Self.write("Host: 127.0.0.1:\(port)\r\n", to: socket)
        try Self.write("\r\n", to: socket)

        await fulfillment(of: [callbackReceived], timeout: 1.0)
        let capturedURL = await capture.get()
        XCTAssertEqual(capturedURL?.host, "localhost")
        XCTAssertEqual(
            URLComponents(url: capturedURL ?? redirectURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "code" })?
                .value,
            "test-code"
        )
    }

    func testLoopbackRedirectValidationRejectsNonLoopbackRedirects() throws {
        let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize?redirect_uri=https%3A%2F%2Fexample.com%2Fcallback")!

        XCTAssertThrowsError(
            try LoopbackChatGPTWebAuthenticationProvider.loopbackRedirectURL(from: authorizeURL)
        ) { error in
            let runtimeError = error as? AgentRuntimeError
            XCTAssertEqual(runtimeError?.code, "oauth_loopback_redirect_invalid")
        }
    }

    private static func findAvailablePort() throws -> Int {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw POSIXError(.EADDRINUSE)
        }
        defer {
            close(socket)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(socket, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            throw POSIXError(.EADDRINUSE)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(socket, socketAddress, &length)
            }
        }

        guard nameResult == 0 else {
            throw POSIXError(.EADDRINUSE)
        }

        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func connect(to port: Int) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw POSIXError(.ECONNREFUSED)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(socket, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            close(socket)
            throw POSIXError(.ECONNREFUSED)
        }

        return socket
    }

    private static func write(_ string: String, to socket: Int32) throws {
        let bytes = Array(string.utf8CString)
        let count = bytes.count - 1
        let result = bytes.withUnsafeBytes { buffer in
            Darwin.send(socket, buffer.baseAddress, count, 0)
        }
        guard result == count else {
            throw POSIXError(.EIO)
        }
    }
}
#endif
