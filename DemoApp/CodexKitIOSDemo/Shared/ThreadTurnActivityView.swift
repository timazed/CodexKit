import CodexKit
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct ThreadTurnActivityView: View {
    let status: AgentThreadStatus

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var title: String {
        switch status {
        case .idle:
            "Idle"
        case .streaming:
            "Thinking..."
        case .waitingForApproval:
            "Waiting for approval..."
        case .waitingForToolResult:
            "Running tool..."
        case .failed:
            "Turn failed"
        }
    }

    private var subtitle: String {
        switch status {
        case .idle:
            "No active turn."
        case .streaming:
            "The assistant is preparing a reply."
        case .waitingForApproval:
            "Approve or deny the pending tool request to continue."
        case .waitingForToolResult:
            "A host tool is still executing."
        case .failed:
            "Check the latest error and try again."
        }
    }
}
