import CodexKit
import Observation
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImageGenerationDemoModel {
    struct Request: Sendable {
        let prompt: String
        let images: [AgentImageAttachment]
        let options: AgentImageGenerationOptions
    }

    typealias Generate = @Sendable (Request, ChatGPTSession) async throws -> [AgentGeneratedImage]
    enum Status { case ready, running, completed, cancelled, failed }

    var prompt = "A watercolor illustration of a small orange fox with soft, detailed brushwork."
    var action: AgentImageGenerationAction = .generate
    var transparentBackground = false
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
         generate: @escaping Generate = ImageGenerationDemoModel.perform) {
        self.session = session
        self.generate = generate
    }

    var canRun: Bool {
        isActive && !isBusy && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (action != .edit || !references.isEmpty)
    }

    func start() {
        guard canRun else { return }
        let request = Request(prompt: prompt, images: action == .generate ? [] : references,
            options: .init(action: action, transparentBackground: transparentBackground))
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
                    throw AgentRuntimeError(code: .imageGenerationMissingOutput, message: "The response completed without an image.")
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

    func importReferences(_ urls: [URL]) {
        do {
            guard urls.count <= 5 else { throw ImageDemoError("Choose up to five reference images.") }
            references = try urls.map { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard count <= 10 * 1_024 * 1_024 else { throw ImageDemoError("Choose images smaller than 10 MB each.") }
                let data = try Data(contentsOf: url)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(source), CGImageSourceGetStatus(source) == .statusComplete,
                      let mime = UTType(type as String)?.preferredMIMEType,
                      ["image/png", "image/jpeg", "image/webp"].contains(mime) else {
                    throw ImageDemoError("Choose a readable PNG, JPEG, or WebP image.")
                }
                return AgentImageAttachment(mimeType: AgentImageMIMEType(rawValue: mime), data: data)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func reportImportError(_ error: Error) { self.error = error.localizedDescription }

    nonisolated static func perform(_ request: Request, session: ChatGPTSession) async throws -> [AgentGeneratedImage] {
        let client = AgentImageGenerationClient()
        if request.images.isEmpty {
            return try await client.generate(prompt: request.prompt, session: session, options: request.options)
        }
        return try await client.edit(images: request.images, prompt: request.prompt, session: session, options: request.options)
    }
}

private struct ImageDemoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
