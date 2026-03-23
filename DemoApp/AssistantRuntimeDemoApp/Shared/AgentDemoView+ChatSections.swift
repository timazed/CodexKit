import CodexKit
import Foundation
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
extension AgentDemoView {
    var header: some View {
        DemoSectionCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent Runtime Demo")
                        .font(.title2.weight(.semibold))

                    Text(
                        viewModel.session == nil
                            ? "Sign in and start a thread to explore live chat, tools, personas, and skills."
                            : "Live runtime controls for chat threads, auth, tools, and behavior changes."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.session != nil {
                    Label("Live", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.green.opacity(0.14))
                        )
                        .foregroundStyle(.green)
                }
            }

            if let session = viewModel.session {
                Text("Signed in as \(session.account.email)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: tileColumns, spacing: 12) {
                registerToolTile

                if viewModel.session == nil {
                    signInTile(for: .deviceCode, isProminent: true)
                    signInTile(for: .browserOAuth)
                } else {
                    DemoActionTile(
                        title: "New Thread",
                        subtitle: "Start a blank conversation and make it active.",
                        systemImage: "plus.bubble",
                        isProminent: true
                    ) {
                        Task {
                            await viewModel.createThread()
                        }
                    }

                    DemoActionTile(
                        title: "Log Out",
                        subtitle: "Clear the current session and local runtime state.",
                        systemImage: "rectangle.portrait.and.arrow.right"
                    ) {
                        Task {
                            await viewModel.signOut()
                        }
                    }
                }
            }
        }
    }

    var modelCard: some View {
        DemoSectionCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Model And Reasoning")
                    .font(.headline)

                HStack(spacing: 10) {
                    modelBadge(title: "Model", value: viewModel.model)
                    modelBadge(title: "Search", value: viewModel.enableWebSearch ? "On" : "Off")
                }
            }

            Text("Pick a thinking level for future requests. Existing threads stay intact; only new turns use the updated effort.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle(
                "Developer Logging",
                isOn: Binding(
                    get: { viewModel.developerLoggingEnabled },
                    set: { viewModel.developerLoggingEnabled = $0 }
                )
            )
            .toggleStyle(.switch)

            Text("Logs restore, sign-in, thread lifecycle, turn events, and tool activity to the Xcode console.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("State store: \(viewModel.resolvedStateURL.lastPathComponent)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            LazyVGrid(columns: tileColumns, spacing: 12) {
                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                    reasoningEffortTile(for: effort)
                }
            }
        }
    }

    var quickStartCard: some View {
        DemoSectionCard {
            Text("Quick Starts")
                .font(.headline)

            Text("Create a focused thread template so the chat area stays clean and each capability has a clear purpose.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: tileColumns, spacing: 12) {
                DemoActionTile(
                    title: "Support Persona",
                    subtitle: "Starts a shipping support thread with domain and style personas pinned.",
                    systemImage: "person.text.rectangle"
                ) {
                    Task {
                        await viewModel.createSupportPersonaThread()
                    }
                }

                DemoActionTile(
                    title: "Health Coach Skill",
                    subtitle: "Creates a thread whose tool policy forces step-planning behavior.",
                    systemImage: "figure.walk"
                ) {
                    Task {
                        await viewModel.createHealthCoachSkillThread()
                    }
                }

                DemoActionTile(
                    title: "Travel Planner Skill",
                    subtitle: "Creates a planning thread with a travel-specific skill attached.",
                    systemImage: "airplane.departure"
                ) {
                    Task {
                        await viewModel.createTravelPlannerSkillThread()
                    }
                }
            }

            if let activeThread = viewModel.activeThread {
                NavigationLink {
                    ThreadDetailView(
                        viewModel: viewModel,
                        threadID: activeThread.id
                    )
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                        Text("Open Current Thread")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(activeThread.title ?? "Untitled Thread")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    var personaExamples: some View {
        DemoSectionCard {
            Text("Behavior Lab")
                .font(.headline)

            Text(
                viewModel.activeThreadPersonaSummary
                    ?? "Use these controls to compare plain chat, pinned personas, per-turn overrides, and skill-constrained behavior."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            LazyVGrid(columns: tileColumns, spacing: 12) {
                DemoActionTile(
                    title: viewModel.isRunningSkillPolicyProbe ? "Running Skill Test..." : "Run Quick Skill Test",
                    subtitle: "Creates normal and skill-restricted threads, then compares the resulting tool behavior.",
                    systemImage: "bolt.horizontal.circle",
                    isProminent: true,
                    isDisabled: viewModel.isRunningSkillPolicyProbe
                ) {
                    Task {
                        await viewModel.runSkillPolicyProbe()
                    }
                }

                DemoActionTile(
                    title: "Pin Planner Persona",
                    subtitle: "Swaps the active thread into a planning-focused persona stack.",
                    systemImage: "list.bullet.clipboard",
                    isDisabled: viewModel.activeThread == nil
                ) {
                    Task {
                        await viewModel.setPlannerPersonaOnActiveThread()
                    }
                }

                DemoActionTile(
                    title: "Send Reviewer Turn",
                    subtitle: "Keeps the thread the same but applies a reviewer override for the next reply only.",
                    systemImage: "exclamationmark.bubble"
                ) {
                    Task {
                        await viewModel.sendReviewerOverrideExample()
                    }
                }
            }

            if let skillPolicyProbeResult = viewModel.skillPolicyProbeResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        skillPolicyProbeResult.passed
                            ? "Quick skill test passed"
                            : "Quick skill test needs review"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(skillPolicyProbeResult.passed ? .green : .orange)

                    Text(skillPolicyProbeResult.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    probeSummaryRow(
                        title: skillPolicyProbeResult.normalThreadTitle,
                        summary: skillPolicyProbeResult.normalSummary
                    )

                    probeSummaryRow(
                        title: skillPolicyProbeResult.skillThreadTitle,
                        summary: skillPolicyProbeResult.skillSummary
                    )

                    HStack(spacing: 10) {
                        Button("Open Normal Thread") {
                            Task {
                                await viewModel.activateThread(id: skillPolicyProbeResult.normalThreadID)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Open Skill Thread") {
                            Task {
                                await viewModel.activateThread(id: skillPolicyProbeResult.skillThreadID)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    var threadWorkspaceCard: some View {
        DemoSectionCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Threads")
                        .font(.headline)

                    Text("Pick a thread to open its transcript, attachments, and composer in a dedicated view.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(viewModel.threads.count)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if viewModel.threads.isEmpty {
                Text("No threads yet. Create one from the controls above and it will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.threads) { thread in
                        threadRow(for: thread)
                    }
                }
            }
        }
    }

    var instructionsDebugPanel: some View {
        DemoSectionCard {
            Toggle(
                "Show Resolved Instructions",
                isOn: Binding(
                    get: { viewModel.showResolvedInstructionsDebug },
                    set: { isEnabled in
                        viewModel.showResolvedInstructionsDebug = isEnabled
                        if !isEnabled {
                            viewModel.lastResolvedInstructions = nil
                            viewModel.lastResolvedInstructionsThreadTitle = nil
                        }
                    }
                )
            )
            .toggleStyle(.switch)

            Text("Developer view for the final instruction stack sent on a turn.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if viewModel.showResolvedInstructionsDebug {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        viewModel.lastResolvedInstructionsThreadTitle.map {
                            "Latest capture: \($0)"
                        } ?? "Send a message or run a demo to capture the resolved instructions."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ScrollView {
                        Text(viewModel.lastResolvedInstructions ?? "No captured instructions yet.")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }
        }
    }

    var registerToolTile: some View {
        DemoActionTile(
            title: "Register Tool",
            subtitle: "Installs the demo shipping tool so agent tool calls can run locally.",
            systemImage: "wrench.and.screwdriver"
        ) {
            Task {
                await viewModel.registerDemoTool()
            }
        }
    }

    func signInTile(
        for authenticationMethod: DemoAuthenticationMethod,
        isProminent: Bool = false
    ) -> some View {
        DemoActionTile(
            title: viewModel.isAuthenticating ? "Signing In..." : authenticationMethod.buttonTitle,
            subtitle: authenticationMethod == .deviceCode
                ? "Shows a device code flow and completes sign-in back in the app."
                : "Launches the browser-based OAuth flow using the localhost callback.",
            systemImage: authenticationMethod == .deviceCode ? "number.square" : "safari",
            isProminent: isProminent,
            isDisabled: viewModel.isAuthenticating
        ) {
            Task {
                await viewModel.signIn(using: authenticationMethod)
            }
        }
    }

    @ViewBuilder
    func reasoningEffortTile(for effort: ReasoningEffort) -> some View {
        DemoActionTile(
            title: effort.demoTitle,
            subtitle: effort.summary,
            systemImage: effort.systemImage,
            isProminent: effort == viewModel.reasoningEffort,
            isDisabled: !viewModel.canReconfigureRuntime
        ) {
            Task {
                await viewModel.updateReasoningEffort(effort)
            }
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
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
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
            ThreadDetailView(
                viewModel: viewModel,
                threadID: thread.id
            )
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(thread.title ?? "Untitled Thread")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(thread.status.rawValue.capitalized)
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
    }

    var tileColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
            GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
        ]
    }
}

private extension ReasoningEffort {
    var demoTitle: String {
        switch self {
        case .low:
            "Think Low"
        case .medium:
            "Think Medium"
        case .high:
            "Think High"
        case .extraHigh:
            "Think Extra High"
        }
    }

    var summary: String {
        switch self {
        case .low:
            "Fastest responses with lighter reasoning."
        case .medium:
            "Balanced depth for everyday app flows."
        case .high:
            "Deeper reasoning for tougher requests."
        case .extraHigh:
            "Maximum effort for complex planning and review."
        }
    }

    var systemImage: String {
        switch self {
        case .low:
            "hare"
        case .medium:
            "dial.medium"
        case .high:
            "brain.head.profile"
        case .extraHigh:
            "sparkles"
        }
    }
}
