#if DEBUG
import AppKit
import CodexKit
import ImageIO
import UniformTypeIdentifiers

/// Explicit opt-in live edit using the demo's own saved browser sign-in.
/// One attempt, no generation deadline, no credential or payload logging.
@MainActor
enum MacDemoImageVerification {
    private static var didRun = false

    static func run(model: MacDemoModel) async {
        guard !didRun else { return }
        didRun = true
        model.selectedSection = .images
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--verification-result"), args.indices.contains(index + 1) else {
            model.errorMessage = "An image verification result path is required."
            return
        }
        let destination = URL(fileURLWithPath: args[index + 1])
        let directory = destination.deletingLastPathComponent()
        var report: [String: String] = [
            "runID": UUID().uuidString,
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "status": "preparing",
            "model": "gpt-6-astra", "imageModel": "omitted",
            "action": "edit", "quality": "low", "size": "omitted", "outputFormat": "jpeg",
            "source": "synthetic_jpeg_portrait", "imageAttempts": "0",
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try save(report, to: destination)
            guard model.isConnected, let sessions = model.sessions, let features = model.features else {
                throw CheckFailure(code: "sign_in_required")
            }
            let session = try await sessions.requireSession()
            let backend = CodexResponsesBackend(configuration: .init(requestRetryPolicy: .disabled, logging: .disabled))
            let catalog = try await backend.listModels(session: session, policy: .refresh)
            report["catalogSource"] = catalog.source.rawValue
            guard catalog.source == .remote, catalog.models.contains(where: { $0.id == "gpt-6-astra" }) else {
                throw CheckFailure(code: "requested_model_not_in_account_catalog")
            }
            let source = try syntheticJPEG()
            try source.write(to: directory.appendingPathComponent("input.jpg"), options: .atomic)
            try Task.checkCancellation()
            report["status"] = "running"
            report["imageAttempts"] = "1"
            report["inputByteCount"] = String(source.count)
            try save(report, to: destination)
            model.models = catalog.visibleModels
            model.modelID = "gpt-6-astra"
            let demo = features.images
            demo.action = .edit
            demo.imageModel = ""
            demo.quality = .low
            demo.outputFormat = .jpeg
            demo.references = [.jpeg(source)]
            demo.prompt = "Edit this synthetic portrait into a polished watercolor portrait with a blue background. Keep the head and shoulders centered. Return the edited image."
            model.runImageGeneration()
            await demo.waitUntilFinished()
            if demo.status == .cancelled { throw CancellationError() }
            if let failure = demo.failure { throw failure }
            guard demo.status == .completed else { throw CheckFailure(code: "image_demo_failed") }
            let images = demo.results
            try Task.checkCancellation()
            guard let generated = images.first else { throw CheckFailure(code: "missing_generated_image") }
            report["imageCount"] = String(images.count)
            report["outputByteCount"] = String(generated.image.data.count)
            report["reportedMIMEType"] = generated.image.mimeType.rawValue
            let metadata = generated.image.generationMetadata
            report["reportedStatus"] = known(metadata?.status, in: ["generating", "completed"])
            report["reportedFormat"] = known(metadata?.outputFormat, in: ["png", "jpeg", "webp"])
            report["reportedQuality"] = known(metadata?.quality, in: ["auto", "low", "medium", "high", "xhigh", "max"])
            report["reportedSize"] = safeSize(metadata?.size)
            report["reportedAction"] = known(metadata?.action, in: ["auto", "generate", "edit"])
            guard let source = CGImageSourceCreateWithData(generated.image.data as CFData, nil),
                  let type = CGImageSourceGetType(source),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CheckFailure(code: "unreadable_generated_image")
            }
            let detectedType = UTType(type as String)
            report["detectedMIMEType"] = detectedType?.preferredMIMEType
            report["outputWidth"] = String(image.width)
            report["outputHeight"] = String(image.height)
            report["imageID"] = generated.id
            let suffix = detectedType?.preferredFilenameExtension ?? "bin"
            try generated.image.data.write(to: directory.appendingPathComponent("output.\(suffix)"), options: .atomic)
            report["generationCompleted"] = "true"
            guard detectedType == .jpeg, image.width > 0, image.height > 0,
                  metadata?.quality == nil || metadata?.quality == "low" else {
                throw CheckFailure(code: "provider_output_options_mismatch")
            }
            report["status"] = "passed"
        } catch is CancellationError {
            report["status"] = "cancelled"
        } catch {
            report["status"] = "failed"
            if let error = error as? AgentRuntimeError {
                report["errorCode"] = error.code
                // The image client exposes the provider explanation, never the raw error JSON.
                report["providerExplanation"] = error.message
                report["httpStatus"] = error.http.map { String($0.statusCode) }
                report["providerCode"] = error.http?.providerCode
                report["providerType"] = error.http?.providerType
                report["requestID"] = error.http?.requestID
                report["clientRequestID"] = error.interruption?.clientRequestID
                report["responseID"] = error.interruption?.responseID
                report["lastSequenceNumber"] = error.interruption?.lastSequenceNumber.map(String.init)
            } else if let error = error as? CheckFailure {
                report["errorCode"] = error.code
            } else {
                let error = error as NSError
                report["errorDomain"] = error.domain
                report["errorCode"] = String(error.code)
            }
        }
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        do { try save(report, to: destination) }
        catch { NSLog("Could not save the image verification report.") }

    }

    private static func save(_ report: [String: String], to destination: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
    }

    private static func known(_ value: String?, in allowed: [String]) -> String? {
        value.map { allowed.contains($0) ? $0 : "unrecognized" }
    }

    private static func safeSize(_ value: String?) -> String? {
        guard let value else { return nil }
        return value == "auto" || value.range(of: #"^[0-9]{1,5}x[0-9]{1,5}$"#, options: .regularExpression) != nil
            ? value : "unrecognized"
    }

    static func syntheticJPEG() throws -> Data {
        guard let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CheckFailure(code: "jpeg_fixture_failed")
        }
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        context.setFillColor(CGColor(red: 0.25, green: 0.2, blue: 0.6, alpha: 1))
        context.fillEllipse(in: CGRect(x: 90, y: -83, width: 332, height: 280))
        context.setFillColor(CGColor(red: 0.75, green: 0.52, blue: 0.36, alpha: 1))
        context.fillEllipse(in: CGRect(x: 163, y: 166, width: 186, height: 246))
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fillEllipse(in: CGRect(x: 195, y: 297, width: 16, height: 12))
        context.fillEllipse(in: CGRect(x: 302, y: 297, width: 16, height: 12))
        context.move(to: CGPoint(x: 218, y: 234))
        context.addQuadCurve(to: CGPoint(x: 294, y: 234), control: CGPoint(x: 256, y: 200))
        context.setLineWidth(5)
        context.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
        context.strokePath()
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CheckFailure(code: "jpeg_fixture_failed")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure(code: "jpeg_fixture_failed") }
        return data as Data
    }

    private struct CheckFailure: Error { let code: String }
}
#endif
