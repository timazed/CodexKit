import Foundation

public enum CodexRemoteExecutionError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidPreparedRequest
    case invalidAuthentication
    case invalidResponse
    case responseTooLarge
    case http(AgentHTTPFailure)
}

/// Submits prepared requests to an mp-api-compatible middleware and reads job metadata.
/// HTTP retries reuse the entire envelope. They never allocate a new provider request ID.
public final class CodexRemoteExecutionClient: Sendable {
    private let baseURL: URL
    private let headers: [String: String]
    private let retryPolicy: RequestRetryPolicy
    private let urlSession: URLSession
    private let maximumResponseBytes = 1_024 * 1_024

    /// Headers belong to middleware authentication/device identity, not provider authentication.
    /// Configuration can inject URLProtocol implementations for offline testing.
    public init(baseURL: URL, headers: [String: String] = [:], retryPolicy: RequestRetryPolicy = .default,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) throws {
        guard let host = baseURL.host, !host.isEmpty,
              baseURL.scheme == "https" || (baseURL.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw CodexRemoteExecutionError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.headers = headers
        self.retryPolicy = retryPolicy
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        urlSession = URLSession(configuration: configuration, delegate: CodexRemoteHTTPDelegate(), delegateQueue: nil)
    }

    deinit { urlSession.invalidateAndCancel() }

    /// Returns acceptance metadata, not the completed provider output.
    /// Omitted completionPush is resolved to silent when remoteExecution is created.
    public func execute(remoteExecution: CodexRemoteExecution,
                        authentication: CodexRemoteAuthentication) async throws -> CodexRemoteJob {
        guard !authentication.accessToken.isEmpty, !authentication.accountID.isEmpty else {
            throw CodexRemoteExecutionError.invalidAuthentication
        }
        // Build once: every retry has the same identity, preference, bytes, and digest.
        let body = try remoteExecution.submission(authentication: authentication)
        return try await perform(path: remoteExecution.path, method: "POST", body: body)
    }

    public func job(id: String) async throws -> CodexRemoteJob {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw CodexRemoteExecutionError.invalidResponse
        }
        let job = try await perform(path: "codex/\(id)", method: "GET", body: nil)
        guard job.jobID == id else { throw CodexRemoteExecutionError.invalidResponse }
        return job
    }

    private func perform(path: String, method: String, body: Data?) async throws -> CodexRemoteJob {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for attempt in 1...max(1, retryPolicy.maxAttempts) {
            try Task.checkCancellation()
            do {
                let data = try await send(request)
                let job: CodexRemoteJob
                do { job = try JSONDecoder().decode(Envelope.self, from: data).data }
                catch { throw CodexRemoteExecutionError.invalidResponse }
                guard !job.jobID.isEmpty, !job.status.isEmpty else { throw CodexRemoteExecutionError.invalidResponse }
                return job
            } catch {
                try Task.checkCancellation()
                guard attempt < retryPolicy.maxAttempts, isRetryable(error) else { throw error }
                let serverDelay: TimeInterval
                if case let CodexRemoteExecutionError.http(failure) = error { serverDelay = failure.retryAfter ?? 0 }
                else { serverDelay = 0 }
                try await Task.sleep(for: .seconds(max(serverDelay, retryPolicy.delayBeforeRetry(attempt: attempt))))
            }
        }
        throw CodexRemoteExecutionError.invalidResponse
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await urlSession.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw CodexRemoteExecutionError.invalidResponse }
        guard response.expectedContentLength <= maximumResponseBytes else { throw CodexRemoteExecutionError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw CodexRemoteExecutionError.responseTooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw CodexRemoteExecutionError.http(.init(response: response, body: data))
        }
        return data
    }

    private func isRetryable(_ error: any Error) -> Bool {
        if case let CodexRemoteExecutionError.http(failure) = error {
            // A changed preference for an existing clientRequestId is a conflict, never a transient failure.
            return failure.statusCode != 409 && retryPolicy.retryableHTTPStatusCodes.contains(failure.statusCode)
        }
        return (error as? URLError).map { retryPolicy.retryableURLErrorCodes.contains($0.code.rawValue) } ?? false
    }

    private struct Envelope: Decodable { let data: CodexRemoteJob }
}

/// Refuse redirects so neither middleware identity nor provider credentials move to another destination.
private final class CodexRemoteHTTPDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
