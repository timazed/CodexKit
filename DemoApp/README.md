# CodexKit Demo App

This folder contains the checked-in iOS example app for exercising the `CodexKit` embedded agent runtime.

## Open the app in Xcode

Run:

```sh
open DemoApp/AssistantRuntimeDemoApp.xcodeproj
```

The Xcode project is the source of truth for the demo app. Edit it directly in Xcode and commit project changes normally.

## What the app does

- launches a SwiftUI chat screen
- signs in with ChatGPT using either device code or browser OAuth
- creates or resumes a thread
- lets you type and send a user request
- lets you attach a photo from the library and send it with or without text
- renders attached user images in the transcript
- streams assistant output into the UI
- shows approval prompts before running a host-defined demo tool
- demonstrates thread-pinned personas and one-turn persona overrides
- enables Responses web search in the checked-in demo configuration

The checked-in demo tool is a deterministic shipping quote tool, and the Xcode console logs when the tool is requested, executed, and completed so you can verify tool usage during a run.

The demo uses the new configuration-first surface:

- `AgentRuntime.Configuration`
- `ChatGPTAuthProvider`
- `KeychainSessionSecureStore`
- `CodexResponsesBackend`
- `FileRuntimeStateStore`
- `ApprovalInbox` and `DeviceCodePromptCoordinator` from `CodexKitUI`

The app links `CodexKit` and `CodexKitUI` from the repo's local `Package.swift`, so it exercises the same SPM integration path a host app would use.

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
