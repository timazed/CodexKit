import AppKit
import CodexKit
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class MacDemoImageModel {
    struct Request: Sendable {
        let model: String
        let imageModel: String?
        let prompt: String
        let images: [AgentImageAttachment]
        let options: AgentImageGenerationOptions
    }

    typealias Generate = @Sendable (Request, ChatGPTSession) async throws -> [AgentGeneratedImage]
    enum Status { case ready, running, completed, cancelled, failed }

    var prompt = "A watercolor portrait of a friendly fictional president against a blue background."
    var action: AgentImageGenerationAction = .generate
    var quality: AgentImageGenerationQuality = .low
    var outputFormat: AgentImageOutputFormat = .jpeg
    var imageModel = ""
    var references: [AgentImageAttachment] = []
    private(set) var results: [AgentGeneratedImage] = []
    private(set) var status = Status.ready
    private(set) var error: String?
    private(set) var failure: AgentRuntimeError?
    private(set) var isBusy = false
    @ObservationIgnored private let session: @MainActor () async throws -> ChatGPTSession
    @ObservationIgnored private let generate: Generate
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isActive = true

    init(session: @escaping @MainActor () async throws -> ChatGPTSession,
         generate: @escaping Generate = MacDemoImageModel.perform) {
        self.session = session
        self.generate = generate
    }

    var canRun: Bool {
        isActive && !isBusy && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (action != .edit || !references.isEmpty)
    }

    func start(model: String) {
        guard canRun else { return }
        let selectedImageModel = imageModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = Request(model: model, imageModel: selectedImageModel.isEmpty ? nil : selectedImageModel,
            prompt: prompt, images: action == .generate ? [] : references,
            options: .init(action: action, outputFormat: outputFormat, quality: quality))
        isBusy = true
        status = .running
        error = nil
        failure = nil
        results = []
        task = Task {
            defer { isBusy = false }
            do {
                let current = try await session()
                try Task.checkCancellation()
                let images = try await generate(request, current)
                try Task.checkCancellation()
                let latest = try await session()
                try Task.checkCancellation()
                guard isActive, latest.binding == current.binding else { throw CancellationError() }
                guard !images.isEmpty else {
                    throw MacDemoFeatureError("The response completed without an image.")
                }
                results = images
                status = .completed
            } catch {
                guard isActive else { return }
                if Task.isCancelled || error is CancellationError {
                    status = .cancelled
                } else {
                    status = .failed
                    failure = error as? AgentRuntimeError
                    self.error = failure?.message ?? error.localizedDescription
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    func invalidate() {
        isActive = false
        task?.cancel()
        references = []
        results = []
        error = nil
        failure = nil
        status = .ready
    }

    func waitUntilFinished() async { await task?.value }

    func chooseReferences() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            guard panel.urls.count <= 4 else { throw MacDemoFeatureError("Choose up to four reference images.") }
            references = try panel.urls.map { url in
                let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard bytes <= 10 * 1_024 * 1_024 else { throw MacDemoFeatureError("Choose images smaller than 10 MB each.") }
                let data = try Data(contentsOf: url)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(source), CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                    throw MacDemoFeatureError("The selected file is not a readable image.")
                }
                let mime: AgentImageMIMEType
                switch type as String {
                case UTType.jpeg.identifier: mime = .jpeg
                case UTType.png.identifier: mime = .png
                case UTType.webP.identifier: mime = .webp
                default: throw MacDemoFeatureError("Choose a JPEG, PNG, or WebP image.")
                }
                return .init(mimeType: mime, data: data)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func save(_ generated: AgentGeneratedImage) {
        let panel = NSSavePanel()
        let type = UTType(mimeType: generated.image.mimeType.rawValue) ?? .image
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "generated-image.\(type.preferredFilenameExtension ?? "png")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try generated.image.data.write(to: url, options: .atomic) }
        catch { self.error = "Could not save the image: \(error.localizedDescription)" }
    }

    nonisolated static func perform(_ request: Request, session: ChatGPTSession) async throws -> [AgentGeneratedImage] {
        let client = AgentImageGenerationClient(configuration: .init(model: request.model, imageModel: request.imageModel))
        if request.images.isEmpty {
            return try await client.generate(prompt: request.prompt, session: session, options: request.options)
        }
        return try await client.edit(images: request.images, prompt: request.prompt, session: session, options: request.options)
    }
}
