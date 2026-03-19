import CodexKitDemo
import SwiftUI

@main
struct AssistantRuntimeDemoApp: App {
    @State private var viewModel: AgentDemoViewModel

    init() {
        let runtime = AgentDemoRuntimeFactory.makeLive(
            redirectURI: URL(string: "assistantdemoapp://oauth/callback")!,
            keychainAccount: "AssistantRuntimeDemoApp"
        )
        _viewModel = State(initialValue: runtime.viewModel)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                AgentDemoView(viewModel: viewModel)
                    .navigationTitle("ChatGPT Demo")
            }
        }
    }
}
