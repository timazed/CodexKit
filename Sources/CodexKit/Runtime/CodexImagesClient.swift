import Foundation

/// The HTTP contract for the authenticated Codex Images endpoints.
/// One request, bounded ingestion, no SDK retry or elapsed-time generation deadline.
struct CodexImagesClient: Sendable {
    static let maximumImageBytes = 32 * 1_024 * 1_024
    let configuration: AgentImageGenerationConfiguration
    let urlSession: URLSession
    var maximumResponseBytes = ((maximumImageBytes + 2) / 3) * 4 + 1_024 * 1_024

    func run(prompt: String, images: [AgentImageAttachment], session: ChatGPTSession,
             options: AgentImageGenerationOptions) async throws -> [AgentGeneratedImage] {
        try Task.checkCancellation()
        let request = try makeRequest(prompt: prompt, images: images, session: session, options: options)
        let clientID = request.value(forHTTPHeaderField: "x-client-request-id")!
        var http: HTTPURLResponse?
        var body = Data()
        do {
            try await AgentStructuredRecoveryContext.current?.beforeTransmission()
            try Task.checkCancellation()
            let (bytes, response) = try await urlSession.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw invalidResponse() }
            http = response
            let success = (200..<300).contains(response.statusCode)
            let limit = success ? maximumResponseBytes : AgentStoreLimits.maximumResponseErrorBodyByteCount
            guard response.expectedContentLength <= limit else { throw tooLarge() }
            body = try await withTaskCancellationHandler {
                var data = Data()
                for try await byte in bytes {
                    guard data.count < limit else { throw tooLarge() }
                    if data.count % 65_536 == 0 { try Task.checkCancellation() }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return data
            } onCancel: { bytes.task.cancel() }
            // A JSON result is only complete after the HTTP body finishes successfully.
            try Task.checkCancellation()
            if !success {
                throw CodexImageResponse.providerFailure(body: body, response: response)
            }
            if let type = response.mimeType, type.lowercased() != "application/json" { throw invalidResponse() }
            let output = try CodexImageResponse.decode(body, response: response, clientID: clientID,
                action: images.isEmpty ? .generate : .edit)
            try Task.checkCancellation()
            return output
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // Do not expose decoding contexts or URLSession descriptions containing request data.
            let failure = (error as? AgentRuntimeError) ?? invalidResponse()
            throw AgentRuntimeError(code: failure.code, message: failure.message,
                http: http.map { AgentHTTPFailure(response: $0, body: body) },
                imageGeneration: CodexImageResponse.diagnostics(response: http, clientID: clientID, body: body))
        }
    }

    private func makeRequest(prompt: String, images: [AgentImageAttachment], session: ChatGPTSession,
                             options: AgentImageGenerationOptions) throws -> URLRequest {
        let action: AgentImageGenerationAction = images.isEmpty ? .generate : .edit
        guard options.outputFormat == .png, options.quality == nil || options.quality == .auto,
              options.action == .auto || options.action == action else {
            throw AgentRuntimeError(code: .imageGenerationUnsupportedOptions,
                message: "Codex Images uses automatic quality and PNG output. The action must match generate or edit. "
                    + "Explicit Responses configurations retain legacy model, quality, and format options.")
        }
        guard images.count <= 5, images.reduce(0, { $0 + $1.data.count }) <= Self.maximumImageBytes else {
            throw AgentRuntimeError(code: .imageGenerationUnsupportedOptions,
                message: "Use at most five reference images totaling no more than 32 MiB.")
        }
        let body = Request(prompt: prompt, background: options.transparentBackground ? "transparent" : "opaque",
            images: images.isEmpty ? nil : images.map { .init(image_url: $0.dataURLString) })
        let clientID = UUID().uuidString
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(
            images.isEmpty ? "images/generations" : "images/edits"))
        request.httpMethod = "POST"
        request.timeoutInterval = urlSession.configuration.timeoutIntervalForRequest
        request.httpBody = try JSONEncoder().encode(body)
        for (key, value) in configuration.extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.originator, forHTTPHeaderField: "originator")
        request.setValue(clientID, forHTTPHeaderField: "x-client-request-id")
        request.setValue(clientID, forHTTPHeaderField: "x-codex-image-turn-id")
        CodexRequestAuthentication.apply(to: &request, session: session)
        return request
    }

    private struct Request: Encodable {
        struct Reference: Encodable { let image_url: String }
        let prompt: String
        let background: String
        let model = "gpt-image-2"
        let quality = "auto"
        let size = "auto"
        let images: [Reference]?
    }

    private func invalidResponse() -> AgentRuntimeError {
        .init(code: .imageGenerationInvalidResponse,
            message: "The Codex image request did not return a complete, valid image response.")
    }

    private func tooLarge() -> AgentRuntimeError {
        .init(code: .imageGenerationResponseTooLarge,
            message: "The image response exceeded its supported size limit.")
    }
}
