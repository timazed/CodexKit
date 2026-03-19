@testable import CodexKit
import Foundation
import XCTest
import Darwin

#if canImport(Network)
@available(iOS 13.0, macOS 10.15, *)
final class LoopbackChatGPTWebAuthenticationProviderTests: XCTestCase {
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
}
#endif
