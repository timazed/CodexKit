import CodexKit
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
                streamedStructuredCard
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

            Text("The streamed demo goes one step further: it shows live assistant narration, best-effort typed partials, and the final persisted payload metadata without asking the app to parse hidden text markers.")
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

    var streamedStructuredCard: some View {
        DemoSectionCard {
            Text("Streamed Text + Typed Payload")
                .font(.headline)

            Text("Streams customer-facing prose and a typed delivery update in the same turn. The final payload is also persisted on the assistant message as metadata.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            sampleInputCard(
                title: "Sample mixed-mode prompt",
                body: DemoStructuredOutputExamples.streamedStructuredPrompt
            )

            DemoActionTile(
                title: viewModel.isRunningStructuredStreamingDemo ? "Streaming Structured Turn..." : "Run Streamed Structured Demo",
                subtitle: "Uses `streamMessage(..., expecting:)` to yield prose deltas, typed partials, and a committed payload.",
                systemImage: "bubble.left.and.text.bubble.right.fill",
                isProminent: true,
                isDisabled: viewModel.session == nil || viewModel.isRunningStructuredStreamingDemo
            ) {
                Task {
                    await viewModel.runStreamedStructuredOutputDemo()
                }
            }

            streamedStatusPanel

            if let result = viewModel.structuredStreamingResult {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run checks")
                            .font(.subheadline.weight(.semibold))

                        statusRow(
                            title: "Committed typed payload",
                            detail: "A final `StreamedStructuredDeliveryUpdate` was emitted before turn completion.",
                            passed: true
                        )
                        statusRow(
                            title: "Persisted metadata",
                            detail: result.persistedMetadata == nil
                                ? "The final assistant message did not keep structured metadata."
                                : "The final assistant message now includes `structuredOutput` metadata for restore and inspection.",
                            passed: result.persistedMetadata != nil
                        )
                        statusRow(
                            title: "Partial snapshots",
                            detail: result.partialSnapshots.isEmpty
                                ? "This run did not produce a decodable partial before commit, which is still valid."
                                : "Received \(result.partialSnapshots.count) best-effort typed partial snapshot\(result.partialSnapshots.count == 1 ? "" : "s").",
                            passed: true
                        )
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.10))
                    )

                    Text("Visible assistant text")
                        .font(.subheadline.weight(.semibold))

                    Text(result.visibleText.isEmpty ? "No visible text captured." : result.visibleText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Typed partial snapshots")
                            .font(.subheadline.weight(.semibold))

                        if result.partialSnapshots.isEmpty {
                            Text("No decodable partial arrived before commit on this run.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(result.partialSnapshots.enumerated()), id: \.offset) { index, partial in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Partial \(index + 1)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    resultRow(label: "Headline", value: partial.statusHeadline)
                                    resultRow(label: "Promise", value: partial.customerPromise)
                                    resultRow(label: "Next Action", value: partial.nextAction)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.08))
                                )
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Committed payload")
                            .font(.subheadline.weight(.semibold))
                        resultRow(label: "Headline", value: result.committedPayload.statusHeadline)
                        resultRow(label: "Promise", value: result.committedPayload.customerPromise)
                        resultRow(label: "Next Action", value: result.committedPayload.nextAction)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.10))
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Persisted metadata")
                            .font(.subheadline.weight(.semibold))

                        if let metadata = result.persistedMetadata {
                            resultRow(label: "Format", value: metadata.formatName)
                            Text(metadata.payload.prettyJSONString)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                )
                                .textSelection(.enabled)
                        } else {
                            Text("No structured metadata was persisted with the final assistant message.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Open Thread In Assistant") {
                        Task {
                            await viewModel.activateThread(id: result.threadID)
                            selectedTab = .assistant
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    var streamedStatusPanel: some View {
        if viewModel.isRunningStructuredStreamingDemo {
            statusBanner(
                title: "Streaming in progress",
                detail: "Watching for live prose, typed partials, and the final persisted payload metadata.",
                tint: .orange
            )
        } else if let result = viewModel.structuredStreamingResult {
            let metadataState = result.persistedMetadata == nil ? "missing" : "saved"
            statusBanner(
                title: "Streamed structured demo passed",
                detail: "Committed payload received and metadata \(metadataState) on thread `\(result.threadTitle)`.",
                tint: .green
            )
        } else if let error = viewModel.structuredStreamingError {
            statusBanner(
                title: "Streamed structured demo failed",
                detail: error,
                tint: .red
            )
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
                subtitle: "Runs `sendMessage(..., expecting:)` and decodes into `StructuredShippingReplyDraft`.",
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
                subtitle: "Packages text and a source URL, then decodes with `sendMessage(..., expecting:)`.",
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

    func statusBanner(title: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }

    func statusRow(title: String, detail: String, passed: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? .green : .red)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
