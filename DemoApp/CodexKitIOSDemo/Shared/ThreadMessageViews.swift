import CodexKit
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ThreadStreamingBubble: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

struct ThreadMessageBubble: View {
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(messageLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if shouldShowVisibleText {
                Text(message.displayText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let structuredOutput = message.structuredOutput {
                structuredOutputCard(structuredOutput)
            }
            if !message.images.isEmpty {
                ThreadAttachmentGallery(images: message.images)
                Text(message.images.count == 1 ? "1 image attached" : "\(message.images.count) images attached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    message.role == .user
                        ? Color.accentColor.opacity(0.12)
                        : Color.primary.opacity(0.04)
                )
        )
    }

    private var messageLabel: String {
        guard message.role == .assistant else { return message.role.rawValue.capitalized }
        switch message.phase {
        case .commentary: return "Assistant · Progress"
        case .finalAnswer: return "Assistant · Answer"
        default: return "Assistant"
        }
    }

    private var shouldShowVisibleText: Bool {
        !isPureStructuredPayloadMessage &&
            !message.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isPureStructuredPayloadMessage: Bool {
        guard let structuredOutput = message.structuredOutput else { return false }
        let rawText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty,
              let data = rawText.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        return parsed == structuredOutput.payload
    }

    @ViewBuilder
    private func structuredOutputCard(_ structuredOutput: AgentStructuredOutputMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Structured Payload")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if isPureStructuredPayloadMessage {
                Text("This assistant turn resolved into a typed structured payload.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Label(structuredOutput.formatName, systemImage: "square.stack.3d.up.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(structuredOutput.payload.prettyJSONString)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .textSelection(.enabled)
        }
        .padding(.top, shouldShowVisibleText ? 4 : 0)
    }
}

private struct ThreadAttachmentGallery: View {
    let images: [AgentImageAttachment]

    var body: some View {
        if images.contains(where: { $0.generationMetadata != nil }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(images) { image in
                    if image.generationMetadata != nil {
                        ThreadGeneratedImageView(image: image)
                    } else {
                        ThreadAttachmentThumbnail(image: image)
                    }
                }
            }
            .padding(.top, 4)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(images) { image in
                        ThreadAttachmentThumbnail(image: image)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct ThreadGeneratedImageView: View {
    let image: AgentImageAttachment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let platformImage = ThreadAttachmentImageCache.image(for: image) {
                Image(platformImage: platformImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let metadata = image.generationMetadata {
                VStack(alignment: .leading, spacing: 4) {
                    if let revisedPrompt = metadata.revisedPrompt, !revisedPrompt.isEmpty {
                        Text(revisedPrompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(generatedImageDetailText(for: metadata))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func generatedImageDetailText(
        for metadata: AgentImageGenerationMetadata
    ) -> String {
        [metadata.outputFormat, metadata.size, metadata.quality, metadata.status]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private struct ThreadAttachmentThumbnail: View {
    let image: AgentImageAttachment

    var body: some View {
        Group {
            if let platformImage = ThreadAttachmentImageCache.image(for: image) {
                Image(platformImage: platformImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

#if canImport(UIKit)
private typealias ThreadPlatformImage = UIImage
#elseif canImport(AppKit)
private typealias ThreadPlatformImage = NSImage
#endif

@MainActor
private enum ThreadAttachmentImageCache {
    private static let cache = NSCache<NSString, ThreadPlatformImage>()

    static func image(for attachment: AgentImageAttachment) -> ThreadPlatformImage? {
        let key = attachment.id as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = ThreadPlatformImage(data: attachment.data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
