# Runtime progress, tools, and turn control

[Documentation index](index.md) · [CodexKit](../README.md)

CodexKit supports these Codex runtime concepts natively in Swift. First-class
question/form presentation remains host-owned.

## GPT-6 Astra

```swift
let backend = CodexResponsesBackend(configuration: .init(model: .gpt6Astra))
let threadConfiguration = AgentThreadConfiguration(model: .gpt6Astra)
```

The bundled Astra identifier is `gpt-6-astra`. Its default reasoning effort is
`.low`, and supported efforts are `.low`, `.medium`, `.high`, `.extraHigh`, `.max`,
and `.ultra`. As with the existing models, `.ultra` is sent as `max` to inference;
it does not add agent delegation to CodexKit. The bundled context-window value
is 272,000 tokens, matching upstream's default window, rather than its optional
larger maximum. Model selection does not grant account access.

## Stream completion

The built-in Responses backend requires `response.completed`. A stream that
ends without that event throws `responses_stream_disconnected`. Existing retry
policy still decides whether a retry is safe: emitted text, progress, structured
output, committed assistant messages, and tool calls prevent automatic replay.
Before output, a retry sends the same POST again; it does not resume the original
provider response. See the [recovery investigation](response-recovery-investigation-2026-09-10.md).

The configured `streamIdleTimeout` is also applied to the Responses URL request.
Custom `AgentBackend` implementations retain their existing completion behavior.

## Parallel tools

Tools execute serially by default. Opt in for independent tools:

```swift
let lookup = ToolDefinition(
    name: "lookup_product",
    description: "Read product details.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([:])
    ]),
    supportsParallelExecution: true
)
```

`AgentRuntime.Configuration.maximumParallelToolCalls` bounds concurrent host calls
within each turn's round; the default is four, and runtime values below one are
clamped to one. It is not a semaphore shared by all active threads. A skill's
`maximumParallelToolCalls` may narrow that ceiling (one forces serial execution)
but cannot increase it. Tools opting in must be safe for overlapping invocations,
including multiple invocations of the same tool.

Skill constraints do not disable parallelism. The runtime resolves active skills
once per turn, validates and reserves calls in provider order, and plans bounded
execution waves before launching tools. Serial tools and approval-gated calls are
exclusive barriers. Exact-prefix sequence entries also form barriers: with
`toolSequence: ["a", "b"]`, the response `[a, b, x, y]` can run as
`[a] -> [b] -> [x, y]` in one round. `[a, x, b]` rejects `x`; the planner does not
reorder or defer invalid calls. See [policy composition](personas-and-skills.md#execution-policy-composition-and-budgets).

The Responses backend gathers all host calls until `response.completed` and emits
`AgentBackendEvent.toolRoundRequested(AgentToolRound)`, regardless of serial or
parallel tool declarations. A round is one model response requesting one or more
host calls. Four calls in one response consume one round, even if execution uses
four serial waves. A response without host calls consumes zero rounds. Transport
retries are not new tool rounds, and an incomplete response executes no host calls.
The existing retry safety checks still disallow replay after observing tool activity.

Custom backends should emit one nonempty `AgentToolRound` per model response, with
a unique round ID and unique invocation IDs in provider order. Legacy
`toolCallRequested` and `toolCallsRequested` remain accepted; each event declares a
complete round. Do not split one response into several legacy events when using
round limits. Empty rounds, duplicate round IDs, and duplicate invocation IDs are
protocol errors. No additional public parallel-execution lifecycle is introduced.

Tool lifecycle events identify individual invocations and can start and finish in
execution order. Audit history records requests in provider order and results
chronologically. Provider results and model-visible tool context are invocation
ordered, including persisted/restored context and compaction input. Completed
results are saved individually; a slower sibling does not delay their audit record.
Replaying a persisted invocation returns its original outcome without executing
the tool again, even if a later skill policy is narrower.
The thread's pending snapshot represents one outstanding wait; use lifecycle
events to display concurrent calls. Interrupting a turn cancels active tasks and
result/approval waiters; host executors must cooperate with cancellation. Completed
external side effects remain the application's responsibility.

Policy rejection produces a normal failed `ToolResultEnvelope` with a structured
`failure` containing a stable string code, message, and optional details. Codes
include `tool_budget_exceeded`, `tool_round_budget_exceeded`, `tool_not_allowed`,
`tool_sequence_violation`, `tool_approval_denied`, `tool_unknown`, and
`tool_execution_failed`, and `tool_cancelled` for an executor that cancels its own
operation while the turn remains active. The Responses adapter sends structured failure information
alongside the textual output. Audit persistence and lifecycle events use the same
finalization path for policy rejection, approval denial, and executed tools.
Cancellation uses interrupted-turn semantics rather than submitting results to an
interrupted provider. Unknown/duplicate result submissions remain protocol errors.

Every tool result must preserve the requested invocation ID and tool name. If a
custom executor returns a different identity, the runtime records a failed result
for the original call before saving history or publishing the result.

Direct Responses backend callers must submit one result per announced call.
Out-of-order results for an announced batch are supported. Unknown, duplicate,
mismatched, and late submissions throw `AgentRuntimeError` with code
`invalid_tool_result`, without replacing a previously accepted result. Completion
and cancellation release outstanding result buffers and waiters. The shared
`AgentTurnStream` API also checks that the envelope ID matches its submission ID;
custom backends remain responsible for tracking their own pending calls.

All nonempty tool-result text blocks are joined in order with blank-line separators
for provider requests, fallback replies, and compaction context. `primaryText`
continues to expose the first block for concise previews.

Remote tool images require a successful HTTP response and a decodable PNG, JPEG,
GIF, WebP, HEIC, or HEIF payload. The image bytes determine the media type, even if
the server omits or mislabels it. HTTP errors, HTML, and truncated image data are
omitted from attachments. Existing download byte limits and cancellation still
apply. Validation leaves accepted bytes unchanged; SQLite and Realm retain
attachment references while the original bytes remain in disk blobs.

## Progress and message phases

Both ordinary and structured streams expose:

- `.progress(AgentTurnProgress)` for message start/completion, reasoning-summary
  deltas, and web-search activity.
- `.rateLimitsUpdated([AgentRateLimitSnapshot])` for account limit changes.
- `.turnInterrupted(AgentTurnInterruption)` for cancellation.

`AgentMessage.phase` distinguishes `.commentary` and `.finalAnswer` when the
provider supplies them. It is optional, persists across all storage adapters,
and preserves unknown future phase strings. Existing `assistantMessageDelta`
events remain answer-text events; reasoning summaries are separate.

Enable provider reasoning summaries with
`CodexResponsesBackendConfiguration(enableReasoningSummaries: true)`. The
backend requests `reasoning.summary = "auto"`; events depend on what the model
actually supplies. Raw private reasoning is not exposed.

`CodexKitUI.AgentRuntimeStore` exposes `latestProgress` and `rateLimits`, and
provides `steer(_:)` and `interrupt()` helpers for the selected thread.

## Model discovery

```swift
let catalog = try await runtime.listModels()
let choices = catalog.visibleModels

// Require a successful network refresh:
let refreshed = try await runtime.listModels(policy: .refresh)

// Avoid network I/O:
let offline = try await runtime.listModels(policy: .cachedOnly)
```

Discovery fetches the Codex `/models` catalog with the signed-in session.
It returns model identifiers, descriptions, reasoning efforts, modalities,
context windows, visibility, and parallel-tool capability where supplied.
Unknown model identifiers and reasoning efforts remain usable.

The backend keeps an in-memory cache per account with a five-minute freshness
window and ETag revalidation. `.preferCached` uses a fresh cache, otherwise
refreshes, falling back to stale or bundled metadata for non-authentication
failures. `.refresh` reports failures; authentication failures always propagate.
The snapshot exposes `source`, `fetchedAt`, and `isStale`. This cache lasts for
the backend instance's lifetime. Refreshing model metadata also updates its
context-window lookup for the selected account.

The discovery request's `client_version` defaults to `0.153.0`; override
`modelClientVersion` in backend configuration when targeting another server
compatibility version. Backends without `AgentBackendModelDiscovering` return
the bundled catalog through the runtime facade.

## Account limits

```swift
let limits = try await runtime.rateLimits()
for limit in limits {
    if let window = limit.primary {
        print(window.remainingPercent, window.resetsAt as Any)
    }
}
```

These are the latest observed snapshots for the signed-in account, not a new
quota request. The backend reads limits from HTTP headers, including error
responses, and `codex.rate_limits` events. Multiple metered limit families are
kept separately. Primary/secondary windows and credit information are optional;
missing values mean unavailable. `AgentUsage` continues to describe turn token
usage separately.

## Steering and interruption

Capture the turn ID from `.turnStarted` or `runtime.activeTurnID(in:)`:

```swift
try await runtime.steer(
    "Focus on recent results.",
    in: threadID,
    expectedTurnID: turnID
)

try await runtime.interrupt(in: threadID, expectedTurnID: turnID)
```

Steering accepts text and optional images. It queues input for the next model
request within the same turn, including an additional request if the current
response would otherwise finish. It cannot change an HTTP response already
being generated. Acceptance is serialized with the backend's completion
decision; stale turn IDs and completed turns are rejected. The user message is
committed when the backend consumes it. Model, persona, and response-format
overrides still belong to a new turn.

A thread accepts one persistent active turn at a time. A second `stream` call
throws `thread_busy`; ephemeral requests remain independent. Custom backends
can opt into steering and explicit interruption with the extended
`AgentTurnStream` initializer. Steering unsupported by a backend throws
`steering_unsupported`.

Interruption releases built-in pending tool waits and cancels the turn task.
The approval inbox also cancels pending presentation. Host executors and custom
approval presenters should cooperate with task cancellation. An interrupted
turn records `.interrupted` as its latest turn status, clears pending state,
returns the thread to `.idle`, emits `.turnInterrupted`, and ends the stream
with `CancellationError`. It does not emit successful completion or capture
completion memory attribution. Already completed external actions are not undone.

## Demo walkthrough

The checked-in iOS demo uses account discovery for its model picker, including
Astra when available, and displays catalog provenance and reported account limits.
Its ordinary chat screen shows provider progress and message phases, with
**Add to turn** and **Stop** controls. **Parallel Lookups** requests two independent
sample tools under a skill limiting execution to those tools, two calls in one
round, and at most two concurrent calls. Both demos display observed concurrency
so the skill's limits can be compared with execution. The interactive backend enables
reasoning summaries; model output still determines whether summaries arrive.

See [Try the runtime features](../DemoApp/README.md#try-the-runtime-features) for
steps, expected behavior, and the distinction between live account data and fixed
sample tool outputs.

## Migration

Update exhaustive switches for the added event cases, `AgentTurnStatus.interrupted`,
and `AgentSystemEventType.turnInterrupted`. Cancellation now produces interrupted
status rather than failed status. Existing tools stay serial unless explicitly
opted in, and existing stored messages decode with `phase == nil`.

## Turn-effective hosted web search

Backend configuration remains the default and upper capability bound:

```swift
let backend = CodexResponsesBackend(configuration: .init(
    enableWebSearch: true,
    webSearchPolicy: .init(mode: .live, allowedDomains: ["example.com"])
))
```

`enableWebSearch: false` always disables search, including when a skill or request
specifies `.live`. With the switch enabled and no policy, existing live-search
behavior is preserved. A backend policy can narrow this to cached or indexed
search and a domain allowlist. Skills use `executionPolicy.webSearch`; a host can
also supply `Request(text: "...", webSearch: ...)`. These restrictions intersect
and apply to every provider pass within the turn, including after host-tool
results and request retries. Later turns resolve their own policies.

Modes compose from most to least restrictive: `disabled`, `cached`, `indexed`,
`live`. Disabled omits the hosted tool. Cached sends `external_web_access: false`;
indexed sends `external_web_access: true` plus `indexed_web_access: true`; live
sends `external_web_access: true`. Indexed retrieval is gated by the search index.
These fields and the domain-filter shape follow the
[upstream Codex hosted-tool implementation](https://github.com/openai/codex/blob/40eac3ce8a0c10cbcb9db910d529355eb2f8fc09/codex-rs/core/src/tools/hosted_spec.rs)
and its
[schema tests](https://github.com/openai/codex/blob/40eac3ce8a0c10cbcb9db910d529355eb2f8fc09/codex-rs/core/src/tools/hosted_spec_tests.rs).
Remote compaction and tool-free structured recovery do not enable hosted search.

`allowedDomains: nil` adds no domain restriction. `[]`, or a disjoint intersection,
disables search; it never becomes unrestricted search. Allowlist entries cover
subdomains, so intersecting `example.com` with `docs.example.com` retains
`docs.example.com`. Entries are trimmed, lowercased, deduplicated and stripped of
one trailing DNS dot. Use at most 100 ASCII/punycode DNS names. URLs, ports, paths,
wildcards and IP addresses are rejected. Filters are emitted as
`filters.allowed_domains`, never approximated in prompt text. These are hosted
search-result filters, not a sandbox for host tools, connectors or other network
traffic. See [OpenAI's search documentation](https://developers.openai.com/api/docs/guides/tools-web-search).

Custom backends and wrappers advertise `AgentBackend.webSearchCapabilities` and
must honor the resolved `Request.webSearch`. The default `nil` means enforcement
is unadvertised: applying a search constraint fails with
`unsupported_backend_capability`. Advertised backends reject unsupported modes or
domain restrictions rather than silently dropping them. Wrappers should forward
both capability information and the request. Capability declarations do not grant
provider/account access; a provider can still reject unsupported requests.

Host `maxToolCalls`, `maxToolRounds`, and per-tool limits do **not** budget hosted
search. CodexKit cannot intercept those provider-executed calls before execution.
For strict search-call budgets, expose search as a host-defined `ToolDefinition`.
