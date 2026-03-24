import CodexKit
import Foundation
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 17.0, macOS 14.0, *)
struct ThreadDetailView: View {
    @State var viewModel: AgentDemoViewModel
    let threadID: String

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingPhoto = false
    @FocusState private var isComposerFocused: Bool

    init(viewModel: AgentDemoViewModel, threadID: String) {
        _viewModel = State(initialValue: viewModel)
        self.threadID = threadID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                threadHeaderCard
                compactionCard
                transcriptCard
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                isComposerFocused = false
            }
        )
#if os(iOS)
        .scrollDismissesKeyboard(.interactively)
#endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                composer
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            .background(.regularMaterial)
        }
        .navigationTitle(activeThread?.title ?? "Thread")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: threadID) {
            await viewModel.activateThread(id: threadID)
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else {
                return
            }

            Task {
                await importPhoto(from: newItem)
            }
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private extension ThreadDetailView {
    var activeThread: AgentThread? {
        viewModel.threads.first { $0.id == threadID }
    }

    var threadHeaderCard: some View {
        DemoSectionCard {
            Text(activeThread?.title ?? "Thread")
                .font(.title3.weight(.semibold))

            Text(activeThread?.status.rawValue.capitalized ?? "Idle")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let personaSummary = viewModel.personaSummary(for: activeThread) {
                Text(personaSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label(
                    viewModel.model,
                    systemImage: "cpu"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    reasoningEffortTitle,
                    systemImage: reasoningEffortSymbol
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    var transcriptCard: some View {
        DemoSectionCard {
            if threadMessages.isEmpty && viewModel.streamingText.isEmpty {
                Text("No messages yet. Send the first message from the composer below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(threadMessages) { message in
                        ThreadMessageBubble(message: message)
                    }

                    if isStreamingActive {
                        ThreadStreamingBubble(text: viewModel.streamingText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var compactionCard: some View {
        DemoSectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Context Compaction")
                    .font(.headline)

                Text("Preserves the visible transcript, but rewrites the runtime’s hidden effective prompt context for future turns.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                compactionMetric(
                    title: "Visible Messages",
                    value: "\(threadMessages.count)"
                )
                compactionMetric(
                    title: "Effective Messages",
                    value: "\(viewModel.activeThreadContextState?.effectiveMessages.count ?? threadMessages.count)"
                )
                compactionMetric(
                    title: "Generation",
                    value: "\(viewModel.activeThreadContextState?.generation ?? 0)"
                )
            }

            if let contextState = viewModel.activeThreadContextState {
                VStack(alignment: .leading, spacing: 6) {
                    if let reason = contextState.lastCompactionReason {
                        Text("Last compaction: \(reason.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let lastCompactedAt = contextState.lastCompactedAt {
                        Text("Updated \(lastCompactedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let summaryMessage = contextState.effectiveMessages.first(where: { $0.role == .system }),
                       !summaryMessage.text.isEmpty {
                        Text(summaryMessage.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .padding(.top, 2)
                    }
                }
            } else {
                Text("No compacted context exists yet for this thread. Send a few messages, then compact to compare the prompt working set against the preserved transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        await viewModel.compactActiveThreadContext()
                    }
                } label: {
                    Label(
                        viewModel.isCompactingThreadContext ? "Compacting..." : "Compact Context Now",
                        systemImage: viewModel.isCompactingThreadContext ? "hourglass" : "arrow.triangle.branch"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.session == nil || activeThread == nil || viewModel.isCompactingThreadContext)

                Button {
                    Task {
                        await viewModel.refreshThreadContextState(for: threadID)
                    }
                } label: {
                    Label("Refresh State", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.session == nil || activeThread == nil)
            }
        }
    }

    var composer: some View {
        let photoPickerIconName = isImportingPhoto ? "hourglass" : "photo.on.rectangle"

        return VStack(alignment: .leading, spacing: 10) {
            if !viewModel.pendingComposerImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(viewModel.pendingComposerImages.enumerated()), id: \.element.id) { index, image in
                            HStack(spacing: 6) {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)

                                Text("Image \(index + 1)")
                                    .font(.caption.weight(.medium))

                                Button {
                                    viewModel.removePendingComposerImage(id: image.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.12))
                            )
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: photoPickerIconName)
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.session == nil || isImportingPhoto)

                TextField("Message the agent", text: $viewModel.composerText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)
                    .focused($isComposerFocused)
                    .onSubmit {
                        isComposerFocused = false
                        Task {
                            await viewModel.sendComposerText()
                        }
                    }

                Button("Send") {
                    isComposerFocused = false
                    Task {
                        await viewModel.sendComposerText()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.session == nil ||
                        (
                            viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                viewModel.pendingComposerImages.isEmpty
                        )
                )
            }
        }
    }

    var threadMessages: [AgentMessage] {
        viewModel.activeThreadID == threadID ? viewModel.messages : []
    }

    var isStreamingActive: Bool {
        viewModel.activeThreadID == threadID && !viewModel.streamingText.isEmpty
    }

    var reasoningEffortTitle: String {
        switch viewModel.reasoningEffort {
        case .low:
            "Think Low"
        case .medium:
            "Think Medium"
        case .high:
            "Think High"
        case .extraHigh:
            "Think Extra High"
        }
    }

    var reasoningEffortSymbol: String {
        switch viewModel.reasoningEffort {
        case .low:
            "hare"
        case .medium:
            "dial.medium"
        case .high:
            "brain.head.profile"
        case .extraHigh:
            "sparkles"
        }
    }

    func importPhoto(from item: PhotosPickerItem) async {
        isImportingPhoto = true

        defer {
            isImportingPhoto = false
            selectedPhotoItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                viewModel.reportError("The selected photo could not be loaded.")
                return
            }

            let mimeType = preferredMIMEType(for: item)
            viewModel.queueComposerImage(
                data: data,
                mimeType: mimeType
            )
        } catch {
            viewModel.reportError(error.localizedDescription)
        }
    }

    func preferredMIMEType(for item: PhotosPickerItem) -> String {
        for contentType in item.supportedContentTypes {
            if let mimeType = contentType.preferredMIMEType {
                return mimeType
            }
        }

        return "image/jpeg"
    }

    @ViewBuilder
    func compactionMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

}

private struct ThreadStreamingBubble: View {
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

private struct ThreadMessageBubble: View {
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role.rawValue.capitalized)
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

    private var shouldShowVisibleText: Bool {
        guard !isPureStructuredPayloadMessage else {
            return false
        }
        return !message.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isPureStructuredPayloadMessage: Bool {
        guard let structuredOutput = message.structuredOutput else {
            return false
        }

        let rawText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty,
              let data = rawText.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return false
        }

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
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let image = ThreadPlatformImage(data: attachment.data) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
