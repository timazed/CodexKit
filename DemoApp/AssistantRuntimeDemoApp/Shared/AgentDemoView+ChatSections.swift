import CodexKit
import Foundation
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
extension AgentDemoView {
    var header: some View {
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

    var headerActions: some View {
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

    var registerToolButton: some View {
        Button("Register Tool") {
            Task {
                await viewModel.registerDemoTool()
            }
        }
        .buttonStyle(.bordered)
    }

    func signInButton(for authenticationMethod: DemoAuthenticationMethod) -> some View {
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

    var threadStrip: some View {
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
                                .fill(
                                    thread.id == viewModel.activeThread?.id
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.secondary.opacity(0.12)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    var personaExamples: some View {
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

    var messageTranscript: some View {
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
    func attachmentGallery(for images: [AgentImageAttachment]) -> some View {
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
}
