# TODO

## Status

- [x] Audit `openai/codex` for reusable auth, session, event, approval, and host-boundary primitives
- [x] Write extraction/design docs under `docs/ios-assistant-runtime/`
- [x] Scaffold `AssistantRuntimeKit` package modules
- [x] Build a mock end-to-end tool approval and execution flow
- [x] Add package tests and verify the scaffold builds

## In Progress

- [x] Initialize local git history and checkpoint the current scaffold
- [x] Replace the mock-only gaps with a production-oriented path where possible
- [x] Land a real Apple-platform ChatGPT OAuth adapter
- [x] Land a ChatGPT Codex responses transport with streamed tool-call continuation
- [ ] Validate the live path in a real iOS app session

## Remaining Work To Reach The Original Goal

- [ ] Verify the Apple-platform OAuth flow against a live ChatGPT sign-in on-device
- [ ] Verify the ChatGPT Codex responses transport against a live account/session
- [ ] Add SwiftUI demo bindings that visibly stream responses and present approvals
- [ ] Persist runtime thread/message state across launches in a host-appropriate way
- [ ] Expand tests around auth restoration, approval denial, thread resume, and tool result round-trips
- [ ] Reassess whether the runtime truly satisfies:
  - [x] real ChatGPT sign-in implementation path exists
  - [x] secure session persistence
  - [x] create thread
  - [x] resume thread
  - [x] send user message
  - [x] stream assistant output
  - [x] register app-defined tool
  - [x] require approval
  - [x] execute approved tool and feed the result back into the thread
  - [ ] live on-device validation completed

## Risks / Unknowns

- Real ChatGPT sign-in may still require one or two live validation adjustments around callback configuration or originator handling.
- The backend transport can be implemented directly against `chatgpt.com/backend-api/codex/responses`, but live verification still depends on a real ChatGPT account session.
- The current repo is a Swift package, not yet a full Xcode demo app project.
