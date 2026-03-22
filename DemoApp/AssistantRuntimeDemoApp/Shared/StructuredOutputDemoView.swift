import Foundation
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct StructuredOutputDemoView: View {
    @State var viewModel: AgentDemoViewModel
    @Binding var selectedTab: DemoTab

    init(viewModel: AgentDemoViewModel, selectedTab: Binding<DemoTab>) {
        _viewModel = State(initialValue: viewModel)
        _selectedTab = selectedTab
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                overviewCard
                shippingDraftCard
                importedContentCard
            }
            .padding(20)
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private extension StructuredOutputDemoView {
    var overviewCard: some View {
        DemoSectionCard {
            Text("Structured Output")
                .font(.title2.weight(.semibold))

            Text("Generate typed Swift models instead of freeform text. Each demo uses the same runtime as chat, writes the assistant turn into a real thread, and decodes the result into a `Decodable` model.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let session = viewModel.session {
                Label("Signed in as \(session.account.email)", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                DemoActionTile(
                    title: "Sign In From Assistant",
                    subtitle: "Structured demos need a live ChatGPT session first.",
                    systemImage: "arrow.left.circle",
                    isProminent: true
                ) {
                    selectedTab = .assistant
                }
            }
        }
    }

    var shippingDraftCard: some View {
        DemoSectionCard {
            Text("Shipping Reply Draft")
                .font(.headline)

            Text("Turns a customer support request into a typed subject, reply, and urgency value.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            sampleInputCard(
                title: "Sample customer request",
                body: DemoStructuredOutputExamples.shippingCustomerMessage
            )

            DemoActionTile(
                title: viewModel.isRunningStructuredOutputDemo ? "Generating Draft..." : "Generate Shipping Draft",
                subtitle: "Runs `completeStructured(...)` and decodes into `StructuredShippingReplyDraft`.",
                systemImage: "shippingbox",
                isProminent: true,
                isDisabled: viewModel.session == nil || viewModel.isRunningStructuredOutputDemo
            ) {
                Task {
                    await viewModel.runStructuredShippingReplyDemo()
                }
            }

            if let result = viewModel.structuredShippingReplyResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Decoded result")
                        .font(.subheadline.weight(.semibold))

                    resultRow(label: "Subject", value: result.draft.subject)
                    resultRow(label: "Urgency", value: result.draft.urgency.rawValue.capitalized)

                    Text(result.draft.reply)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Open Thread In Assistant") {
                        Task {
                            await viewModel.activateThread(id: result.threadID)
                            selectedTab = .assistant
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                )
            }
        }
    }

    var importedContentCard: some View {
        DemoSectionCard {
            Text("Imported Content Summary")
                .font(.headline)

            Text("Summarizes external content into a typed title, key points, and follow-up action.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            sampleInputCard(
                title: "Imported article excerpt",
                body: DemoStructuredOutputExamples.importedArticleExcerpt
            )

            Text(DemoStructuredOutputExamples.importedArticleURL.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            DemoActionTile(
                title: viewModel.isRunningStructuredOutputDemo ? "Summarizing Content..." : "Summarize Imported Content",
                subtitle: "Packages text and a source URL, then decodes into `StructuredImportedContentSummary`.",
                systemImage: "doc.text.magnifyingglass",
                isDisabled: viewModel.session == nil || viewModel.isRunningStructuredOutputDemo
            ) {
                Task {
                    await viewModel.runStructuredImportedSummaryDemo()
                }
            }

            if let result = viewModel.structuredImportedSummaryResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Decoded result")
                        .font(.subheadline.weight(.semibold))

                    resultRow(label: "Title", value: result.summary.title)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Key Points")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(result.summary.keyPoints.enumerated()), id: \.offset) { index, point in
                            Text("\(index + 1). \(point)")
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    resultRow(label: "Follow-up", value: result.summary.followUpAction)

                    Button("Open Thread In Assistant") {
                        Task {
                            await viewModel.activateThread(id: result.threadID)
                            selectedTab = .assistant
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    func sampleInputCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(body)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    func resultRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
