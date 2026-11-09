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
            await request.onProgress?(.requesting)
            await gate.wait()
            await request.onProgress?(.completed)
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
        try require(model.progress == .requesting && model.estimatedPercentage(at: Date()) != nil
                    && model.estimatedPercentage(at: Date().addingTimeInterval(10_000)) == 99,
                    "Image estimate must start on request and remain below completion")
        await gate.release()
        await model.waitUntilFinished()
        try require(model.status == .completed && model.results == [output] && !model.isBusy
                    && model.estimatedPercentage(at: Date()) == nil
                    && model.results.first?.pixelSize == .init(width: 2, height: 2)
                    && model.results.first?.diagnostics?.generationID == "generation",
                    "Completed image did not become visible")

        // An uncooperative operation can return after cancellation; the UI must still discard it.
        for invalidate in [false, true] {
            let gate = ImageVerificationGate()
            let pending = ImageGenerationDemoModel(session: { session }, generate: { request, _ in
                await request.onProgress?(.requesting)
                await gate.wait()
                return [output]
            })
            pending.start()
            await gate.waitUntilStarted()
            if invalidate { pending.invalidate() } else { pending.cancel() }
            await gate.release()
            await pending.waitUntilFinished()
            try require(pending.results.isEmpty && !pending.isBusy && pending.error == nil
                        && pending.estimatedPercentage(at: Date()) == nil,
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
        try await verifyGIF(session: session)
        return ["animated GIF controls, playback timing, original bytes and export type",
                "image controls preserve transparency and edit references with built-in Codex defaults",
                "image completion publishes once and blocks overlapping requests",
                "image estimate caps at 99 and stops after completion or cancellation",
                "image cancellation and disconnect discard late completion",
                "image errors preserve provider details and reject empty success"]
    }

    private static func verifyGIF(session: ChatGPTSession) async throws {
        let data = syntheticGIF()
        let output = AgentGeneratedImage(id: "gif-fixture", image: .init(mimeType: .gif, data: data))
        for custom in [false, true] {
            let demo = ImageGenerationDemoModel(session: { session }, generate: { request, _ in
                guard request.options.outputFormat == .gif,
                      request.options.animation == (custom ? .init(frameCount: 2, frameDurationMilliseconds: 100) : nil) else {
                    throw ImageDemoVerificationError("GIF controls did not reach the SDK")
                }
                return [output]
            })
            demo.outputFormat = .gif
            demo.customAnimation = custom
            demo.frameCount = 2
            demo.frameDurationMilliseconds = 100
            demo.start()
            await demo.waitUntilFinished()
            try require(demo.status == .completed && demo.results.first?.image.data == data,
                        "GIF completion lost original animation bytes")
            try require(demo.results.first?.demoExportType == .gif, "GIF export used PNG")
        }
        let sample = ImageGenerationDemoModel(session: { throw ImageDemoVerificationError("Sample requested authentication") },
            generate: { _, _ in throw ImageDemoVerificationError("Sample contacted the provider") })
        sample.showAnimationSample()
        try require(sample.showingAnimationSample && sample.status == .completed
                    && sample.results.first?.demoExportType == .gif
                    && sample.results.first.flatMap({ DemoImageAnimation(data: $0.image.data) })?.frames.count == 8,
                    "Local GIF sample must play without authentication or a provider call")
        guard let animation = DemoImageAnimation(data: data) else {
            throw ImageDemoVerificationError("GIF playback could not decode its frames")
        }
        try require(animation.frames.count == 2 && abs(animation.duration - 0.2) < 0.001,
                    "GIF playback lost frame timing")
        try require(animation.frameIndex(elapsed: 0) == 0 && animation.frameIndex(elapsed: 0.11) == 1
                    && animation.frameIndex(elapsed: 0.21) == 0, "GIF playback did not advance and loop")
    }

    static func syntheticGIF() -> Data {
        let header: [UInt8] = Array("GIF89a".utf8) + [1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255]
        let prefix: [UInt8] = [0x21, 0xf9, 4, 0, 10, 0, 0, 0, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2]
        return Data(header + prefix + [0x44, 1, 0] + prefix + [0x4c, 1, 0, 0x3b])
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
