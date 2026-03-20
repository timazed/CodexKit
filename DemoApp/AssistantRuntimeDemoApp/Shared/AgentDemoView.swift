import CodexKit
import CodexKitUI
import Foundation
import Observation
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 17.0, macOS 14.0, *)
struct AgentDemoView: View {
    @State private var viewModel: AgentDemoViewModel
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingPhoto = false
    @FocusState private var isComposerFocused: Bool

    init(viewModel: AgentDemoViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                personaExamples
                threadStrip
                messageTranscript
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
        .task {
            await viewModel.restore()
            await viewModel.registerDemoTool()
        }
        .sheet(item: approvalRequestBinding) { request in
            approvalSheet(for: request)
        }
        .sheet(item: deviceCodePromptBinding) { prompt in
            deviceCodeSheet(for: prompt)
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else {
                return
            }

            Task {
                await importPhoto(from: newItem)
            }
        }
        .alert("Runtime Error", isPresented: errorBinding) {
            Button("Dismiss") {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.lastError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent Runtime Demo")
                        .font(.title2.weight(.semibold))

                    if let session = viewModel.session {
                        Text("Signed in as \(session.account.email)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Choose a ChatGPT auth flow to start a live thread.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                headerActions
            }
        }
    }

    private var headerActions: some View {
        Group {
            if viewModel.session == nil {
                HStack(spacing: 12) {
                    registerToolButton
                    signInButton(for: .deviceCode)
                    signInButton(for: .browserOAuth)
                }
            } else {
                HStack(spacing: 12) {
                    registerToolButton
                    Button("New Thread") {
                        Task {
                            await viewModel.createThread()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Log Out") {
                        Task {
                            await viewModel.signOut()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var registerToolButton: some View {
        Button("Register Tool") {
            Task {
                await viewModel.registerDemoTool()
            }
        }
        .buttonStyle(.bordered)
    }

    private func signInButton(for authenticationMethod: DemoAuthenticationMethod) -> some View {
        Group {
            if authenticationMethod == .deviceCode {
                Button(viewModel.isAuthenticating ? "Signing In..." : authenticationMethod.buttonTitle) {
                    Task {
                        await viewModel.signIn(using: authenticationMethod)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(viewModel.isAuthenticating ? "Signing In..." : authenticationMethod.buttonTitle) {
                    Task {
                        await viewModel.signIn(using: authenticationMethod)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(viewModel.isAuthenticating)
    }

    private var threadStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.threads) { thread in
                    Button {
                        Task {
                            await viewModel.activateThread(id: thread.id)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(thread.title ?? "Untitled Thread")
                                .font(.subheadline.weight(.medium))
                            Text(thread.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let personaSummary = viewModel.personaSummary(for: thread) {
                                Text(personaSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(thread.id == viewModel.activeThread?.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var personaExamples: some View {
        if viewModel.session != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Persona Demo")
                    .font(.headline)

                Text(
                    viewModel.activeThreadPersonaSummary.map { "Active persona: \($0)" }
                        ?? "Create a support-persona thread, swap it to planner, or send a one-turn reviewer override."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        Button("Create Support Thread") {
                            Task {
                                await viewModel.createSupportPersonaThread()
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Pin Planner Persona") {
                            Task {
                                await viewModel.setPlannerPersonaOnActiveThread()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.activeThread == nil)

                        Button("Send Reviewer Example") {
                            Task {
                                await viewModel.sendReviewerOverrideExample()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var messageTranscript: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(viewModel.messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.role.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(message.displayText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !message.images.isEmpty {
                        attachmentGallery(for: message.images)
                    }
                    if !message.images.isEmpty {
                        Text(message.images.count == 1 ? "1 image attached" : "\(message.images.count) images attached")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(message.role == .user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                )
            }

            if !viewModel.streamingText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assistant")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(viewModel.streamingText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func attachmentGallery(for images: [AgentImageAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(images) { image in
                    if let platformImage = platformImage(from: image.data) {
                        Image(platformImage: platformImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var composer: some View {
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

    private func importPhoto(from item: PhotosPickerItem) async {
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

    private func preferredMIMEType(for item: PhotosPickerItem) -> String {
        for contentType in item.supportedContentTypes {
            if let mimeType = contentType.preferredMIMEType {
                return mimeType
            }
        }

        return "image/jpeg"
    }

#if canImport(UIKit)
    private func platformImage(from data: Data) -> UIImage? {
        UIImage(data: data)
    }
#elseif canImport(AppKit)
    private func platformImage(from data: Data) -> NSImage? {
        NSImage(data: data)
    }
#endif

    private var approvalRequestBinding: Binding<ApprovalRequest?> {
        Binding(
            get: { viewModel.approvalInbox.currentRequest },
            set: { _ in }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.lastError != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissError()
                }
            }
        )
    }

    private var deviceCodePromptBinding: Binding<ChatGPTDeviceCodePrompt?> {
        Binding(
            get: { viewModel.deviceCodePromptCoordinator.currentPrompt },
            set: { _ in }
        )
    }

    @ViewBuilder
    private func approvalSheet(for request: ApprovalRequest) -> some View {
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
    private func deviceCodeSheet(for prompt: ChatGPTDeviceCodePrompt) -> some View {
        DeviceCodePromptView(prompt: prompt)
            .presentationDetents([.medium, .large])
    }
}

#if canImport(UIKit)
private extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif canImport(AppKit)
private extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}
#endif

@available(iOS 17.0, macOS 14.0, *)
private struct DeviceCodePromptView: View {
    let prompt: ChatGPTDeviceCodePrompt

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Finish Sign-In")
                .font(.title3.weight(.semibold))

            Text("Open the verification page, sign in with ChatGPT, and enter this one-time code.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Code")
                    .font(.headline)
                Text(prompt.userCode)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }

            HStack(spacing: 12) {
                Button("Open Verification Page") {
                    openURL(prompt.verificationURL)
                }
                .buttonStyle(.borderedProminent)
            }

            Text(prompt.verificationURL.absoluteString)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(24)
    }
}
