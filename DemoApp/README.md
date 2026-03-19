# CodexKit Demo App

This folder contains the iOS app entrypoint for exercising the `CodexKit` embedded assistant runtime.

## Open the app in Xcode

Run:

```sh
ruby scripts/generate_demo_app_project.rb
open AssistantRuntimeDemoApp.xcodeproj
```

If you want a custom bundle identifier for device installs, generate the project with:

```sh
CODEXKIT_DEMO_BUNDLE_ID=your.bundle.id ruby scripts/generate_demo_app_project.rb
```

## What the app does

- launches a SwiftUI chat screen
- signs in with ChatGPT using the current iOS-compatible auth flow
- creates or resumes a thread
- lets you type and send a user request
- streams assistant output into the UI
- shows approval prompts before running a host-defined demo tool

## Files

- `DemoApp/AssistantRuntimeDemoApp/AssistantRuntimeDemoApp.swift`
- `DemoApp/AssistantRuntimeDemoApp/Info.plist`
- `Sources/CodexKitDemo/AssistantDemoView.swift`
- `Sources/CodexKitDemo/AssistantDemoViewModel.swift`
- `Sources/CodexKitDemo/AssistantDemoRuntimeFactory.swift`
