import CodexKit
import CodexKitUI
import Foundation
import Observation
import PhotosUI
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct AgentDemoView: View {
    @State var viewModel: AgentDemoViewModel
    @State var selectedPhotoItem: PhotosPickerItem?
    @State var isImportingPhoto = false
    @FocusState var isComposerFocused: Bool

    init(viewModel: AgentDemoViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                personaExamples
                instructionsDebugPanel
                threadStrip
                messageTranscript
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                isComposerFocused = false
            }
        )
#if os(iOS)
        .scrollDismissesKeyboard(.interactively)
#endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                composer
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
            .background(.regularMaterial)
        }
        .task {
            await viewModel.restore()
            await viewModel.registerDemoTool()
        }
        .sheet(item: approvalRequestBinding) { request in
            approvalSheet(for: request)
        }
        .sheet(item: deviceCodePromptBinding) { prompt in
            deviceCodeSheet(for: prompt)
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else {
                return
            }

            Task {
                await importPhoto(from: newItem)
            }
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
