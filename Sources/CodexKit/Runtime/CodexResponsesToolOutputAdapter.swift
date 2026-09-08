import Foundation

struct CodexResponsesToolOutputAdapter: Sendable {
    let urlSession: URLSession

    func text(from result: ToolResultEnvelope) -> String {
        var segments: [String] = []
        if let text = result.combinedText {
            segments.append(text)
        }
        let imageURLs = result.content.compactMap { content -> URL? in
            guard case let .image(url) = content else { return nil }
            return url
        }
        if !imageURLs.isEmpty {
            segments.append("Image URLs:\n" + imageURLs.map(\.absoluteString).joined(separator: "\n"))
        }
        if !segments.isEmpty {
            return segments.joined(separator: "\n\n")
        }
        if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return result.success ? "Tool execution completed." : "Tool execution failed."
    }

    func images(from result: ToolResultEnvelope) async -> [AgentImageAttachment] {
        var attachments: [AgentImageAttachment] = []
        for content in result.content {
            guard !Task.isCancelled else { break }
            guard case let .image(url) = content else { continue }
            if let attachment = await imageAttachment(from: url) {
                attachments.append(attachment)
            }
        }
        return attachments.uniqued()
    }

    private func imageAttachment(from url: URL) async -> AgentImageAttachment? {
        if url.scheme?.lowercased() == "data" {
            let encodedLimit = AgentImageAttachment.maximumDataURLByteCount * 3
            guard url.absoluteString.utf8.count <= encodedLimit else { return nil }
            let decoded = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            return AgentImageAttachment(dataURLString: decoded)
        }

        if url.isFileURL {
            guard let mimeType = RuntimeImageMimeType(pathExtension: url.pathExtension),
                  let data = try? readBoundedFile(url),
                  !data.isEmpty else {
                return nil
            }
            return AgentImageAttachment(mimeType: mimeType.rawValue, data: data)
        }

        do {
            let (bytes, response) = try await urlSession.bytes(from: url)
            defer { bytes.task.cancel() }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode) else { return nil }
            guard response.expectedContentLength < 0 ||
                    response.expectedContentLength <= AgentStoreLimits.maximumImageByteCount else {
                return nil
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                guard data.count < AgentStoreLimits.maximumImageByteCount else { return nil }
                if data.count % 16_384 == 0 { try Task.checkCancellation() }
                data.append(byte)
            }
            guard !Task.isCancelled, let mimeType = RuntimeDownloadedImage.mimeType(for: data) else { return nil }
            return AgentImageAttachment(mimeType: mimeType, data: data)
        } catch {
            return nil
        }
    }

    private func readBoundedFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              (values.fileSize ?? 0) <= AgentStoreLimits.maximumImageByteCount else {
            return Data()
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: AgentStoreLimits.maximumImageByteCount + 1) ?? Data()
        return data.count <= AgentStoreLimits.maximumImageByteCount ? data : Data()
    }
}

private enum RuntimeImageMimeType: String {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case gif = "image/gif"
    case webp = "image/webp"
    case heic = "image/heic"
    case heif = "image/heif"

    init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "gif": self = .gif
        case "webp": self = .webp
        case "heic": self = .heic
        case "heif": self = .heif
        default: return nil
        }
    }
}
