import SwiftUI

enum DemoTab: Hashable {
    case assistant
    case structuredOutput
    case healthCoach
}

@main
struct AssistantRuntimeDemoApp: App {
    @State private var viewModel: AgentDemoViewModel
    @State private var selectedTab: DemoTab = .assistant

    init() {
        let viewModel = AgentDemoRuntimeFactory.makeLive(
            enableWebSearch: true,
            keychainAccount: "AssistantRuntimeDemoApp"
        )
        _viewModel = State(initialValue: viewModel)
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    AgentDemoView(viewModel: viewModel)
                        .navigationTitle("Assistant")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tag(DemoTab.assistant)
                .tabItem {
                    Label("Assistant", systemImage: "bubble.left.and.bubble.right")
                }

                NavigationStack {
                    StructuredOutputDemoView(
                        viewModel: viewModel,
                        selectedTab: $selectedTab
                    )
                    .navigationTitle("Structured Output")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .tag(DemoTab.structuredOutput)
                .tabItem {
                    Label("Structured", systemImage: "square.stack.3d.up")
                }

                NavigationStack {
                    HealthCoachView(viewModel: viewModel)
                        .navigationTitle("Health Coach")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tag(DemoTab.healthCoach)
                .tabItem {
                    Label("Health Coach", systemImage: "figure.walk")
                }
            }
        }
    }
}
