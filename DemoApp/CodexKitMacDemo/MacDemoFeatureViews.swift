import CodexKit
import SwiftUI

struct MacDemoFeatureView: View {
    @Bindable var model: MacDemoModel
    @Bindable var features: MacDemoFeatures

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch model.selectedSection {
                case .structured: structured
                case .memory: memory
                case .runtime: runtime
                case .assistant: EmptyView()
                }
                if features.isBusy {
                    HStack {
                        ProgressView("Running example…")
                        Button("Stop") { Task { await model.stop() } }
                    }
                }
                if let error = features.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled)
                }
                if !features.result.isEmpty {
                    GroupBox("Result") {
                        Text(features.result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }
            }
            .padding(24).frame(maxWidth: 850).frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var structured: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Structured output").font(.title2.bold())
            Text("Use the same typed Swift schemas and requests as the iOS demo. Results are saved in real conversations.")
                .foregroundStyle(.secondary)
            GroupBox("Shipping support") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(DemoStructuredOutputExamples.shippingCustomerMessage)
                    action("Generate Shipping Draft", .shipping)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                action("Summarize Imported Content", .imported)
                action("Stream Text + Typed Payload", .streamed)
            }
            if !features.structuredText.isEmpty {
                Text(features.structuredText).textSelection(.enabled)
            }
            if !features.structuredPayload.isEmpty {
                Text("Typed partials received: \(features.partialCount)").font(.caption).foregroundStyle(.secondary)
                Text(features.structuredPayload).font(.callout.monospaced()).textSelection(.enabled)
                    .padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Memory").font(.title2.bold())
            Text("Save preferences, retrieve relevant records, and preview how memory enters a prompt. This store belongs to the connected account.")
                .foregroundStyle(.secondary)
            Text(model.runtimeOptions.automaticMemory
                ? "Automatic capture is enabled for conversations with Use Memory selected."
                : "Enable automatic capture in session options before connecting to capture preferences after turns.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Memory to save", text: $features.memoryText, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
            HStack {
                action("Save with MemoryWriter", .saveMemory)
                action("Save Raw Record", .rawMemory)
                action("Capture from Conversation", .captureMemory)
            }
            TextField("Search memories", text: $features.memoryQuery).textFieldStyle(.roundedBorder)
            HStack {
                action("Search", .queryMemory)
                action("Preview Prompt with Memory", .previewMemory)
            }
            ForEach(features.memories) { record in
                GroupBox(record.category) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.summary).textSelection(.enabled)
                        Text("Importance: \(record.importance, specifier: "%.1f") · \(record.tags.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            if !features.memoryPreview.isEmpty {
                DisclosureGroup("Resolved memory prompt") {
                    Text(features.memoryPreview).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private var runtime: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Runtime examples").font(.title2.bold())
            Text("Run tools, inspect instructions, change personas, or compact the current conversation.")
                .foregroundStyle(.secondary)
            GroupBox("Tools and skills") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { action("Parallel Lookups", .parallel); action("Approval Example", .approval) }
                    HStack { action("Travel Skill", .travel); action("Compare Skill Policy", .policyProbe) }
                    Text("Tools return sample data. The approval example prepares a local draft and sends nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("Conversation title", text: $features.threadTitle).textFieldStyle(.roundedBorder)
            HStack { action("Rename", .rename); action("Apply Planner Persona", .planner); action("Compact Context", .compact) }
            TextField("Temporary question / instruction preview", text: $features.ephemeralPrompt, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack { action("Ephemeral Reply", .ephemeral); action("Inspect Instructions", .instructions) }
            action("Refresh SDK Diagnostics", .diagnostics)
            Text("An ephemeral reply uses the conversation context without adding messages to its transcript.")
                .font(.caption).foregroundStyle(.secondary)
            if let chat = model.chat {
                GroupBox("Activity and usage") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Peak concurrent tools in the last chat turn: \(chat.peakConcurrentTools)")
                        ForEach(chat.runningTools.keys.sorted(), id: \.self) { id in
                            Label(chat.runningTools[id] ?? "Tool", systemImage: "gearshape.2")
                        }
                        if !chat.reasoningSummary.isEmpty { Text(chat.reasoningSummary).textSelection(.enabled) }
                        if chat.rateLimits.isEmpty { Text("Usage limits appear after a response supplies them.").foregroundStyle(.secondary) }
                        ForEach(chat.rateLimits) { limit in
                            Text("\(limit.limitName ?? limit.limitID): \(limit.primary.map { String(format: "%.0f%% remaining", $0.remainingPercent) } ?? "primary window unavailable")")
                            if let secondary = limit.secondary {
                                Text("Secondary window: \(secondary.remainingPercent, specifier: "%.0f")% remaining")
                            }
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func action(_ title: String, _ action: MacDemoAction) -> some View {
        Button(title) { model.runFeature(action) }.disabled(model.isWorking)
    }
}
