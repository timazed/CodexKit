# iOS Assistant Runtime Extraction Audit

## Scope

Audit source: `openai/codex` from GitHub (`main`, inspected at `903660edba6e1ecfd7c9b1782105be4ebf0e02a7`).

Goal: identify the minimum reusable Codex pieces for an iOS-native embedded assistant runtime that keeps:

- ChatGPT authentication/session handling
- thread and turn lifecycle
- streaming event delivery
- approvals
- resumable conversations
- host-defined tool execution

while removing:

- CLI and TUI concerns
- shell and subprocess execution
- repo editing
- git/worktree flows
- patch generation/application
- desktop callback assumptions

## Best Reuse Candidates

### 1. Authentication and Account State

Primary upstream references:

- `codex-rs/core/src/auth.rs`
- `codex-rs/core/src/auth/storage.rs`
- `codex-rs/login/src/server.rs`
- `codex-rs/login/src/device_code_auth.rs`
- `codex-rs/app-server-protocol/src/protocol/v2.rs`
- `codex-rs/app-server/src/message_processor.rs`
- `codex-rs/app-server/src/codex_message_processor.rs`

Reusable ideas:

- `AuthManager` is the real center of gravity, not the CLI login command.
- Codex distinguishes three auth shapes:
  - `ApiKey`
  - `Chatgpt`
  - `ChatgptAuthTokens`
- `AuthManager` already models externally managed ChatGPT tokens through `ExternalAuthRefresher`, which is exactly the right adaptation seam for iOS.
- Token refresh recovery is already state-machine based:
  - guarded reload
  - refresh-token flow
  - externally managed token refresh callback
- `account/chatgptAuthTokens/refresh` in app-server is a strong host/runtime boundary for externally managed mobile auth.

What ports cleanly:

- auth state model
- refresh lifecycle
- external-token bridge concept
- account metadata extraction (`email`, `plan_type`, `chatgpt_account_id`)
- logout/invalidation semantics

What does not port directly:

- localhost callback server in `login/src/server.rs`
- browser launch assumptions
- terminal-oriented device-code UX
- CLI/keyring storage choices as-is

### 2. Thread and Turn Lifecycle

Primary upstream references:

- `codex-rs/core/src/thread_manager.rs`
- `codex-rs/core/src/codex_thread.rs`
- `codex-rs/core/src/rollout/recorder.rs`
- `codex-rs/core/src/state/session.rs`
- `codex-rs/core/src/state/turn.rs`
- `codex-rs/app-server-protocol/src/protocol/v2.rs`
- `codex-rs/app-server/src/thread_state.rs`
- `codex-rs/app-server/src/thread_status.rs`
- `codex-rs/state/src/runtime/threads.rs`

Reusable ideas:

- separate thread creation/resume/fork concepts
- per-thread runtime status
- per-turn pending state for approvals, user input, and tool results
- lightweight persisted thread metadata separate from active in-memory execution
- event-sourced rollout/history as the source for resume/read

What ports cleanly:

- `Thread` / `Turn` / `Item` layering
- resumable thread identity
- active turn pending maps for:
  - approvals
  - request-user-input
  - request-permissions
  - dynamic tool results
- loaded vs active vs waiting states

What must be simplified for iOS:

- no fork/worktree/repo-oriented thread source semantics
- no cwd/git coupling in thread identity
- no shell snapshot or background terminal cleanup paths
- no reliance on rollout files containing repo/file edit events

### 3. Streaming Event Model

Primary upstream references:

- `codex-rs/protocol/src/protocol.rs`
- `codex-rs/app-server-protocol/src/protocol/common.rs`
- `codex-rs/app-server-protocol/src/protocol/v2.rs`
- `sdk/typescript/src/events.ts`
- `sdk/typescript/src/thread.ts`

Reusable ideas:

- Codex already exposes an event-driven runtime.
- The strongest portable pattern is:
  - `thread/started`
  - `turn/started`
  - item lifecycle events
  - assistant text deltas
  - final completion / failure events
- The TypeScript SDK shows the minimal consumer-facing shape better than the full CLI/runtime internals.

What ports cleanly:

- streamed assistant deltas
- structured completion and failure events
- turn-scoped usage
- thread status updates
- item-oriented lifecycle hooks for tools and approvals

What should be dropped or flattened:

- shell output delta events
- terminal interaction events
- file change diff events
- collab/sub-agent events
- review mode items

### 4. Approval Model

Primary upstream references:

- `codex-rs/protocol/src/approvals.rs`
- `codex-rs/protocol/src/request_permissions.rs`
- `codex-rs/protocol/src/request_user_input.rs`
- `codex-rs/app-server-protocol/src/protocol/v2.rs`
- `codex-rs/app-server/src/thread_status.rs`

Reusable ideas:

- approvals are modeled as structured requests with stable IDs
- active thread state explicitly tracks “waiting on approval” and “waiting on user input”
- approvals are not tied to one UI; they are runtime pauses resolved by the host
- there is already a generic shape for user elicitation and dynamic tool callbacks

What ports cleanly:

- approval request ID
- structured reason/message payload
- approve/deny result envelope
- suspension/resume of an active turn while waiting for host input

What should not be ported:

- shell-specific review decisions
- execpolicy amendment mechanics
- filesystem/network sandbox amendment details
- guardian sub-agent approval reviewer flow

### 5. Host Integration Boundary

Primary upstream references:

- `codex-rs/app-server/README.md`
- `codex-rs/app-server-protocol/src/protocol/common.rs`
- `codex-rs/app-server-protocol/src/protocol/v2.rs`
- `codex-rs/app-server/src/message_processor.rs`
- `codex-rs/app-server/src/dynamic_tools.rs`
- `codex-rs/app-server/src/bespoke_event_handling.rs`

Reusable ideas:

- app-server already treats the UI/app as a host that:
  - authenticates
  - presents approvals
  - answers elicitation
  - executes dynamic tools
  - receives streamed notifications
- `DynamicToolCallParams` and `DynamicToolCallResponse` are a direct model for app-defined tools.
- `ChatgptAuthTokensRefresh` is a direct model for host-owned auth refresh.

This is the strongest extraction seam in the whole repository.

## Modules to Reuse by Concept

### Keep as conceptual source material

- `core/src/auth.rs`
- `core/src/auth/storage.rs`
- `app-server-protocol/src/protocol/common.rs`
- `app-server-protocol/src/protocol/v2.rs`
- `protocol/src/protocol.rs`
- `protocol/src/dynamic_tools.rs`
- `protocol/src/approvals.rs`
- `thread_manager.rs`
- `codex_thread.rs`
- `rollout/recorder.rs`
- `state/session.rs`
- `state/turn.rs`
- `state/src/runtime/threads.rs`

### Keep only as adaptation reference, not direct code

- `login/src/server.rs`
- `login/src/device_code_auth.rs`

Reason:

- the login flow is useful
- the transport assumptions are not

### Fence off entirely

- `cli/`
- `tui/`
- `exec/`
- `exec-server/`
- `shell-command/`
- `shell-escalation/`
- `apply-patch/`
- `file-search/`
- `linux-sandbox/`
- `windows-sandbox-rs/`
- repo/git helpers and worktree flows
- `agent/control` sub-agent lifecycle
- review-specific flows

## iOS-Incompatible Dependencies and Assumptions

### Desktop auth assumptions

- localhost callback HTTP server
- implicit browser launching from runtime
- device-code flow presented as terminal copy
- keyring/file fallback policy oriented around CLI home directories

### Coding-agent assumptions

- shell approval payloads
- command execution events
- filesystem write diffs
- repo metadata in thread lifecycle
- sandbox escalation semantics designed for shell commands

### Host/process assumptions

- JSON-RPC over stdio / websocket
- long-running process that owns all runtime behavior
- desktop filesystem visibility beyond app sandbox

## Minimum Extraction Set for an iOS Runtime

This is the smallest viable set worth carrying over.

### A. Auth/session core

Port:

- auth state model
- secure persistence abstraction
- refresh/invalidation lifecycle
- external auth refresher callback

Do not port:

- desktop login server implementation

### B. Thread runtime core

Port:

- thread identity
- turn lifecycle
- active pending maps for approvals/tools
- lightweight thread persistence

Do not port:

- repo-specific source metadata beyond optional opaque host metadata

### C. Streaming event core

Port:

- thread started/status changed
- turn started/completed/failed
- assistant text delta
- message committed
- tool call started/completed
- approval requested/resolved

Drop:

- shell/file-diff/terminal specific items

### D. Tool bridge core

Port:

- dynamic tool registration shape
- invocation routing
- result envelope

Drop:

- any built-in tool implementations

### E. Approval bridge core

Port:

- structured approval request
- host-mediated decision
- turn pause/resume semantics

Drop:

- execpolicy/network sandbox amendment payloads from the core iOS API

## Recommended Extraction Strategy

1. Re-implement the runtime in Swift rather than trying to embed Rust wholesale.
2. Treat Codex as the protocol and lifecycle reference implementation.
3. Preserve the host/runtime boundaries from app-server.
4. Replace desktop auth with iOS-native auth UX and Keychain persistence.
5. Keep the event vocabulary intentionally smaller than upstream Codex.

## Bottom Line

The most reusable pieces of Codex for iOS are not the CLI or the agent executor. They are:

- `AuthManager`’s ChatGPT auth and refresh model
- the app-server host/runtime boundary
- the thread/turn/item lifecycle
- the streaming notification vocabulary
- the dynamic tool and approval callback shapes

That is the correct minimum extraction set for an iOS-native assistant runtime.
