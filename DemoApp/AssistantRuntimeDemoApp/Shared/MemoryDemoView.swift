import CodexKit
import Foundation
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct MemoryDemoView: View {
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
                automaticPolicyCard
                automaticCaptureCard
                guidedAuthoringCard
                lowLevelAuthoringCard
                retrievalCard
            }
            .padding(20)
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private extension MemoryDemoView {
    var overviewCard: some View {
        DemoSectionCard {
            Text("Memory Layer")
                .font(.title2.weight(.semibold))

            Text("This demo shows the full stack: high-level automatic capture policies, mid-level guided authoring with `MemoryWriter`, and low-level raw `MemoryRecord` control.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if viewModel.session != nil {
                Label("Signed in: prompt-injection preview can also create a live thread.", systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Label("You can save and query memory without signing in. Sign in if you want the preview to open a real thread.", systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var automaticPolicyCard: some View {
        DemoSectionCard {
            Text("Automatic Policy")
                .font(.headline)

            Text("This is the high-level option. The runtime is configured to capture memory automatically after successful turns for threads with memory context.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            sampleCard(
                title: "Normal chat prompt",
                body: DemoMemoryExamples.automaticPolicyPrompt
            )

            DemoActionTile(
                title: viewModel.isRunningMemoryDemo ? "Running Automatic Policy..." : "Run Auto Memory Policy Demo",
                subtitle: "Sends a normal assistant message, then lets the runtime extract and save durable memory on its own.",
                systemImage: "bolt.badge.automatic",
                isProminent: true,
                isDisabled: viewModel.session == nil || viewModel.isRunningMemoryDemo
            ) {
                Task {
                    await viewModel.runAutomaticPolicyMemoryDemo()
                }
            }

            if let result = viewModel.automaticPolicyMemoryResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Captured after a regular turn")
                        .font(.subheadline.weight(.semibold))

                    ForEach(Array(result.records.enumerated()), id: \.offset) { _, record in
                        memoryRecordCard(
                            title: record.summary,
                            record: record,
                            diagnostics: MemoryStoreDiagnostics(
                                namespace: record.namespace,
                                implementation: "automatic_policy",
                                schemaVersion: nil,
                                totalRecords: result.records.count,
                                activeRecords: result.records.count,
                                archivedRecords: 0,
                                countsByScope: [:],
                                countsByCategory: [:]
                            )
                        )
                    }

                    Button("Open Policy Thread In Assistant") {
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

    var guidedAuthoringCard: some View {
        DemoSectionCard {
            Text("Guided Authoring")
                .font(.headline)

            Text("Uses `MemoryWriter` defaults so the app only supplies the memory payload. Namespace, scope, category, and tags are resolved automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            sampleCard(
                title: "MemoryDraft",
                body: """
                summary: \(DemoMemoryExamples.guidedDraft.summary)
                evidence: \(DemoMemoryExamples.guidedDraft.evidence.first ?? "")
                dedupeKey: \(DemoMemoryExamples.guidedDraft.dedupeKey ?? "none")
                """
            )

            DemoActionTile(
                title: viewModel.isRunningMemoryDemo ? "Saving Guided Memory..." : "Save Guided Health Coach Memory",
                subtitle: "Calls `runtime.memoryWriter(defaults:)` and resolves a real `MemoryRecord`.",
                systemImage: "wand.and.stars",
                isProminent: true,
                isDisabled: viewModel.isRunningMemoryDemo
            ) {
                Task {
                    await viewModel.runGuidedMemoryDemo()
                }
            }

            if let result = viewModel.guidedMemoryResult {
                memoryRecordCard(
                    title: "Resolved record",
                    record: result.record,
                    diagnostics: result.diagnostics
                )
            }
        }
    }

    var automaticCaptureCard: some View {
        DemoSectionCard {
            Text("Automatic Capture")
                .font(.headline)

            Text("Lets the runtime extract durable memory candidates from a transcript, then writes them through the same memory store automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            sampleCard(
                title: "Sample transcript",
                body: DemoMemoryExamples.automaticCaptureTranscript
            )

            DemoActionTile(
                title: viewModel.isRunningMemoryDemo ? "Capturing Memory..." : "Auto-Capture Memory From Transcript",
                subtitle: "Uses structured output under the hood, then saves the extracted drafts with `MemoryWriter`.",
                systemImage: "sparkles.rectangle.stack",
                isProminent: true,
                isDisabled: viewModel.session == nil || viewModel.isRunningMemoryDemo
            ) {
                Task {
                    await viewModel.runAutomaticMemoryDemo()
                }
            }

            if let result = viewModel.automaticMemoryResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Captured \(result.capture.records.count) memory record\(result.capture.records.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.semibold))

                    ForEach(Array(result.capture.records.enumerated()), id: \.offset) { _, record in
                        memoryRecordCard(
                            title: record.summary,
                            record: record,
                            diagnostics: MemoryStoreDiagnostics(
                                namespace: record.namespace,
                                implementation: "runtime_capture",
                                schemaVersion: nil,
                                totalRecords: result.capture.records.count,
                                activeRecords: result.capture.records.count,
                                archivedRecords: 0,
                                countsByScope: [:],
                                countsByCategory: [:]
                            )
                        )
                    }

                    Button("Open Capture Thread In Assistant") {
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

    var lowLevelAuthoringCard: some View {
        DemoSectionCard {
            Text("Raw Store Control")
                .font(.headline)

            Text("Writes a full `MemoryRecord` directly into the SQLite store. This is the low-level escape hatch for apps that want exact IDs, scopes, compaction flows, or custom pipelines.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            sampleCard(
                title: "MemoryRecord",
                body: """
                namespace: \(DemoMemoryExamples.rawRecord.namespace)
                scope: \(DemoMemoryExamples.rawRecord.scope.rawValue)
                category: \(DemoMemoryExamples.rawRecord.category)
                summary: \(DemoMemoryExamples.rawRecord.summary)
                """
            )

            DemoActionTile(
                title: viewModel.isRunningMemoryDemo ? "Saving Raw Memory..." : "Save Raw Travel Planner Memory",
                subtitle: "Calls `SQLiteMemoryStore.upsert(...)` directly with a fully specified record.",
                systemImage: "shippingbox.circle",
                isDisabled: viewModel.isRunningMemoryDemo
            ) {
                Task {
                    await viewModel.runRawMemoryDemo()
                }
            }

            if let result = viewModel.rawMemoryResult {
                memoryRecordCard(
                    title: "Stored raw record",
                    record: result.record,
                    diagnostics: result.diagnostics
                )
            }
        }
    }

    var retrievalCard: some View {
        DemoSectionCard {
            Text("Retrieval Preview")
                .font(.headline)

            Text("Queries the stored memories and renders the exact prompt block that would be injected into a turn. If you are signed in, it also creates a live thread with matching memory context.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            sampleCard(
                title: "Preview request",
                body: DemoMemoryExamples.previewRequestText
            )

            DemoActionTile(
                title: viewModel.isRunningMemoryDemo ? "Building Preview..." : "Preview Memory Injection",
                subtitle: viewModel.session == nil
                    ? "Runs a local memory query and renders the prompt block."
                    : "Runs `memoryQueryPreview` and prepares a real thread you can open in Assistant.",
                systemImage: "brain.head.profile",
                isDisabled: viewModel.isRunningMemoryDemo
            ) {
                Task {
                    await viewModel.runMemoryPreviewDemo()
                }
            }

            if let result = viewModel.memoryPreviewResult {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Matched \(result.result.matches.count) record\(result.result.matches.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.semibold))

                    if result.result.matches.isEmpty {
                        Text("No memory matched yet. Save one of the demo records above and run the preview again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(result.result.matches.enumerated()), id: \.offset) { _, match in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(match.record.scope.rawValue) • \(match.record.category)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(match.record.summary)
                                    .font(.body)
                                Text("score \(match.explanation.totalScore.formatted(.number.precision(.fractionLength(2))))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    sampleCard(
                        title: "Rendered prompt block",
                        body: result.renderedPrompt.isEmpty ? "(empty)" : result.renderedPrompt
                    )

                    if let threadID = result.threadID {
                        Button("Open Preview Thread In Assistant") {
                            Task {
                                await viewModel.activateThread(id: threadID)
                                selectedTab = .assistant
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                )
            }
        }
    }

    func sampleCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(body)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    func memoryRecordCard(
        title: String,
        record: MemoryRecord,
        diagnostics: MemoryStoreDiagnostics
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Group {
                detailRow(label: "Namespace", value: record.namespace)
                detailRow(label: "Scope", value: record.scope.rawValue)
                detailRow(label: "Category", value: record.category)
                detailRow(label: "Summary", value: record.summary)
                detailRow(label: "Tags", value: record.tags.joined(separator: ", "))
                detailRow(label: "Dedupe Key", value: record.dedupeKey ?? "none")
                detailRow(label: "Store Count", value: "\(diagnostics.totalRecords)")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "none" : value)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
