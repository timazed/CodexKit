# CodexKit Demo App

This folder contains the checked-in iOS example app for exercising the `CodexKit` embedded agent runtime. The package itself supports both iOS and macOS; this demo remains the iOS sample app.

## Open the app in Xcode

Run:

```sh
open DemoApp/AssistantRuntimeDemoApp.xcodeproj
```

The Xcode project is the source of truth for the demo app. Edit it directly in Xcode and commit project changes normally.

## What the app does

- launches a SwiftUI chat screen
- includes a `Health Coach` tab for step-goal tracking
- signs in with ChatGPT using either device code or browser OAuth
- creates or resumes a thread
- lets you type and send a user request
- lets you attach a photo from the library and send it with or without text
- renders attached user images in the transcript
- streams assistant output into the UI
- demonstrates live Combine observation of thread, message, summary, context-state, and context-usage updates
- lets you rename the active thread from the thread detail screen using `setTitle(_:for:)`
- includes a thread-level `Context Compaction` card so you can compact effective prompt state without removing visible transcript history
- supports approval prompts for host-defined tools that opt into `requiresApproval`
- demonstrates thread-pinned personas and one-turn persona overrides
- includes first-class framework skill examples for `health_coach` and `travel_planner`
- demonstrates skill execution policy with skill-specific tool constraints
- includes a one-tap `Run Skill Policy Probe` action that runs the same tool-focused prompt in normal vs skill threads
- showcases runtime APIs that can load persona/skill definitions from local or remote files
- includes a `Show Resolved Instructions` debug toggle so you can inspect per-turn compiled instructions
- enables Responses web search in the checked-in demo configuration
- reads HealthKit step totals (with permission), tracks a daily goal, and schedules local reminder notifications
- supports switchable coaching tone (`Hardcore Personal` or `Firm Coach`)
- proactively generates AI coach feedback in a dedicated persona-pinned thread as steps, goal, or tone change

The checked-in demo registers deterministic skill-specific tools (`health_coach_fetch_progress` and `travel_planner_build_day_plan`), and the Xcode console logs when each tool is requested, executed, and completed so you can verify tool usage during a run.

The demo currently focuses on text plus photo input flows. Built-in image generation is not enabled in the checked-in app configuration.

The demo uses the new configuration-first surface:

- `AgentRuntime.Configuration`
- `ChatGPTAuthProvider`
- `KeychainSessionSecureStore`
- `CodexResponsesBackend`
- `GRDBRuntimeStateStore`
- `ApprovalInbox` and `DeviceCodePromptCoordinator` from `CodexKitUI`

The app links `CodexKit` and `CodexKitUI` from the repo's local `Package.swift`, so it exercises the same SPM integration path a host app would use. Runtime state is stored in `runtime-state.sqlite`, memory is stored in `memory.sqlite`, and the GRDB-backed runtime store will import an older sibling `runtime-state.json` file automatically on first launch if one exists.

The checked-in demo enables context compaction in automatic mode. In a thread detail screen, the `Context Compaction` card shows:

- visible transcript token usage
- effective prompt token usage
- estimated context window fullness when available
- compaction generation
- last compaction reason/time
- a `Compact Context Now` action for manual testing

The same thread detail screen also includes an `Observation Demo` card. It subscribes to:

- `observeThread(id:)`
- `observeMessages(in:)`
- `observeThreadSummary(id:)`
- `observeThreadContextState(id:)`
- `observeThreadContextUsage(id:)`

Use that card to verify that:

- local title changes propagate immediately through `setTitle(_:for:)`
- new messages appear from the observation stream without a manual refresh
- context compaction updates the observed context state live
- effective prompt usage updates live in estimated tokens

## Files

- `DemoApp/AssistantRuntimeDemoApp/AssistantRuntimeDemoApp.swift`
- `DemoApp/AssistantRuntimeDemoApp/Info.plist`
- `DemoApp/AssistantRuntimeDemoApp.xcodeproj`
- `DemoApp/AssistantRuntimeDemoApp/Shared/AgentDemoView.swift`
- `DemoApp/AssistantRuntimeDemoApp/Shared/AgentDemoViewModel.swift`
- `DemoApp/AssistantRuntimeDemoApp/Shared/AgentDemoRuntimeFactory.swift`
- `Sources/CodexKitUI/AgentRuntimeStore.swift`
- `Sources/CodexKitUI/ApprovalInbox.swift`
- `Sources/CodexKitUI/DeviceCodePromptCoordinator.swift`
