import CodexKit
import Foundation

struct DemoTurnActivity {
    var title = "Preparing a reply"
    var reasoningSummary = ""
    var runningTools: [String: String] = [:]
    var peakConcurrentTools = 0
    var notice: String?
}

@MainActor
extension AgentDemoViewModel {
    var selectableModels: [CodexModel] {
        var models = modelCatalog?.visibleModels.map(\.model) ?? CodexModel.userFacingModels
        let selected = activeThreadConfiguration.codexModel
        if !models.contains(selected) { models.append(selected) }
        return models
    }

    func discoveredModel(_ model: CodexModel) -> CodexAvailableModel? {
        modelCatalog?.models.first { $0.model == model }
    }

    var modelCatalogDescription: String {
        guard let catalog = modelCatalog else { return "Bundled models · refresh after signing in" }
        let source: String = switch catalog.source {
        case .remote: "Account models"
        case .cache: "Cached account models"
        case .bundled: "Bundled models"
        }
        return source + (catalog.isStale ? " · refresh needed" : "")
    }

    func refreshModels(force: Bool = false) async {
        guard session != nil, !isRefreshingModels else { return }
        let generation = runtimeFeaturesGeneration
        let sourceRuntime = runtime
        isRefreshingModels = true
        defer { if generation == runtimeFeaturesGeneration { isRefreshingModels = false } }
        do {
            let catalog = try await sourceRuntime.listModels(policy: force ? .refresh : .preferCached)
            let limits = try await sourceRuntime.rateLimits()
            guard generation == runtimeFeaturesGeneration else { return }
            modelCatalog = catalog
            mergeRateLimits(limits)
        } catch {
            guard generation == runtimeFeaturesGeneration else { return }
            reportError(error)
        }
    }

    func mergeRateLimits(_ updates: [AgentRateLimitSnapshot]) {
        for update in updates {
            accountRateLimits.removeAll { $0.limitID == update.limitID }
            accountRateLimits.append(update)
        }
        accountRateLimits.sort { $0.limitID < $1.limitID }
    }

    func resetRuntimeFeatures() {
        runtimeFeaturesGeneration = UUID()
        modelCatalog = nil
        accountRateLimits = []
        isRefreshingModels = false
        turnActivities = [:]
        runningTurnIDs = [:]
        sendingThreadIDs = []
        stoppingThreadIDs = []
        steeringThreadIDs = []
    }

    func receiveProgress(_ progress: AgentTurnProgress) {
        var activity = turnActivities[progress.threadID] ?? DemoTurnActivity()
        switch progress.content {
        case let .messageStarted(_, phase):
            activity.title = phase == .finalAnswer ? "Writing the answer" : "Working on your request"
        case let .messageCompleted(_, phase):
            if phase == .finalAnswer { activity.title = "Finishing" }
        case let .reasoningSummaryDelta(_, _, delta):
            activity.title = "Thinking"
            activity.reasoningSummary = String((activity.reasoningSummary + delta).suffix(4_000))
        case let .webSearch(_, status, _):
            activity.title = status == "completed" ? "Search complete" : "Searching the web"
        }
        turnActivities[progress.threadID] = activity
    }

    func receiveToolStart(_ invocation: ToolInvocation) {
        var activity = turnActivities[invocation.threadID] ?? DemoTurnActivity()
        activity.runningTools[invocation.id] = invocation.toolName
        activity.peakConcurrentTools = max(activity.peakConcurrentTools, activity.runningTools.count)
        turnActivities[invocation.threadID] = activity
    }

    func receiveToolFinish(_ result: ToolResultEnvelope, threadID: String) {
        turnActivities[threadID]?.runningTools[result.invocationID] = nil
    }

    func stopTurn(in threadID: String) async {
        guard let turnID = runningTurnIDs[threadID], !stoppingThreadIDs.contains(threadID) else { return }
        stoppingThreadIDs.insert(threadID)
        turnActivities[threadID]?.notice = "Stopping…"
        do {
            try await runtime.interrupt(in: threadID, expectedTurnID: turnID)
        } catch {
            stoppingThreadIDs.remove(threadID)
            reportError(error)
        }
    }

    func addComposerToTurn(text: String, images: [AgentImageAttachment], threadID: String) async {
        guard let turnID = runningTurnIDs[threadID], !stoppingThreadIDs.contains(threadID),
              !steeringThreadIDs.contains(threadID) else { return }
        steeringThreadIDs.insert(threadID)
        defer { steeringThreadIDs.remove(threadID) }
        do {
            try await runtime.steer(text, images: images, in: threadID, expectedTurnID: turnID)
            // Preserve edits made while the request was being accepted.
            if composerText.trimmingCharacters(in: .whitespacesAndNewlines) == text { composerText = "" }
            let sentIDs = Set(images.map(\.id))
            pendingComposerImages.removeAll { sentIDs.contains($0.id) }
            turnActivities[threadID]?.notice = "Added to this turn. It will be used on the next model request."
        } catch { reportError(error) }
    }

    func registerParallelDemoTools() async throws {
        for (name, description, output) in [
            ("demo_lookup_weather", "Read sample Sydney weather for the parallel-tools demo.", "Sample weather: Sydney, sunny, 22°C."),
            ("demo_lookup_transport", "Read sample Sydney transport for the parallel-tools demo.", "Sample transport: trains every 10 minutes; ferry every 30 minutes.")
        ] {
            try await runtime.replaceTool(.init(name: name, description: description,
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                supportsParallelExecution: true), executor: .init { invocation, _ in
                    // Simulates independent reads so overlap is visible in the UI.
                    try await Task.sleep(for: .milliseconds(1_500))
                    return .success(invocation: invocation, text: output)
                })
        }
    }

    func runParallelToolsDemo() async {
        guard session != nil, canReconfigureRuntime else { return }
        guard await createThreadInternal(title: "Parallel Lookups", personaStack: nil) != nil else { return }
        await sendMessageInternal("Use demo_lookup_weather and demo_lookup_transport together to plan a short Sydney outing. These are independent sample lookups; request both in the same batch. Then summarize the sample results.")
    }
}
