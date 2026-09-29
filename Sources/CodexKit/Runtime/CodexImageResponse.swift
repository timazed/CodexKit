import Foundation

enum CodexImageResponse {
    private struct Response: Decodable {
        struct Image: Decodable {
            let b64_json: String
            let generation_id: String?
        }
        let created: Double?
        let data: [Image]?
        let error: JSONValue?
        let status: String?
        let background: String?
        let quality: String?
        let size: String?
    }

    static func decode(_ body: Data, response: HTTPURLResponse, clientID: String,
                       action: AgentImageGenerationAction) throws -> [AgentGeneratedImage] {
        let value = try JSONDecoder().decode(Response.self, from: body)
        if let error = value.error, error != .null { throw providerFailure(body: body, response: response) }
        guard let created = value.created, created.isFinite, created >= 0,
              value.status == nil || value.status == "completed" else {
            throw AgentRuntimeError(code: .imageGenerationInvalidResponse,
                message: "The image request did not complete successfully.")
        }
        guard let images = value.data, !images.isEmpty else { throw missingImage() }
        guard images.count <= AgentStoreLimits.maximumImageCountPerMessage else { throw tooLarge() }
        var totalBytes = 0
        return try images.map { item in
            try Task.checkCancellation()
            guard item.b64_json.utf8.count <= ((CodexImagesClient.maximumImageBytes + 2) / 3) * 4 else {
                throw tooLarge()
            }
            guard let data = Data(base64Encoded: item.b64_json), !data.isEmpty else { throw missingImage() }
            totalBytes += data.count
            guard totalBytes <= CodexImagesClient.maximumImageBytes else { throw tooLarge() }
            guard RuntimeDownloadedImage.mimeType(for: data) == .png else {
                throw AgentRuntimeError(code: .imageGenerationInvalidResponse,
                    message: "The image service did not return a complete PNG image.")
            }
            let id = UUID().uuidString
            let metadata = AgentImageGenerationMetadata(id: id, status: "completed", action: action.rawValue,
                background: value.background.flatMap { ["transparent", "opaque", "auto"].contains($0) ? $0 : nil },
                outputFormat: "png", quality: value.quality.flatMap { AgentImageGenerationQuality(rawValue: $0)?.rawValue },
                size: value.size.map { String($0.prefix(64)) })
            return AgentGeneratedImage(id: id, image: .init(id: id, mimeType: .png, data: data, generationMetadata: metadata),
                createdAt: Date(timeIntervalSince1970: created),
                diagnostics: diagnostics(response: response, clientID: clientID, generationID: item.generation_id))
        }
    }

    static func providerFailure(body: Data, response: HTTPURLResponse) -> AgentRuntimeError {
        if usageLimit(response: response, body: body) != nil {
            return .init(code: .imageGenerationUsageLimitExceeded,
                message: "The image generation allowance has been reached. Try again after it resets.")
        }
        // Return only the provider's explanation; never store or log the raw JSON.
        let message = (try? JSONDecoder().decode(CodexHTTPProviderError.self, from: body))?.message
            .map { String($0.prefix(4_096)) }
            ?? "The Codex image request failed (HTTP \(response.statusCode))."
        if (200..<300).contains(response.statusCode) {
            return .init(code: .imageGenerationInvalidResponse, message: message)
        }
        return .httpFailure(response: response, body: body, prefix: "image_generation", message: message)
    }

    static func diagnostics(response: HTTPURLResponse?, clientID: String, body: Data = Data(),
                            generationID: String? = nil) -> AgentImageGenerationDiagnostics {
        .init(clientRequestID: clientID,
            requestID: response.map { AgentHTTPFailure(response: $0).requestID } ?? nil,
            imageRequestID: identifier(response?.value(forHTTPHeaderField: "x-codex-imagegen-request-id")),
            generationID: identifier(generationID),
            usageLimit: response.flatMap { usageLimit(response: $0, body: body) })
    }

    private static func usageLimit(response: HTTPURLResponse, body: Data) -> AgentImageGenerationUsageLimit? {
        let error = errorObject(body)
        guard response.statusCode == 429, error?["type"] as? String == "usage_limit_reached" else { return nil }
        let imageLimits = CodexRateLimitParser.headers(response).first { $0.limitID == "image_gen" }
        guard response.value(forHTTPHeaderField: "x-codex-active-limit") == "image_gen" || imageLimits != nil else {
            return nil
        }
        let reset = (error?["resets_at"] as? Double).flatMap { seconds -> Date? in
            seconds.isFinite && seconds >= 0 ? Date(timeIntervalSince1970: seconds) : nil
        } ?? [imageLimits?.primary, imageLimits?.secondary].compactMap { window -> Date? in
            guard let window, window.usedPercent >= 100 else { return nil }
            return window.resetsAt
        }.max()
        return .init(resetsAt: reset)
    }

    private static func identifier(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(value.prefix(1_024))
    }

    private static func errorObject(_ body: Data) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any]
    }

    private static func missingImage() -> AgentRuntimeError {
        .init(code: .imageGenerationMissingOutput, message: "The completed request contained no usable image data.")
    }

    private static func tooLarge() -> AgentRuntimeError {
        .init(code: .imageGenerationResponseTooLarge, message: "The decoded images exceeded the supported size limit.")
    }
}
