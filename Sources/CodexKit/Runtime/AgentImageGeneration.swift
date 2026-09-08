import Foundation

public enum AgentImageGenerationAction: String, Codable, Hashable, Sendable {
    case auto
    case generate
    case edit
}

public enum AgentImageOutputFormat: String, Codable, Hashable, Sendable {
    case png
    case jpeg
    case webp

    var mimeType: String {
        switch self {
        case .png:
            "image/png"
        case .jpeg:
            "image/jpeg"
        case .webp:
            "image/webp"
        }
    }
}

public enum AgentImageGenerationQuality: String, Codable, Hashable, Sendable {
    case auto
    case low
    case medium
    case high
}

public struct AgentImageGenerationOptions: Codable, Hashable, Sendable {
    public var action: AgentImageGenerationAction
    public var outputFormat: AgentImageOutputFormat
    public var quality: AgentImageGenerationQuality?
    public var size: String?

    public init(
        action: AgentImageGenerationAction = .auto,
        outputFormat: AgentImageOutputFormat = .png,
        quality: AgentImageGenerationQuality? = nil,
        size: String? = nil
    ) {
        self.action = action
        self.outputFormat = outputFormat
        self.quality = quality
        self.size = size
    }

    public static var generate: AgentImageGenerationOptions {
        AgentImageGenerationOptions(action: .generate)
    }

    public static var edit: AgentImageGenerationOptions {
        AgentImageGenerationOptions(action: .edit)
    }
}

public struct AgentGeneratedImage: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let image: AgentImageAttachment
    public let revisedPrompt: String?
    public let createdAt: Date

    public init(
        id: String,
        image: AgentImageAttachment,
        revisedPrompt: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.image = image
        self.revisedPrompt = revisedPrompt
        self.createdAt = createdAt
    }
}

public struct AgentImageGenerationConfiguration: Sendable {
    public let baseURL: URL
    public let model: String
    public let imageModel: String?
    public let originator: String
    public let extraHeaders: [String: String]

    public init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api/codex")!,
        model: String = "gpt-5",
        imageModel: String? = "gpt-image-1.5",
        originator: String = "codex_cli_rs",
        extraHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.model = model
        self.imageModel = imageModel
        self.originator = originator
        self.extraHeaders = extraHeaders
    }
}

public actor AgentImageGenerationClient {
    private let configuration: AgentImageGenerationConfiguration
    private let urlSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: AgentImageGenerationConfiguration = AgentImageGenerationConfiguration(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func generate(
        prompt: String,
        session: ChatGPTSession,
        options: AgentImageGenerationOptions = .generate
    ) async throws -> [AgentGeneratedImage] {
        try await run(
            prompt: prompt,
            images: [],
            session: session,
            options: options.action == .auto ? .generate : options
        )
    }

    public func edit(
        images: [AgentImageAttachment],
        prompt: String,
        session: ChatGPTSession,
        options: AgentImageGenerationOptions = .edit
    ) async throws -> [AgentGeneratedImage] {
        guard !images.isEmpty else {
            throw AgentRuntimeError.invalidMessageContent()
        }
        try validateEditableImages(images)
        return try await run(
            prompt: prompt,
            images: images,
            session: session,
            options: options.action == .auto ? .edit : options
        )
    }

    private func run(
        prompt: String,
        images: [AgentImageAttachment],
        session: ChatGPTSession,
        options: AgentImageGenerationOptions
    ) async throws -> [AgentGeneratedImage] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentRuntimeError.invalidMessageContent()
        }

        let request = try buildURLRequest(
            prompt: prompt,
            images: images,
            session: session,
            options: options
        )
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeError(
                code: "image_generation_invalid_response",
                message: "The image generation endpoint returned an invalid response."
            )
        }
        let isSuccess = (200 ..< 300).contains(httpResponse.statusCode)
        let responseLimit = isSuccess
            ? ((AgentStoreLimits.maximumImageBytesPerWrite + 2) / 3) * 4 + AgentStoreLimits.maximumEmbeddedPayloadByteCount
            : AgentStoreLimits.maximumResponseErrorBodyByteCount
        var data = Data()
        for try await byte in bytes {
            guard data.count < responseLimit else {
                throw AgentRuntimeError(code: "image_generation_response_too_large",
                    message: "The image generation response exceeded its supported size limit.",
                    http: .init(response: httpResponse))
            }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard isSuccess else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AgentRuntimeError.httpFailure(response: httpResponse, body: data, prefix: "image_generation",
                message: "The image generation request failed with status \(httpResponse.statusCode): \(body)")
        }

        let responseBody = try decoder.decode(ImageGenerationResponseBody.self, from: data)
        let generated = responseBody.output.compactMap { item -> AgentGeneratedImage? in
            guard item.type == "image_generation_call",
                  let result = item.result,
                  let image = AgentImageAttachment(
                    base64String: result,
                    mimeType: options.outputFormat.mimeType,
                    id: item.id ?? UUID().uuidString
                  ) else {
                return nil
            }
            return AgentGeneratedImage(
                id: item.id ?? image.id,
                image: image,
                revisedPrompt: item.revisedPrompt
            )
        }

        guard !generated.isEmpty else {
            throw AgentRuntimeError(
                code: "image_generation_missing_output",
                message: "The image generation request completed without returning an image."
            )
        }
        return generated
    }

    private func buildURLRequest(
        prompt: String,
        images: [AgentImageAttachment],
        session: ChatGPTSession,
        options: AgentImageGenerationOptions
    ) throws -> URLRequest {
        var content: [JSONValue] = [
            .object([
                "type": .string("input_text"),
                "text": .string(prompt),
            ]),
        ]
        content.append(contentsOf: images.map { image in
            .object([
                "type": .string("input_image"),
                "image_url": .string(image.dataURLString),
            ])
        })

        var tool: [String: JSONValue] = [
            "type": .string("image_generation"),
            "action": .string(options.action.rawValue),
            "output_format": .string(options.outputFormat.rawValue),
        ]
        if let imageModel = configuration.imageModel {
            tool["model"] = .string(imageModel)
        }
        if let quality = options.quality {
            tool["quality"] = .string(quality.rawValue)
        }
        if let size = options.size {
            tool["size"] = .string(size)
        }

        let body = ImageGenerationRequestBody(
            model: configuration.model,
            input: [
                .object([
                    "role": .string("user"),
                    "content": .array(content),
                ]),
            ],
            tools: [.object(tool)],
            store: false
        )

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(session.account.id, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue(configuration.originator, forHTTPHeaderField: "originator")

        for (header, value) in configuration.extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        return request
    }

    private func validateEditableImages(_ images: [AgentImageAttachment]) throws {
        if let unsupported = images.first(where: { !Self.isSupportedEditableImageMimeType($0.mimeType) }) {
            throw AgentRuntimeError.unsupportedImageMimeType(unsupported.mimeType)
        }
    }

    private static func isSupportedEditableImageMimeType(_ mimeType: String) -> Bool {
        switch mimeType.lowercased() {
        case "image/png", "image/jpeg", "image/webp":
            true
        default:
            false
        }
    }
}

private struct ImageGenerationRequestBody: Encodable {
    let model: String
    let input: [JSONValue]
    let tools: [JSONValue]
    let store: Bool
}

private struct ImageGenerationResponseBody: Decodable {
    let output: [ImageGenerationOutputItem]
}

private struct ImageGenerationOutputItem: Decodable {
    let id: String?
    let type: String
    let result: String?
    let revisedPrompt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case result
        case revisedPrompt = "revised_prompt"
    }
}
