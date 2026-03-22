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
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.role.rawValue.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(message.displayText)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !message.images.isEmpty {
                                attachmentGallery(for: message.images)

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

                    if isStreamingActive {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Assistant")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(viewModel.streamingText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    func attachmentGallery(for images: [AgentImageAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(images) { image in
                    if let platformImage = platformImage(from: image.data) {
                        Image(platformImage: platformImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .padding(.top, 4)
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

#if canImport(UIKit)
    func platformImage(from data: Data) -> UIImage? {
        UIImage(data: data)
    }
#elseif canImport(AppKit)
    func platformImage(from data: Data) -> NSImage? {
        NSImage(data: data)
    }
#endif
}
