import CodexKit
import SwiftUI

/// Shared iOS/macOS example. Only outputCommitted promotes previews to a saved result.
@MainActor
struct ProgressiveOutputDemoView: View {
    @Bindable var model: ProgressiveOutputDemoModel
    let isConnected: Bool
    let isHostBusy: Bool
    let run: (ProgressiveOutputDemoMode) -> Void
    let reload: () -> Void
    let cancel: () -> Void
    @State private var selection: ProgressiveOutputDemoMode = .records

    var body: some View {
        GroupBox("Turn-based streaming output") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Uses start(_:in:output:) for text, typed records, XML, or native JSON Schema.")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Picker("Output format", selection: $selection) {
                    ForEach(ProgressiveOutputDemoMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .disabled(model.isBusy)
                Text(selection.explanation).font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { controls }
                    VStack(alignment: .leading) { controls }
                }
                if !isConnected { Text("Connect a session to run this example.").font(.caption) }
                Label(model.status, systemImage: model.isCommitted ? "checkmark.seal.fill" : "info.circle")
                    .font(.callout).foregroundStyle(model.isCommitted ? Color.green : Color.secondary)
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if model.threadID != nil {
                    Text("\(model.mode.rawValue) · \(model.previewEvents) preview events")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Turn identity") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Thread: \(model.threadID ?? "")")
                            if let context = model.context {
                                Text("Turn: \(context.turnID)")
                                Text("Message: \(context.messageID)")
                                Text("Document: \(context.documentID.uuidString)")
                            }
                        }.font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                ForEach(model.units) { unit in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(unit.title).font(.headline)
                        Text(unit.attributes).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(unit.text).textSelection(.enabled)
                        Text(unitStatus(unit))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                if !model.rawText.isEmpty {
                    Text(model.mode == .text ? "Text" : "Raw \(model.mode.rawValue)")
                        .font(.caption.bold())
                    Text(model.rawText).font(.callout.monospaced()).textSelection(.enabled)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var controls: some View {
        Button("Run New Turn") {
            run(selection)
        }
        .disabled(!isConnected || isHostBusy || model.isBusy)
        if model.isBusy {
            ProgressView().controlSize(.small)
            Button("Cancel", action: cancel)
        }
        if model.isCommitted {
            Button(model.isReloading ? "Reloading…" : "Reload Saved Output", action: reload)
                .disabled(!isConnected || isHostBusy || model.isBusy)
        }
    }

    private func unitStatus(_ unit: ProgressiveDemoUnit) -> String {
        if model.isCommitted { return "Saved" }
        return unit.isClosed ? "Complete unit · uncommitted" : "Streaming · uncommitted"
    }
}
