import Foundation
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct HealthCoachView: View {
    @State var viewModel: AgentDemoViewModel

    init(viewModel: AgentDemoViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                goalCard
                toneCard
                feedbackCard
                healthErrorCard
                actionButtons
            }
            .padding(20)
        }
        .task {
            await viewModel.initializeHealthCoachIfNeeded()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                await viewModel.refreshHealthCoachProgress()
            }
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private extension HealthCoachView {
    var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(.headline)

            Text("\(viewModel.todayStepCount) / \(viewModel.dailyStepGoal) steps")
                .font(.title3.weight(.semibold))

            ProgressView(value: viewModel.healthProgressFraction)
                .progressViewStyle(.linear)

            if viewModel.hasMetDailyGoal {
                Text("Goal complete. Well done, you pushed through.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Text("\(viewModel.remainingStepCount) steps remaining")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let updatedAt = viewModel.healthLastUpdatedAt {
                Text("Last updated \(updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label(
                    viewModel.healthKitAuthorized ? "Health Access On" : "Health Access Off",
                    systemImage: viewModel.healthKitAuthorized ? "checkmark.shield.fill" : "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(viewModel.healthKitAuthorized ? .green : .orange)

                Label(
                    viewModel.notificationAuthorized ? "Reminders On" : "Reminders Off",
                    systemImage: viewModel.notificationAuthorized ? "bell.badge.fill" : "bell.slash"
                )
                .font(.caption)
                .foregroundStyle(viewModel.notificationAuthorized ? .green : .orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    var goalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily Goal")
                .font(.headline)

            HStack(spacing: 12) {
                Button("-500") {
                    Task {
                        await viewModel.adjustDailyStepGoal(by: -500)
                    }
                }
                .buttonStyle(.bordered)

                Text("\(viewModel.dailyStepGoal) steps")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 150, alignment: .center)

                Button("+500") {
                    Task {
                        await viewModel.adjustDailyStepGoal(by: 500)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    var toneCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coach Tone")
                .font(.headline)

            Picker("Coach Tone", selection: toneModeBinding) {
                ForEach(HealthCoachToneMode.allCases) { toneMode in
                    Text(toneMode.title)
                        .tag(toneMode)
                }
            }
            .pickerStyle(.segmented)

            Text(viewModel.healthCoachToneMode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coach Feedback")
                .font(.headline)

            if viewModel.isAskingHealthCoach {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Coach is updating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(viewModel.healthCoachFeedback)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    @ViewBuilder
    var healthErrorCard: some View {
        if let lastError = viewModel.lastError,
           !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Health Error")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.red.opacity(0.10))
            )
        }
    }

    var actionButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button("Enable Permissions") {
                        Task {
                            await viewModel.requestHealthCoachPermissions()
                        }
                    }
                    .buttonStyle(.bordered)

                    Button(viewModel.isRefreshingHealthCoach ? "Refreshing..." : "Refresh Steps") {
                        Task {
                            await viewModel.refreshHealthCoachProgress()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRefreshingHealthCoach)

                    Button(viewModel.isAskingHealthCoach ? "Coach Updating..." : "Regenerate Coach") {
                        Task {
                            await viewModel.refreshAICoachFeedback(force: true)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isAskingHealthCoach)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    var toneModeBinding: Binding<HealthCoachToneMode> {
        Binding(
            get: { viewModel.healthCoachToneMode },
            set: { toneMode in
                Task {
                    await viewModel.setHealthCoachToneMode(toneMode)
                }
            }
        )
    }
}
