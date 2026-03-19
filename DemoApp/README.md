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
- signs in with ChatGPT using the current iOS-compatible auth flow
- creates or resumes a thread
- lets you type and send a user request
- streams assistant output into the UI
- shows approval prompts before running a host-defined demo tool
- enables Responses web search in the checked-in demo configuration

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
