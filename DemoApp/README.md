# Assistant Runtime Demo App

This folder contains the iOS app entrypoint for exercising the embedded assistant runtime.

## Open the app in Xcode

Run:

```sh
ruby scripts/generate_demo_app_project.rb
open AssistantRuntimeDemoApp.xcodeproj
```

## What the app does

- launches a SwiftUI chat screen
- signs in with ChatGPT using `ASWebAuthenticationSession`
- creates or resumes a thread
- lets you type and send a user request
- streams assistant output into the UI
- shows approval prompts before running a host-defined demo tool

## Files

- `DemoApp/AssistantRuntimeDemoApp/AssistantRuntimeDemoApp.swift`
- `DemoApp/AssistantRuntimeDemoApp/Info.plist`
- `Sources/AssistantRuntimeDemo/AssistantDemoView.swift`
- `Sources/AssistantRuntimeDemo/AssistantDemoViewModel.swift`
- `Sources/AssistantRuntimeDemo/AssistantDemoRuntimeFactory.swift`
