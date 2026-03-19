# TODO

## Status

- [x] Audit `openai/codex` for reusable auth, session, event, approval, and host-boundary primitives
- [x] Write extraction/design docs under `docs/ios-assistant-runtime/`
- [x] Scaffold `AssistantRuntimeKit` package modules
- [x] Build a mock end-to-end tool approval and execution flow
- [x] Add package tests and verify the scaffold builds

## In Progress

- [ ] Initialize local git history and checkpoint the current scaffold
- [ ] Replace the mock-only gaps with a production-oriented path where possible

## Remaining Work To Reach The Original Goal

- [ ] Implement a real iOS-native ChatGPT auth adapter based on Codex auth flow concepts
- [ ] Replace desktop localhost login assumptions with `ASWebAuthenticationSession`
- [ ] Add a production-oriented backend transport interface implementation beyond the in-memory demo backend
- [ ] Decide and implement the minimum real assistant thread/message backend protocol for the iOS runtime
- [ ] Add SwiftUI demo bindings that visibly stream responses and present approvals
- [ ] Persist runtime thread/message state across launches in a host-appropriate way
- [ ] Expand tests around auth restoration, approval denial, thread resume, and tool result round-trips
- [ ] Reassess whether the runtime truly satisfies:
  - [ ] real ChatGPT sign-in
  - [ ] secure session persistence
  - [ ] create thread
  - [ ] resume thread
  - [ ] send user message
  - [ ] stream assistant output
  - [ ] register app-defined tool
  - [ ] require approval
  - [ ] execute approved tool and feed the result back into the thread

## Risks / Unknowns

- Real ChatGPT sign-in may require assumptions about upstream OAuth behavior that need careful validation.
- A truly non-mock runtime backend may require either:
  - a direct network protocol compatible with ChatGPT-authenticated Codex services, or
  - a thin service layer we define and document.
- The current repo is a Swift package, not yet an Xcode demo app project.
