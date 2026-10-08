#if DEBUG
import CodexKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct RemoteExecutionDemoView: View {
    let address: String
    let mode: LocalCloudDemoMode
    let session: ChatGPTSession?
    let model: String
    @State private var kind = RemoteDemoKind.text
    @State private var push = RemoteDemoPush.defaultSilent
    @State private var retry = false
    @State private var prompt = "Confirm the remote demo completed."
    @State private var events: [String] = []
    @State private var results: [RemoteDemoResult] = []
    @State private var checks: [String] = []
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        GroupBox("Remote Execution") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Submit a job, follow its status, and view its completed result using the local API address and provider selected above.")
                Picker("Request", selection: $kind) {
                    ForEach(RemoteDemoKind.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Completion push", selection: $push) {
                    ForEach(RemoteDemoPush.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Prompt", text: $prompt).textFieldStyle(.roundedBorder)
                if kind == .imageEdit {
                    Text("Image edit uses a small bundled PNG reference.").font(.caption).foregroundStyle(.secondary)
                }
                if mode == .fixture {
                    Toggle("Simulate a lost submission reply", isOn: $retry)
                    Text("The first reply fails after acceptance. The SDK retries the same job and preference.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Run Remote Request") { start(.single) }
                    Button("Run Mixed Batch") { start(.mixed) }
                }.disabled(task != nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == .live && session == nil))
                Text("Mixed batch sends one text, one JSON, and one image request.")
                    .font(.caption).foregroundStyle(.secondary)
                if mode == .fixture {
                    Button("Verify All Remote Features") { start(.verification) }.disabled(task != nil)
                }
                if task != nil {
                    HStack { ProgressView().controlSize(.small); Button("Stop Waiting") { task?.cancel() } }
                }
                Text("Completion events are simulated locally. One event follows all outstanding jobs; regular wins in a mixed batch. SNS/APNs delivery requires your configured middleware and device.")
                    .font(.caption).foregroundStyle(.secondary)
                if !events.isEmpty {
                    DisclosureGroup("Execution progress (\(events.count) events)") {
                        ForEach(Array(events.enumerated()), id: \.offset) { _, text in Text(text).font(.caption).textSelection(.enabled) }
                    }
                    Text(events.last ?? "").font(.caption).textSelection(.enabled)
                }
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(result.kind.rawValue) · \(result.push.rawValue)", systemImage: "checkmark.circle")
                        Text(result.text).textSelection(.enabled)
                        if let data = result.image, let image = preview(data) {
                            image.resizable().interpolation(.none).scaledToFit().frame(maxWidth: 240, maxHeight: 180)
                        }
                        Text("Job \(result.id.prefix(12)) · \(result.submissions) submission(s) · one provider execution")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !checks.isEmpty {
                    DisclosureGroup("Passed checks (\(checks.count))") {
                        ForEach(checks, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.caption) }
                    }
                }
                if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { task?.cancel() }
    }

    private enum Run { case single, mixed, verification }

    private func preview(_ data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map { Image(uiImage: $0) }
        #else
        NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }

    private func start(_ run: Run) {
        events = []; results = []; checks = []; error = nil
        // Freeze all controls before the first await; edits cannot alter a pending submission.
        let scenarios: [RemoteDemoScenario] = run == .mixed
            ? [.init(kind: .text, push: .silent), .init(kind: .json, push: .regular), .init(kind: .image, push: .defaultSilent)]
            : [.init(kind: kind, push: push, retry: mode == .fixture && retry)]
        let selectedAddress = address, selectedMode = mode, selectedSession = session, selectedModel = model, selectedPrompt = prompt
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let url = try LocalCloudDemoError.address(selectedAddress)
                let progress: RemoteExecutionDemoProbe.Progress = { text in
                    await MainActor.run { if !Task.isCancelled { events.append(text) } }
                }
                let report = try await (run == .verification
                    ? RemoteExecutionDemoProbe.verify(baseURL: url, progress: progress)
                    : RemoteExecutionDemoProbe.run(baseURL: url, mode: selectedMode, session: selectedSession,
                        model: selectedModel, scenarios: scenarios, prompt: selectedPrompt, progress: progress))
                try Task.checkCancellation()
                results = report.results
                checks = report.checks
            } catch is CancellationError { error = "Stopped waiting. Accepted jobs remain owned by the local middleware." }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
