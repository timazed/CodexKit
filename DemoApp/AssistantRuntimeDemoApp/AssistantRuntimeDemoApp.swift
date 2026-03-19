import SwiftUI

@main
struct AssistantRuntimeDemoApp: App {
    @State private var viewModel: AgentDemoViewModel

    init() {
        let viewModel = AgentDemoRuntimeFactory.makeLive(
            enableWebSearch: true,
            keychainAccount: "AssistantRuntimeDemoApp"
        )
        _viewModel = State(initialValue: viewModel)
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
