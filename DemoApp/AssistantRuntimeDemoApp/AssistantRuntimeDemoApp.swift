import SwiftUI

enum DemoTab: Hashable {
    case assistant
    case structuredOutput
    case memory
    case healthCoach
}

@main
struct AssistantRuntimeDemoApp: App {
    @State private var viewModel: AgentDemoViewModel?
    @State private var setupError: String?
    @State private var selectedTab: DemoTab = .assistant

    init() {
        do {
            let viewModel = try AgentDemoRuntimeFactory.makeLive(
                enableWebSearch: true,
                enableImageGeneration: true,
                keychainAccount: "AssistantRuntimeDemoApp"
            )
            _viewModel = State(initialValue: viewModel)
            _setupError = State(initialValue: nil)
        } catch {
            _viewModel = State(initialValue: nil)
            _setupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let viewModel {
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
                        MemoryDemoView(
                            viewModel: viewModel,
                            selectedTab: $selectedTab
                        )
                        .navigationTitle("Memory")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .tag(DemoTab.memory)
                    .tabItem {
                        Label("Memory", systemImage: "brain")
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
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Couldn’t Start the Demo")
                        .font(.headline)
                    Text(setupError ?? "The persistence store could not be opened.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }
}
