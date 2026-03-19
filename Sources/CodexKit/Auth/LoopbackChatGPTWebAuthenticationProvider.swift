import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(Network)
import Network
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

#if canImport(AuthenticationServices) && canImport(Network)
@available(iOS 13.0, macOS 10.15, *)
final class LoopbackChatGPTWebAuthenticationProvider: NSObject, ChatGPTWebAuthenticationProviding, @unchecked Sendable {
    private let callbackServerFactory: @Sendable (URL) throws -> LoopbackCallbackServing
    private let presentationAnchorProvider: @MainActor @Sendable () -> ASPresentationAnchor?

    private var activeSession: ASWebAuthenticationSession?
    private var activePresentationContextProvider: LoopbackPresentationContextProvider?
    @MainActor
    private var activeAuthenticationContinuation: CheckedContinuation<URL, Error>?

    override convenience init() {
        self.init(
            callbackServerFactory: { redirectURL in
                try LoopbackCallbackServer(redirectURL: redirectURL)
            },
            presentationAnchorProvider: {
                loopbackDefaultPresentationAnchor()
            }
        )
    }

    init(
        callbackServerFactory: @escaping @Sendable (URL) throws -> LoopbackCallbackServing,
        presentationAnchorProvider: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) {
        self.callbackServerFactory = callbackServerFactory
        self.presentationAnchorProvider = presentationAnchorProvider
        super.init()
    }

    func authenticate(
        authorizeURL: URL,
        callbackScheme _: String
    ) async throws -> URL {
        let redirectURL = try Self.loopbackRedirectURL(from: authorizeURL)
        let callbackServer = try callbackServerFactory(redirectURL)
        try await callbackServer.start()

        let anchor = try await MainActor.run { () throws -> ASPresentationAnchor in
            guard let anchor = presentationAnchorProvider() else {
                throw AgentRuntimeError(
                    code: "oauth_presentation_anchor_unavailable",
                    message: "The ChatGPT sign-in sheet could not be presented because no active window was available."
                )
            }
            return anchor
        }

        defer {
            callbackServer.stop()
        }

        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await callbackServer.waitForCallback()
            }

            group.addTask {
                try await self.runAuthenticationSession(
                    authorizeURL: authorizeURL,
                    anchor: anchor
                )
            }

            do {
                guard let firstResult = try await group.next() else {
                    throw AgentRuntimeError(
                        code: "oauth_callback_missing_code",
                        message: "The ChatGPT sign-in callback did not complete."
                    )
                }

                await MainActor.run {
                    self.cancelActiveSession()
                }
                callbackServer.stop()
                group.cancelAll()
                return firstResult
            } catch {
                await MainActor.run {
                    self.cancelActiveSession()
                }
                callbackServer.stop()
                group.cancelAll()
                throw error
            }
        }
    }

    private func runAuthenticationSession(
        authorizeURL: URL,
        anchor: ASPresentationAnchor
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor [weak self] in
                self?.activeAuthenticationContinuation = continuation
                let session = ASWebAuthenticationSession(
                    url: authorizeURL,
                    callbackURLScheme: nil
                ) { callbackURL, error in
                    self?.finishAuthenticationSession(
                        with: callbackURL.map(Result.success)
                            ?? .failure(
                                error ?? AgentRuntimeError(
                                    code: "oauth_authentication_cancelled",
                                    message: "The ChatGPT sign-in flow did not complete."
                                )
                            )
                    )
                }

                let contextProvider = LoopbackPresentationContextProvider(anchor: anchor)
                session.presentationContextProvider = contextProvider
                #if os(iOS)
                session.prefersEphemeralWebBrowserSession = false
                #endif
                self?.activeSession = session
                self?.activePresentationContextProvider = contextProvider

                guard session.start() else {
                    self?.finishAuthenticationSession(
                        with: .failure(
                            AgentRuntimeError(
                            code: "oauth_authentication_start_failed",
                            message: "The ChatGPT sign-in flow could not be started."
                        )
                    )
                    )
                    return
                }
            }
        }
    }

    @MainActor
    private func cancelActiveSession() {
        activeSession?.cancel()
        finishAuthenticationSession(
            with: .failure(
                AgentRuntimeError(
                    code: "oauth_authentication_cancelled",
                    message: "The ChatGPT sign-in flow did not complete."
                )
            )
        )
    }

    @MainActor
    private func finishAuthenticationSession(with result: Result<URL, Error>) {
        activeSession = nil
        activePresentationContextProvider = nil

        guard let continuation = activeAuthenticationContinuation else {
            return
        }

        activeAuthenticationContinuation = nil
        continuation.resume(with: result)
    }

    static func loopbackRedirectURL(from authorizeURL: URL) throws -> URL {
        guard let components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false),
              let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let redirectURL = URL(string: redirectURI),
              let scheme = redirectURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = redirectURL.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1",
              redirectURL.port != nil else {
            throw AgentRuntimeError(
                code: "oauth_loopback_redirect_invalid",
                message: "Loopback browser auth requires an http://localhost redirect URI with an explicit port."
            )
        }

        return redirectURL
    }
}

protocol LoopbackCallbackServing: Sendable {
    func start() async throws
    func waitForCallback() async throws -> URL
    func stop()
}

@available(iOS 13.0, macOS 10.15, *)
final class LoopbackCallbackServer: @unchecked Sendable, LoopbackCallbackServing {
    private let redirectURL: URL
    private let queue = DispatchQueue(label: "ai.assistantruntime.loopback-callback")
    private let state = LoopbackCallbackServerState()
    private let listener: NWListener

    init(redirectURL: URL) throws {
        guard let portValue = redirectURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw AgentRuntimeError(
                code: "oauth_loopback_redirect_invalid",
                message: "Loopback browser auth requires a localhost redirect URI with a valid port."
            )
        }

        self.redirectURL = redirectURL
        self.listener = try NWListener(using: .tcp, on: port)
        configureListener()
    }

    func start() async throws {
        listener.start(queue: queue)
        try await state.waitUntilReady()
    }

    func waitForCallback() async throws -> URL {
        try await state.waitForCallback()
    }

    func stop() {
        listener.cancel()
    }

    private func configureListener() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.stateUpdateHandler = { [weak self] newState in
            guard let self else {
                return
            }

            Task {
                switch newState {
                case .ready:
                    await self.state.markReady()
                case let .failed(error):
                    await self.state.fail(with: AgentRuntimeError(
                        code: "oauth_loopback_listener_failed",
                        message: "The localhost callback listener failed: \(error.localizedDescription)"
                    ))
                case .cancelled:
                    await self.state.fail(with: AgentRuntimeError(
                        code: "oauth_loopback_listener_cancelled",
                        message: "The localhost callback listener stopped before authentication completed."
                    ))
                default:
                    break
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                Task {
                    await self.state.fail(with: AgentRuntimeError(
                        code: "oauth_loopback_receive_failed",
                        message: "The localhost callback listener failed while reading the redirect: \(error.localizedDescription)"
                    ))
                }
                connection.cancel()
                return
            }

            let updatedBuffer = buffer + (data ?? Data())
            if let callbackURL = Self.callbackURL(fromHTTPRequest: updatedBuffer, redirectURL: self.redirectURL) {
                Self.sendHTMLResponse(
                    on: connection,
                    statusCode: 200,
                    body: """
                    <html>
                    <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 24px;">
                    <h1>Sign-in complete</h1>
                    <p>You can return to the app.</p>
                    </body>
                    </html>
                    """
                )
                Task {
                    await self.state.complete(with: callbackURL)
                }
                return
            }

            if Self.httpHeadersComplete(in: updatedBuffer) || isComplete {
                Self.sendHTMLResponse(
                    on: connection,
                    statusCode: 404,
                    body: """
                    <html>
                    <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 24px;">
                    <h1>Not found</h1>
                    <p>This localhost callback path is not handled by the demo app.</p>
                    </body>
                    </html>
                    """
                )
                return
            }

            self.receiveRequest(on: connection, buffer: updatedBuffer)
        }
    }

    static func callbackURL(fromHTTPRequest data: Data, redirectURL: URL) -> URL? {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.split(separator: "\r\n", omittingEmptySubsequences: false).first else {
            return nil
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              parts[0] == "GET" else {
            return nil
        }

        let target = String(parts[1])
        guard var components = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(targetParts[0])
        guard path == components.path else {
            return nil
        }

        components.percentEncodedQuery = targetParts.count > 1 ? String(targetParts[1]) : nil
        return components.url
    }

    static func httpHeadersComplete(in data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    static func sendHTMLResponse(
        on connection: NWConnection,
        statusCode: Int,
        body: String
    ) {
        let statusText = statusCode == 200 ? "OK" : "Not Found"
        let bodyData = Data(body.utf8)
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

@available(iOS 13.0, macOS 10.15, *)
private actor LoopbackCallbackServerState {
    private var ready = false
    private var callbackURL: URL?
    private var failure: Error?

    private var readinessContinuations: [CheckedContinuation<Void, Error>] = []
    private var callbackContinuations: [CheckedContinuation<URL, Error>] = []

    func waitUntilReady() async throws {
        if ready {
            return
        }

        if let failure {
            throw failure
        }

        try await withCheckedThrowingContinuation { continuation in
            readinessContinuations.append(continuation)
        }
    }

    func waitForCallback() async throws -> URL {
        if let callbackURL {
            return callbackURL
        }

        if let failure {
            throw failure
        }

        return try await withCheckedThrowingContinuation { continuation in
            callbackContinuations.append(continuation)
        }
    }

    func markReady() {
        guard !ready else {
            return
        }

        ready = true
        let continuations = readinessContinuations
        readinessContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func complete(with callbackURL: URL) {
        guard self.callbackURL == nil else {
            return
        }

        self.callbackURL = callbackURL
        let continuations = callbackContinuations
        callbackContinuations.removeAll()
        continuations.forEach { $0.resume(returning: callbackURL) }
    }

    func fail(with error: Error) {
        guard failure == nil else {
            return
        }

        failure = error
        let readiness = readinessContinuations
        let callbacks = callbackContinuations
        readinessContinuations.removeAll()
        callbackContinuations.removeAll()
        readiness.forEach { $0.resume(throwing: error) }
        callbacks.forEach { $0.resume(throwing: error) }
    }
}

@available(iOS 13.0, macOS 10.15, *)
private final class LoopbackPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

@MainActor
@available(iOS 13.0, macOS 10.15, *)
private func loopbackDefaultPresentationAnchor() -> ASPresentationAnchor? {
    #if canImport(UIKit)
    let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }

    if let keyWindow = scenes
        .flatMap(\.windows)
        .first(where: \.isKeyWindow) {
        return keyWindow
    }

    return scenes
        .flatMap(\.windows)
        .first(where: { !$0.isHidden })
    #elseif canImport(AppKit)
    return NSApp.keyWindow ?? NSApp.mainWindow
    #else
    return nil
    #endif
}
#endif
