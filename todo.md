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
- [x] Add a runnable iOS demo app target for live validation
- [x] Add a device-code ChatGPT sign-in path for iOS when redirect-based auth is rejected upstream
- [ ] Validate the live path in a real iOS app session

## Remaining Work To Reach The Original Goal

- [ ] Verify the iOS ChatGPT sign-in flow against a live account on-device
- [ ] Verify the ChatGPT Codex responses transport against a live account/session
- [x] Add SwiftUI demo bindings that visibly stream responses and present approvals
- [x] Persist runtime thread/message state across launches in a host-appropriate way
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

- The browser OAuth flow from Codex appears to be bound to localhost redirects; the demo app now uses a Codex-style device-code flow on iOS instead.
- The backend transport can be implemented directly against `chatgpt.com/backend-api/codex/responses`, but live verification still depends on a real ChatGPT account session.
- The demo app project is generated and buildable, but still needs one real sign-in/send run to prove the live path end-to-end.
