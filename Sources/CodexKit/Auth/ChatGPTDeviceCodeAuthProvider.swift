import Foundation

public struct ChatGPTDeviceCodePrompt: Equatable, Identifiable, Sendable {
    public var id: String { userCode }
    public let verificationURL: URL
    public let userCode: String

    public init(verificationURL: URL, userCode: String) {
        self.verificationURL = verificationURL
        self.userCode = userCode
    }
}

public protocol ChatGPTDeviceCodePresenting: Sendable {
    func present(prompt: ChatGPTDeviceCodePrompt) async
    func clear() async
}

public final class ChatGPTDeviceCodeAuthProvider: ChatGPTAuthProviding, @unchecked Sendable {
    private let configuration: ChatGPTOAuthConfiguration
    private let urlSession: URLSession
    private let presenter: any ChatGPTDeviceCodePresenting

    public init(
        configuration: ChatGPTOAuthConfiguration,
        urlSession: URLSession = .shared,
        presenter: any ChatGPTDeviceCodePresenting
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.presenter = presenter
    }

    public func signInInteractively() async throws -> ChatGPTSession {
        let userCodeResponse = try await requestUserCode()
        let verificationURL = configuration.issuerURL
            .appendingPathComponent("codex")
            .appendingPathComponent("device")

        await presenter.present(
            prompt: ChatGPTDeviceCodePrompt(
                verificationURL: verificationURL,
                userCode: userCodeResponse.userCode
            )
        )
        do {
            let codeResponse = try await pollForAuthorizationCode(
                deviceAuthID: userCodeResponse.deviceAuthID,
                userCode: userCodeResponse.userCode,
                interval: max(userCodeResponse.interval, 1)
            )

            let tokenResponse = try await exchangeAuthorizationCode(
                codeResponse.authorizationCode,
                codeVerifier: codeResponse.codeVerifier,
                redirectURI: configuration.issuerURL
                    .appendingPathComponent("deviceauth")
                    .appendingPathComponent("callback")
                    .absoluteString
            )
            let session = try makeSession(from: tokenResponse)
            await presenter.clear()
            return session
        } catch {
            await presenter.clear()
            throw error
        }
    }

    public func refresh(
        session: ChatGPTSession,
        reason _: ChatGPTAuthRefreshReason
    ) async throws -> ChatGPTSession {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw AssistantRuntimeError(
                code: "missing_refresh_token",
                message: "This ChatGPT session cannot be refreshed because no refresh token is available."
            )
        }

        let tokenResponse = try await refreshAccessToken(refreshToken)
        return try makeSession(from: tokenResponse, fallbackRefreshToken: refreshToken)
    }

    public func signOut(session _: ChatGPTSession?) async {
        await presenter.clear()
    }

    private func requestUserCode() async throws -> DeviceUserCodeResponse {
        var request = URLRequest(
            url: configuration.issuerURL
                .appendingPathComponent("api")
                .appendingPathComponent("accounts")
                .appendingPathComponent("deviceauth")
                .appendingPathComponent("usercode")
        )
        request.httpMethod = "POST"
        applyDefaultAuthHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeviceUserCodeRequest(clientID: configuration.clientID))
        return try await sendRequest(request, decode: DeviceUserCodeResponse.self)
    }

    private func pollForAuthorizationCode(
        deviceAuthID: String,
        userCode: String,
        interval: UInt64
    ) async throws -> DeviceTokenResponse {
        let deadline = Date().addingTimeInterval(15 * 60)
        let pollURL = configuration.issuerURL
            .appendingPathComponent("api")
            .appendingPathComponent("accounts")
            .appendingPathComponent("deviceauth")
            .appendingPathComponent("token")

        while Date() < deadline {
            try Task.checkCancellation()

            var request = URLRequest(url: pollURL)
            request.httpMethod = "POST"
            applyDefaultAuthHeaders(to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                DeviceTokenPollRequest(deviceAuthID: deviceAuthID, userCode: userCode)
            )

            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AssistantRuntimeError(
                    code: "device_code_invalid_response",
                    message: "The ChatGPT device-code login returned an invalid response."
                )
            }

            if (200 ..< 300).contains(httpResponse.statusCode) {
                return try JSONDecoder().decode(DeviceTokenResponse.self, from: data)
            }

            if httpResponse.statusCode == 403 || httpResponse.statusCode == 404 {
                try await Task.sleep(for: .seconds(Double(interval)))
                continue
            }

            let body = simplifyAuthErrorBody(data)
            throw AssistantRuntimeError(
                code: "device_code_poll_failed",
                message: "ChatGPT device-code login failed with status \(httpResponse.statusCode): \(body)"
            )
        }

        throw AssistantRuntimeError(
            code: "device_code_timed_out",
            message: "ChatGPT device-code login timed out before authorization completed."
        )
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.issuerURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        applyDefaultAuthHeaders(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncodedFormBody(
            [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirectURI),
                ("client_id", configuration.clientID),
                ("code_verifier", codeVerifier),
            ]
        )
        return try await sendTokenRequest(request)
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> TokenResponse {
        var request = URLRequest(url: configuration.issuerURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        applyDefaultAuthHeaders(to: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = urlEncodedFormBody(
            [
                ("grant_type", "refresh_token"),
                ("client_id", configuration.clientID),
                ("refresh_token", refreshToken),
            ]
        )
        return try await sendTokenRequest(request)
    }

    private func sendTokenRequest(_ request: URLRequest) async throws -> TokenResponse {
        try await sendRequest(request, decode: TokenResponse.self)
    }

    private func sendRequest<T: Decodable>(
        _ request: URLRequest,
        decode type: T.Type
    ) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssistantRuntimeError(
                code: "oauth_token_response_invalid",
                message: "The ChatGPT token exchange returned an invalid response."
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = simplifyAuthErrorBody(data)
            throw AssistantRuntimeError(
                code: "oauth_token_exchange_failed",
                message: "ChatGPT request failed with status \(httpResponse.statusCode): \(body)"
            )
        }

        return try JSONDecoder().decode(type, from: data)
    }

    private func makeSession(
        from response: TokenResponse,
        fallbackRefreshToken: String? = nil
    ) throws -> ChatGPTSession {
        let idClaims = try JWTClaims.decode(from: response.idToken)
        let accessClaims = try JWTClaims.decode(from: response.accessToken)

        let accountID = idClaims.chatGPTAccountID
            ?? accessClaims.chatGPTAccountID
            ?? "unknown-account"
        let email = idClaims.email ?? accessClaims.email ?? "unknown@chatgpt.local"
        let plan = ChatGPTPlanType(
            rawValue: idClaims.planType ?? accessClaims.planType ?? "unknown"
        ) ?? .unknown

        return ChatGPTSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? fallbackRefreshToken,
            idToken: response.idToken,
            account: ChatGPTAccount(id: accountID, email: email, plan: plan),
            acquiredAt: accessClaims.issuedAt ?? Date(),
            expiresAt: accessClaims.expiresAt,
            isExternallyManaged: false
        )
    }

    private func applyDefaultAuthHeaders(to request: inout URLRequest) {
        request.setValue(configuration.originator, forHTTPHeaderField: "originator")
        request.setValue(
            buildCodexLikeUserAgent(
                originator: configuration.originator,
                product: configuration.userAgentProduct
            ),
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }
}

private struct DeviceUserCodeRequest: Encodable {
    let clientID: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

private struct DeviceTokenPollRequest: Encodable {
    let deviceAuthID: String
    let userCode: String

    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
    }
}

private struct DeviceUserCodeResponse: Decodable {
    let deviceAuthID: String
    let userCode: String
    let interval: UInt64

    enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthID = try container.decode(String.self, forKey: .deviceAuthID)
        userCode = try container.decode(String.self, forKey: .userCode)

        if let intervalString = try? container.decode(String.self, forKey: .interval),
           let parsed = UInt64(intervalString) {
            interval = parsed
        } else if let parsed = try? container.decode(UInt64.self, forKey: .interval) {
            interval = parsed
        } else {
            interval = 5
        }
    }
}

private struct DeviceTokenResponse: Decodable {
    let authorizationCode: String
    let codeChallenge: String
    let codeVerifier: String

    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeChallenge = "code_challenge"
        case codeVerifier = "code_verifier"
    }
}
