import CodexKit
import CodexKitUI
import Foundation
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 17.0, macOS 14.0, *)
extension AgentDemoView {
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

    var approvalRequestBinding: Binding<ApprovalRequest?> {
        Binding(
            get: { viewModel.approvalInbox.currentRequest },
            set: { _ in }
        )
    }

    var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.lastError != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissError()
                }
            }
        )
    }

    var deviceCodePromptBinding: Binding<ChatGPTDeviceCodePrompt?> {
        Binding(
            get: { viewModel.deviceCodePromptCoordinator.currentPrompt },
            set: { _ in }
        )
    }

    @ViewBuilder
    func approvalSheet(for request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title)
                .font(.title3.weight(.semibold))

            Text(request.message)
                .foregroundStyle(.secondary)

            if case let .object(arguments) = request.toolInvocation.arguments {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Arguments")
                        .font(.headline)
                    ForEach(arguments.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(String(describing: arguments[key]))")
                            .font(.subheadline)
                    }
                }
            }

            HStack {
                Button("Deny") {
                    viewModel.denyPendingRequest()
                }
                .buttonStyle(.bordered)

                Button("Approve") {
                    viewModel.approvePendingRequest()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    @ViewBuilder
    func deviceCodeSheet(for prompt: ChatGPTDeviceCodePrompt) -> some View {
        DeviceCodePromptView(prompt: prompt)
            .presentationDetents([.medium, .large])
    }
}
