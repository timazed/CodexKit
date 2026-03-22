import CodexKit
import CodexKitUI
import Foundation
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
extension AgentDemoView {
    var approvalRequestBinding: Binding<ApprovalRequest?> {
        Binding(
            get: { viewModel.approvalInbox.currentRequest },
            set: { _ in }
        )
    }

    var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.lastError != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissError()
                }
            }
        )
    }

    var deviceCodePromptBinding: Binding<ChatGPTDeviceCodePrompt?> {
        Binding(
            get: { viewModel.deviceCodePromptCoordinator.currentPrompt },
            set: { _ in }
        )
    }

    @ViewBuilder
    func approvalSheet(for request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title)
                .font(.title3.weight(.semibold))

            Text(request.message)
                .foregroundStyle(.secondary)

            if case let .object(arguments) = request.toolInvocation.arguments {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Arguments")
                        .font(.headline)
                    ForEach(arguments.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(String(describing: arguments[key]))")
                            .font(.subheadline)
                    }
                }
            }

            HStack {
                Button("Deny") {
                    viewModel.denyPendingRequest()
                }
                .buttonStyle(.bordered)

                Button("Approve") {
                    viewModel.approvePendingRequest()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    @ViewBuilder
    func deviceCodeSheet(for prompt: ChatGPTDeviceCodePrompt) -> some View {
        DeviceCodePromptView(prompt: prompt)
            .presentationDetents([.medium, .large])
    }
}
