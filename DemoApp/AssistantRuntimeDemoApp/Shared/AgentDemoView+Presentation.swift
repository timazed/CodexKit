import CodexKit
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
extension AgentDemoView {
    @ViewBuilder
    func modelTile(for model: CodexModel) -> some View {
        DemoActionTile(
            title: model.info?.displayName ?? model.rawValue,
            subtitle: model.info?.summary ?? "Custom Codex model.",
            systemImage: model.demoSystemImage,
            isProminent: model.rawValue == viewModel.activeThreadConfiguration.model,
            isDisabled: !viewModel.canReconfigureRuntime
        ) {
            Task { await viewModel.updateModel(model) }
        }
    }

    @ViewBuilder
    func reasoningEffortTile(for effort: ReasoningEffort) -> some View {
        DemoActionTile(
            title: effort.demoTitle,
            subtitle: effort.summary,
            systemImage: effort.systemImage,
            isProminent: effort == viewModel.activeThreadConfiguration.reasoningEffort,
            isDisabled: !viewModel.canReconfigureRuntime
        ) {
            Task { await viewModel.updateReasoningEffort(effort) }
        }
    }

    func modelBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    func probeSummaryRow(title: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func threadRow(for thread: AgentThread) -> some View {
        NavigationLink {
            ThreadDetailView(viewModel: viewModel, threadID: thread.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(thread.title ?? "Untitled Thread")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text(thread.status.rawValue.capitalized)
                        Text("•")
                        Label(
                            "Powered by \(viewModel.persistenceAdapter.title)",
                            systemImage: "cylinder.split.1x2"
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let personaSummary = viewModel.personaSummary(for: thread) {
                        Text(personaSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if thread.id == viewModel.activeThread?.id {
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        thread.id == viewModel.activeThread?.id
                            ? Color.accentColor.opacity(0.12)
                            : Color.primary.opacity(0.04)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.session == nil)
    }

    var tileColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
            GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
        ]
    }
}

private extension CodexModel {
    var demoSystemImage: String {
        switch self {
        case .gpt56Sol: "sun.max"
        case .gpt56Terra: "globe.americas"
        case .gpt56Luna: "moon.stars"
        case .gpt55: "sparkles"
        case .gpt54: "brain.head.profile"
        case .gpt54Mini: "hare"
        case .gpt53CodexSpark: "bolt.fill"
        case .gpt52: "briefcase"
        default: "cpu"
        }
    }
}

private extension ReasoningEffort {
    var demoTitle: String {
        switch self {
        case .none: "No Reasoning"
        case .minimal: "Think Minimal"
        case .low: "Think Low"
        case .medium: "Think Medium"
        case .high: "Think High"
        case .extraHigh: "Think Extra High"
        case .max: "Think Max"
        case .ultra: "Think Ultra"
        case let .custom(value): "Think \(value)"
        }
    }

    var summary: String {
        switch self {
        case .none: "Skip model reasoning when supported."
        case .minimal: "Use the lightest available reasoning."
        case .low: "Fastest responses with lighter reasoning."
        case .medium: "Balanced depth for everyday app flows."
        case .high: "Deeper reasoning for tougher requests."
        case .extraHigh: "Extra-high reasoning for complex planning and review."
        case .max: "Maximum reasoning depth for the hardest problems."
        case .ultra: "Maximum reasoning; delegation requires a multi-agent host."
        case .custom: "Use a model-defined reasoning effort."
        }
    }

    var systemImage: String {
        switch self {
        case .none: "circle.slash"
        case .minimal: "gauge.with.dots.needle.0percent"
        case .low: "hare"
        case .medium: "dial.medium"
        case .high: "brain.head.profile"
        case .extraHigh: "sparkles"
        case .max: "gauge.with.dots.needle.100percent"
        case .ultra: "point.3.connected.trianglepath.dotted"
        case .custom: "slider.horizontal.3"
        }
    }
}
