#if DEBUG
import CodexKit
import SwiftUI

struct LocalCloudDemoView: View {
    let session: ChatGPTSession?
    let model: String
    @State private var address = "http://127.0.0.1:8787"
    @State private var mode: LocalCloudDemoMode = .fixture
    @State private var result = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Local Cloud") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Test one structured request through the local TypeScript API and decode its reply in Swift.")
                    TextField("Local API address", text: $address).textFieldStyle(.roundedBorder)
                    Picker("Provider", selection: $mode) {
                        Text("Fixture (no account needed)").tag(LocalCloudDemoMode.fixture)
                        Text("Live ChatGPT session").tag(LocalCloudDemoMode.live)
                    }
                    .disabled(task != nil)
                    Text(mode == .fixture
                        ? "Start the API with npm run dev:api. The response is synthetic; request preparation and validation are real."
                        : "Start the API with npm run dev:api -- --live. This sends your current session credentials to the loopback API for one provider request.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Run Local Cloud Test", action: run)
                            .disabled(task != nil || (mode == .live && session == nil))
                        if task != nil {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { task?.cancel() }
                        }
                    }
                    if !result.isEmpty { Label(result, systemImage: "checkmark.circle").textSelection(.enabled) }
                    if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    Text("This uses an isolated ephemeral request and verifies its saved receipt. It does not change the active conversation.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            RemoteExecutionDemoView(address: address, mode: mode, session: session, model: model)
        }
        .onDisappear { task?.cancel() }
    }

    private func run() {
        result = ""
        error = nil
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let url = try LocalCloudDemoError.address(address)
                let output = try await LocalCloudDemoProbe.run(baseURL: url, mode: mode, session: session, model: model)
                result = output.message
            } catch is CancellationError { self.error = "Cancelled." }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
