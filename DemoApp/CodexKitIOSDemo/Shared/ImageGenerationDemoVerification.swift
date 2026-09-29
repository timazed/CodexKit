#if DEBUG
import CodexKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum ImageGenerationDemoVerification {
    static func run() async throws -> [String] {
        let session = ChatGPTSession(accessToken: "synthetic-image-token",
            account: .init(id: "image-fixture", email: "demo@example.invalid", plan: .plus),
            expiresAt: Date().addingTimeInterval(3600))
        let jpeg = Data([1, 2, 3])
        let output = AgentGeneratedImage(id: "image-fixture", image: .png(try syntheticPNG()),
            diagnostics: .init(clientRequestID: "client", imageRequestID: "image-request", generationID: "generation"))
        let gate = ImageVerificationGate()
        let model = ImageGenerationDemoModel(session: { session }, generate: { request, _ in
            guard request.options == .init(action: .edit, transparentBackground: true),
                  request.images.first?.data == jpeg else { throw ImageDemoVerificationError("Image controls changed the request") }
            await gate.wait()
            return [output]
        })
        model.action = .edit
        model.transparentBackground = true
        try require(!model.canRun, "Edit must require a reference")
        model.references = [.jpeg(jpeg)]
        model.start()
        model.start()
        await gate.waitUntilStarted()
        try require(model.isBusy && model.results.isEmpty, "Pending image appeared as completed")
        await gate.release()
        await model.waitUntilFinished()
        try require(model.status == .completed && model.results == [output] && !model.isBusy
                    && model.results.first?.pixelSize == .init(width: 2, height: 2)
                    && model.results.first?.diagnostics?.generationID == "generation",
                    "Completed image did not become visible")

        // An uncooperative operation can return after cancellation; the UI must still discard it.
        for invalidate in [false, true] {
            let gate = ImageVerificationGate()
            let pending = ImageGenerationDemoModel(session: { session }, generate: { _, _ in
                await gate.wait()
                return [output]
            })
            pending.start()
            await gate.waitUntilStarted()
            if invalidate { pending.invalidate() } else { pending.cancel() }
            await gate.release()
            await pending.waitUntilFinished()
            try require(pending.results.isEmpty && !pending.isBusy && pending.error == nil,
                        "Cancelled or disconnected image request published a late result")
            try require(pending.status == (invalidate ? .ready : .cancelled), "Incorrect cancellation state")
            if invalidate { try require(!pending.canRun, "Disconnected image controls remained active") }
        }

        let failure = AgentRuntimeError(code: .imageGenerationUsageLimitExceeded, message: "Image allowance reached",
            http: .init(statusCode: 429, providerType: "usage_limit_reached", requestID: "request-fixture"),
            imageGeneration: .init(clientRequestID: "client", imageRequestID: "image-request",
                usageLimit: .init(resetsAt: Date(timeIntervalSince1970: 2000))))
        let failed = ImageGenerationDemoModel(session: { session }, generate: { _, _ in throw failure })
        failed.start()
        await failed.waitUntilFinished()
        try require(failed.status == .failed && failed.results.isEmpty
                    && failed.failure?.http?.requestID == "request-fixture" && failed.error == failure.message
                    && failed.failure?.imageGeneration?.imageRequestID == "image-request"
                    && failed.failure?.imageGeneration?.usageLimit?.resetsAt == Date(timeIntervalSince1970: 2000),
                    "Image provider details were lost")
        let empty = ImageGenerationDemoModel(session: { session }, generate: { _, _ in [] })
        empty.start()
        await empty.waitUntilFinished()
        try require(empty.status == .failed && empty.results.isEmpty, "Empty image output became a success")
        return ["image controls preserve transparency and edit references with built-in Codex defaults",
                "image completion publishes once and blocks overlapping requests",
                "image cancellation and disconnect discard late completion",
                "image errors preserve provider details and reject empty success"]
    }

    private static func syntheticPNG() throws -> Data {
        guard let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw ImageDemoVerificationError("PNG fixture failed") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageDemoVerificationError("PNG fixture failed")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageDemoVerificationError("PNG fixture failed") }
        return data as Data
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ImageDemoVerificationError(message) }
    }
}

private actor ImageVerificationGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            completion = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() { completion?.resume(); completion = nil }
}
private struct ImageDemoVerificationError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
#endif
