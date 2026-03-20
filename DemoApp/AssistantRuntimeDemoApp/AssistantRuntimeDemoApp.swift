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
            TabView {
                NavigationStack {
                    AgentDemoView(viewModel: viewModel)
                        .navigationTitle("ChatGPT Demo")
                }
                .tabItem {
                    Label("Assistant", systemImage: "bubble.left.and.bubble.right")
                }

                NavigationStack {
                    HealthCoachView(viewModel: viewModel)
                        .navigationTitle("Health Coach")
                }
                .tabItem {
                    Label("Health Coach", systemImage: "figure.walk")
                }
            }
        }
    }
}
