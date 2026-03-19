import Foundation

public enum ChatGPTAuthenticationMethod: Sendable {
    case deviceCode
    case oauth(redirectURI: URL)
}

public final class ChatGPTAuthProvider: ChatGPTAuthProviding, @unchecked Sendable {
    public struct Configuration: Sendable {
        public let issuerURL: URL
        public let clientID: String
        public let scopes: [String]
        public let originator: String
        public let forcedWorkspaceID: String?
        public let userAgentProduct: String

        public init(
            issuerURL: URL = URL(string: "https://auth.openai.com")!,
            clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann",
            scopes: [String] = [
                "openid",
                "profile",
                "email",
                "offline_access",
                "api.connectors.read",
                "api.connectors.invoke",
            ],
            originator: String = "codex_cli_rs",
            forcedWorkspaceID: String? = nil,
            userAgentProduct: String = "CodexKit"
        ) {
            self.issuerURL = issuerURL
            self.clientID = clientID
            self.scopes = scopes
            self.originator = originator
            self.forcedWorkspaceID = forcedWorkspaceID
            self.userAgentProduct = userAgentProduct
        }

        fileprivate func oauthConfiguration(redirectURI: URL) -> ChatGPTOAuthConfiguration {
            ChatGPTOAuthConfiguration(
                issuerURL: issuerURL,
                clientID: clientID,
                redirectURI: redirectURI,
                scopes: scopes,
                originator: originator,
                forcedWorkspaceID: forcedWorkspaceID,
                userAgentProduct: userAgentProduct
            )
        }

        fileprivate var deviceCodeConfiguration: ChatGPTOAuthConfiguration {
            // Device-code auth does not use an app callback, but the lower-level
            // shared configuration still expects a redirect URI.
            oauthConfiguration(redirectURI: URL(string: "codexkit://device-code")!)
        }
    }

    private let implementation: any ChatGPTAuthProviding

    public init(
        method: ChatGPTAuthenticationMethod,
        configuration: Configuration = Configuration(),
        urlSession: URLSession = .shared,
        deviceCodePresenter: (any ChatGPTDeviceCodePresenting)? = nil
    ) throws {
        switch method {
        case .deviceCode:
            guard let deviceCodePresenter else {
                throw AgentRuntimeError(
                    code: "device_code_presenter_missing",
                    message: "ChatGPT device-code auth requires a presenter."
                )
            }
            implementation = ChatGPTDeviceCodeAuthProvider(
                configuration: configuration.deviceCodeConfiguration,
                urlSession: urlSession,
                presenter: deviceCodePresenter
            )

        case let .oauth(redirectURI):
            implementation = ChatGPTOAuthProvider(
                configuration: configuration.oauthConfiguration(redirectURI: redirectURI),
                urlSession: urlSession
            )
        }
    }

    public func signInInteractively() async throws -> ChatGPTSession {
        try await implementation.signInInteractively()
    }

    public func refresh(
        session: ChatGPTSession,
        reason: ChatGPTAuthRefreshReason
    ) async throws -> ChatGPTSession {
        try await implementation.refresh(session: session, reason: reason)
    }

    public func signOut(session: ChatGPTSession?) async {
        await implementation.signOut(session: session)
    }
}
