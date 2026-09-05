import CodexKit
import SwiftUI

struct DemoAccountLimitsView: View {
    let limits: [AgentRateLimitSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account Usage").font(.headline)
            if limits.isEmpty {
                Text("Usage limits will appear when the account reports them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(limits) { limit in
                VStack(alignment: .leading, spacing: 6) {
                    Text(limit.limitName ?? limit.limitID).font(.subheadline.weight(.semibold))
                    if let primary = limit.primary { window(primary, title: "Primary allowance") }
                    if let secondary = limit.secondary { window(secondary, title: "Secondary allowance") }
                    if let credits = limit.credits {
                        Text(credits.unlimited ? "Unlimited credits" : "Credits: \(credits.balance ?? (credits.hasCredits ? "Available" : "None"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Latest reported values; separate from the tokens used in a conversation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func window(_ window: AgentRateLimitWindow, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title): \(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% remaining")
                .font(.caption)
            ProgressView(value: window.remainingPercent, total: 100)
            if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct DemoLiveTurnView: View {
    let activity: DemoTurnActivity
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if isRunning { ProgressView().controlSize(.small) }
                Text(isRunning ? activity.title : (activity.notice ?? "Turn finished"))
                    .font(.subheadline.weight(.semibold))
            }
            if !activity.runningTools.isEmpty {
                Text("\(activity.runningTools.count) tool call(s) in progress")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(activity.runningTools.keys.sorted(), id: \.self) { id in
                    Text(activity.runningTools[id] ?? "Tool")
                        .font(.caption.monospaced())
                }
            }
            if activity.peakConcurrentTools > 1 {
                Label("Peak: \(activity.peakConcurrentTools) overlapping calls", systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !activity.reasoningSummary.isEmpty {
                DisclosureGroup("Reasoning summary") {
                    Text(activity.reasoningSummary).font(.caption).textSelection(.enabled)
                }
                .font(.caption)
            }
            if isRunning, let notice = activity.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}
