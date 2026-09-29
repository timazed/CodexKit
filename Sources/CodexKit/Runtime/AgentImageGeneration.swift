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

    var mimeType: AgentImageMIMEType {
        switch self {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .webp:
            .webp
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

    /// Configure image quality and format. The service chooses output dimensions.
    public init(
        action: AgentImageGenerationAction = .auto,
        outputFormat: AgentImageOutputFormat = .png,
        quality: AgentImageGenerationQuality? = nil
    ) {
        self.action = action
        self.outputFormat = outputFormat
        self.quality = quality
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
            options: resolved(options, action: .generate)
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
            options: resolved(options, action: .edit)
        )
    }

    private func run(
        prompt: String,
        images: [AgentImageAttachment],
        session: ChatGPTSession,
        options: AgentImageGenerationOptions
    ) async throws -> [AgentGeneratedImage] {
        try Task.checkCancellation()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentRuntimeError.invalidMessageContent()
        }

        let request = try buildURLRequest(
            prompt: prompt,
            images: images,
            session: session,
            options: options
        )
        // A single transport attempt: the host owns cancellation and its retry budget.
        let streamClient = CodexResponsesEventStreamClient(
            urlSession: urlSession, decoder: decoder, logger: AgentLogger(), maximumBufferedEvents: 1,
            responseBudget: CodexResponseBudget(maximumBytes: AgentImageGenerationResponse.maximumStreamBytes),
            httpErrorPrefix: "image_generation"
        )
        var observation = ResponsesAttemptObservation()
        var http: AgentHTTPFailure?
        do {
            let stream = try await streamClient.openEventStream(request: request)
            http = stream.http
            var result = AgentImageGenerationResponse(outputFormat: options.outputFormat)
            for try await event in stream.events {
                try Task.checkCancellation()
                observation.observe(event)
                if let images = try result.consume(event) {
                    try Task.checkCancellation()
                    return images
                }
            }
            try Task.checkCancellation()
            throw AgentRuntimeError(code: .responsesStreamDisconnected,
                message: "The image generation stream ended before terminal completion.")
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // Decoding contexts can contain provider data; expose only a fixed explanation.
            let underlying: Error = error is DecodingError
                ? AgentRuntimeError(code: .imageGenerationInvalidResponse,
                    message: "The image generation endpoint returned an invalid stream event.") : error
            let failure = observation.failure(underlying,
                clientRequestID: request.value(forHTTPHeaderField: "x-client-request-id"),
                requestID: (error as? AgentRuntimeError)?.http?.requestID ?? http?.requestID)
            throw AgentImageGenerationResponse.failure(failure, http: http)
        }
    }

    private func buildURLRequest(
        prompt: String,
        images: [AgentImageAttachment],
        session: ChatGPTSession,
        options: AgentImageGenerationOptions
    ) throws -> URLRequest {
        var content: [JSONValue] = [
            .object([
                "type": ResponsesContentType.inputText.jsonValue,
                "text": .string(prompt),
            ]),
        ]
        content.append(contentsOf: images.map(\.responsesInputImage))

        var tool: [String: JSONValue] = [
            "type": ResponsesToolType.imageGeneration.jsonValue,
            "action": .string(options.action.rawValue),
            "output_format": .string(options.outputFormat.rawValue),
        ]
        if let imageModel = configuration.imageModel {
            tool["model"] = .string(imageModel)
        }
        if let quality = options.quality {
            tool["quality"] = .string(quality.rawValue)
        }
        let factory = CodexResponsesRequestFactory(configuration: .init(
            baseURL: configuration.baseURL, model: configuration.model,
            originator: configuration.originator,
            streamIdleTimeout: urlSession.configuration.timeoutIntervalForRequest,
            extraHeaders: configuration.extraHeaders
        ), encoder: encoder)
        return try factory.buildURLRequest(
            model: configuration.model,
            instructions: "Use the image generation tool to fulfill the user's image request.",
            input: [.object([
                "type": ResponsesItemType.message.jsonValue,
                "role": .string("user"),
                "content": .array(content),
            ])],
            tools: [.object(tool)],
            toolChoice: .imageGeneration,
            requestID: UUID().uuidString,
            session: session
        )
    }

    private func resolved(_ options: AgentImageGenerationOptions, action: AgentImageGenerationAction) -> AgentImageGenerationOptions {
        var options = options
        if options.action == .auto { options.action = action }
        return options
    }

    private func validateEditableImages(_ images: [AgentImageAttachment]) throws {
        if let unsupported = images.first(where: { !Self.isSupportedEditableImageMimeType($0.mimeType) }) {
            throw AgentRuntimeError.unsupportedImageMimeType(unsupported.mimeType.rawValue)
        }
    }

    private static func isSupportedEditableImageMimeType(_ mimeType: AgentImageMIMEType) -> Bool {
        switch AgentImageMIMEType(rawValue: mimeType.rawValue.lowercased()) {
        case .png, .jpeg, .webp:
            true
        default:
            false
        }
    }
}
