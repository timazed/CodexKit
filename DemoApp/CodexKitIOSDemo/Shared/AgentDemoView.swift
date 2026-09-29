import CodexKit
import CodexKitUI
import Foundation
import Observation
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct AgentDemoView: View {
    @State var viewModel: AgentDemoViewModel

    init(viewModel: AgentDemoViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if viewModel.session != nil {
                    modelCard
                    quickStartCard
                    NavigationLink {
                        ImageGenerationDemoView {
                            guard let session = await viewModel.runtime.currentSession() else {
                                throw AgentRuntimeError.signedOut()
                            }
                            guard !session.requiresRefresh() else {
                                throw AgentRuntimeError.unauthorized("Reconnect to refresh your session before generating images.")
                            }
                            return session
                        }
                    } label: {
                        Label("Images · Generate or edit", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.buttonStyle(.bordered)
                    personaExamples
                    instructionsDebugPanel
                }
                threadWorkspaceCard
            }
            .padding(20)
            .contentShape(Rectangle())
        }
#if os(iOS)
        .scrollDismissesKeyboard(.interactively)
#endif
        .task {
            await viewModel.restore()
        }
        .sheet(item: approvalRequestBinding) { request in
            approvalSheet(for: request)
        }
        .sheet(item: deviceCodePromptBinding) { prompt in
            deviceCodeSheet(for: prompt)
        }
        .alert("Runtime Error", isPresented: errorBinding) {
            Button("Dismiss") {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.lastError ?? "")
        }
    }
}
