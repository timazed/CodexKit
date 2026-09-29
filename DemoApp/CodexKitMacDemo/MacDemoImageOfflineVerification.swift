#if DEBUG
import CodexKit
import Foundation

@MainActor
enum MacDemoImageOfflineVerification {
    static func run() async throws -> [String] {
        let session = ChatGPTSession(accessToken: "synthetic-image-token",
            account: .init(id: "image-fixture", email: "demo@example.invalid", plan: .plus),
            expiresAt: Date().addingTimeInterval(3600))
        let jpeg = try MacDemoImageVerification.syntheticJPEG()
        let output = AgentGeneratedImage(id: "image-fixture", image: .jpeg(jpeg))
        let gate = ImageVerificationGate()
        let model = MacDemoImageModel(session: { session }, generate: { request, _ in
            guard request.model == "gpt-6-astra", request.imageModel == nil,
                  request.options == .init(action: .edit, outputFormat: .jpeg, quality: .low),
                  request.images.first?.data == jpeg else { throw MacDemoFeatureError("Image controls changed the request") }
            await gate.wait()
            return [output]
        })
        model.action = .edit
        try require(!model.canRun, "Edit must require a reference")
        model.references = [.jpeg(jpeg)]
        model.start(model: "gpt-6-astra")
        model.start(model: "must-not-start-twice")
        await gate.waitUntilStarted()
        try require(model.isBusy && model.results.isEmpty, "Pending image appeared as completed")
        await gate.release()
        await model.waitUntilFinished()
        try require(model.status == .completed && model.results == [output] && !model.isBusy,
                    "Completed image did not become visible")

        // An uncooperative operation can return after cancellation; the UI must still discard it.
        for invalidate in [false, true] {
            let gate = ImageVerificationGate()
            let pending = MacDemoImageModel(session: { session }, generate: { _, _ in
                await gate.wait()
                return [output]
            })
            pending.start(model: "gpt-6-astra")
            await gate.waitUntilStarted()
            if invalidate { pending.invalidate() } else { pending.cancel() }
            await gate.release()
            await pending.waitUntilFinished()
            try require(pending.results.isEmpty && !pending.isBusy && pending.error == nil,
                        "Cancelled or disconnected image request published a late result")
            try require(pending.status == (invalidate ? .ready : .cancelled), "Incorrect cancellation state")
            if invalidate { try require(!pending.canRun, "Disconnected image controls remained active") }
        }

        let failure = AgentRuntimeError(code: "image_generation_http_status_400", message: "Invalid image option",
            http: .init(statusCode: 400, providerCode: "invalid_option", requestID: "request-fixture"))
        let failed = MacDemoImageModel(session: { session }, generate: { _, _ in throw failure })
        failed.start(model: "gpt-6-astra")
        await failed.waitUntilFinished()
        try require(failed.status == .failed && failed.results.isEmpty
                    && failed.failure?.http?.requestID == "request-fixture" && failed.error == failure.message,
                    "Image provider details were lost")
        let empty = MacDemoImageModel(session: { session }, generate: { _, _ in [] })
        empty.start(model: "gpt-6-astra")
        await empty.waitUntilFinished()
        try require(empty.status == .failed && empty.results.isEmpty, "Empty image output became a success")
        return ["image controls preserve model, nil image model, low quality, JPEG and edit reference without requesting size",
                "image completion publishes once and blocks overlapping requests",
                "image cancellation and disconnect discard late completion",
                "image errors preserve provider details and reject empty success"]
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw MacDemoFeatureError(message) }
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
#endif
