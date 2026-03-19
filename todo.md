# TODO

## Status

- [x] Audit `openai/codex` for reusable auth, session, event, approval, and host-boundary primitives
- [x] Write extraction/design docs under `docs/ios-assistant-runtime/`
- [x] Scaffold `CodexKit` package modules
- [x] Build a mock end-to-end tool approval and execution flow
- [x] Add package tests and verify the scaffold builds

## In Progress

- [x] Initialize local git history and checkpoint the current scaffold
- [x] Replace the mock-only gaps with a production-oriented path where possible
- [x] Land a real Apple-platform ChatGPT OAuth adapter
- [x] Land a ChatGPT Codex responses transport with streamed tool-call continuation
- [x] Add a runnable iOS demo app target for live validation
- [x] Add a device-code ChatGPT sign-in path for iOS when redirect-based auth is rejected upstream
- [x] Fix iOS demo app compatibility-mode letterboxing by declaring a launch screen
- [x] Enforce live-backend-safe tool names and update the demo tool identifier
- [x] Align direct auth requests more closely with Codex headers and token wire format
- [x] Rename the Swift package and primary module surface to `CodexKit`
- [x] Validate the live path in a real iOS app session
- [x] Refactor the public SDK surface to a consistent `Agent*` vocabulary
- [x] Replace `HostBridge` with a configuration-based `AgentRuntime` entry point
- [x] Add an optional UI-facing helper target for SwiftUI integration
- [x] Hide low-level runtime plumbing from the public surface where possible
- [x] Migrate docs, examples, tests, and demo app usage to the simplified API

## Remaining Work To Reach The Original Goal

- [x] Verify the iOS ChatGPT sign-in flow against a live account on-device
- [x] Verify the ChatGPT Codex responses transport against a live account/session
- [x] Add SwiftUI demo bindings that visibly stream responses and present approvals
- [x] Persist runtime thread/message state across launches in a host-appropriate way
- [x] Expand tests around the renamed API surface, configuration setup, approval denial, thread resume, and tool result round-trips
- [x] Reassess the final public API for long-term SDK ergonomics after the rename
- [x] Reassess whether the runtime truly satisfies:
  - [x] real ChatGPT sign-in implementation path exists
  - [x] secure session persistence
  - [x] create thread
  - [x] resume thread
  - [x] send user message
  - [x] stream assistant output
  - [x] register app-defined tool
  - [x] require approval
  - [x] execute approved tool and feed the result back into the thread
  - [x] live on-device validation completed

## Risks / Unknowns

- The browser OAuth flow from Codex appears to be bound to localhost redirects; the recommended iOS path remains the Codex-style device-code flow.
- The public API is now intentionally cleaner and more opinionated, but any future rename away from `Agent*` would be another breaking change.
