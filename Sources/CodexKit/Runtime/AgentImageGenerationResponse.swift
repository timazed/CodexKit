import Foundation

/// Image items are provisional until response.completed. Codex can send an empty
/// terminal output after streaming output_item.done, so retain those finalized items.
/// A nonempty terminal snapshot is authoritative and avoids duplicating images.
struct AgentImageGenerationResponse {
    // The provider may send image bytes in both output_item.done and response.completed.
    static let maximumStreamBytes = 2 * (
        ((AgentStoreLimits.maximumImageBytesPerWrite + 2) / 3) * 4
            + AgentStoreLimits.maximumEmbeddedPayloadByteCount
    )

    let outputFormat: AgentImageOutputFormat
    private var items: [Int: StreamImageGenerationCallItem] = [:]
    private var observedItemTypes: Set<String> = []

    init(outputFormat: AgentImageOutputFormat) { self.outputFormat = outputFormat }

    mutating func consume(_ event: CodexResponsesStreamEvent) throws -> [AgentGeneratedImage]? {
        switch event.kind {
        case let .outputItem(item, index):
            // Only known type labels, never response text, image bytes, or unknown provider values.
            observedItemTypes.insert(item.type?.rawValue ?? "unrecognized")
            if case let .imageGenerationCall(image) = item.kind {
                guard items.count < AgentStoreLimits.maximumResponseItemCount || items[index] != nil else {
                    throw tooLarge()
                }
                items[index] = image
            }
            return nil
        case let .failed(error, _):
            throw error
        case .completed:
            let snapshot = event.completedOutput.flatMap { $0.isEmpty ? nil : $0 }
            let completedItems = snapshot?.compactMap { item -> StreamImageGenerationCallItem? in
                guard case let .imageGenerationCall(image) = item.kind else { return nil }
                return image
            } ?? items.sorted { $0.key < $1.key }.map(\.value)
            guard !completedItems.isEmpty else {
                let finalTypes = event.completedOutput.map { Set($0.map { $0.type?.rawValue ?? "unrecognized" }) }
                let summary = finalTypes.map { $0.sorted().joined(separator: ", ") } ?? "omitted"
                throw AgentRuntimeError(code: .imageGenerationMissingOutput,
                    message: "The image generation request completed without returning an image. "
                        + "Terminal output types: [\(summary)]. "
                        + "Stream output types: [\(observedItemTypes.sorted().joined(separator: ", "))].")
            }
            var byteCount = 0
            return try completedItems.map { item in
                // Existing Codex streams can retain "generating" on output_item.done.
                // Accept that stale label only for a finalized item, after response.completed.
                let finalizedGenerating = item.status == "generating" && items.values.contains {
                    $0.id == item.id && $0.result == item.result && ($0.status == "generating" || $0.status == "completed")
                }
                guard item.status == "completed" || finalizedGenerating else {
                    let status = ["generating", "in_progress", "failed", "cancelled"].contains(item.status)
                        ? item.status : "unrecognized"
                    throw AgentRuntimeError(code: .imageGenerationInvalidResponse,
                        message: "The image generation response contained an unfinished image (status: \(status)).")
                }
                let format = item.outputFormat.flatMap(AgentImageOutputFormat.init(rawValue:)) ?? outputFormat
                guard let result = item.result,
                      let image = AgentImageAttachment(base64String: result, mimeType: format.mimeType, id: item.id,
                        generationMetadata: item.generationMetadata),
                      !image.data.isEmpty else {
                    throw AgentRuntimeError(code: .imageGenerationMissingOutput,
                        message: "The image generation response contained no usable image data.")
                }
                byteCount += image.data.count
                guard byteCount <= AgentStoreLimits.maximumImageBytesPerWrite else { throw tooLarge() }
                return AgentGeneratedImage(id: item.id, image: image, revisedPrompt: item.revisedPrompt)
            }
        default:
            return nil
        }
    }

    static func failure(_ original: AgentRuntimeError, http: AgentHTTPFailure?) -> AgentRuntimeError {
        let code: String
        switch original.knownCode {
        case .responsesInvalidResponse: code = AgentRuntimeErrorCode.imageGenerationInvalidResponse.rawValue
        case .responsesErrorBodyTooLarge, .responsesEventTooLarge, .turnResponseByteLimitExceeded:
            code = AgentRuntimeErrorCode.imageGenerationResponseTooLarge.rawValue
        default: code = original.code
        }
        let details = original.http.map {
            AgentHTTPFailure(statusCode: $0.statusCode, providerCode: $0.providerCode, providerType: $0.providerType,
                requestID: $0.requestID ?? http?.requestID, retryAfter: $0.retryAfter ?? http?.retryAfter)
        } ?? http
        return .init(code: code, message: original.message, http: details, interruption: original.interruption)
    }

    private func tooLarge() -> AgentRuntimeError {
        .init(code: .imageGenerationResponseTooLarge,
            message: "The image generation response exceeded its supported size limit.")
    }
}
