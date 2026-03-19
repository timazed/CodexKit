import CodexKitDemo
import SwiftUI

@main
struct AssistantRuntimeDemoApp: App {
    @State private var viewModel: AssistantDemoViewModel

    init() {
        let runtime = AssistantDemoRuntimeFactory.makeLive(
            redirectURI: URL(string: "assistantdemoapp://oauth/callback")!,
            keychainAccount: "AssistantRuntimeDemoApp"
        )
        _viewModel = State(initialValue: runtime.viewModel)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                AssistantDemoView(viewModel: viewModel)
                    .navigationTitle("ChatGPT Demo")
            }
        }
    }
}
