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
policy still decides whether a retry is safe: committed assistant messages and
executed tool calls prevent replay. Uncommitted text deltas retain their existing retry behavior.

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

`AgentRuntime.Configuration.maximumParallelToolCalls` bounds each batch; the
default is four, and values below one are clamped to one. The Responses backend
requests parallel calls when at least one registered tool opts in. It collects
the response's calls and emits `AgentBackendEvent.toolCallsRequested`.

The runtime executes consecutive eligible calls together. A serial tool or an
approval-gated tool is a barrier: preceding work finishes before it runs, and
following work waits for it. Approval-gated tools remain exclusive even if their
parallel flag is true. Turns with skill tool-policy constraints run tools
serially to preserve call limits and sequencing.

Tool lifecycle events identify individual calls and may finish out of order.
Provider call/result history retains the model's original call order. The
thread's pending snapshot represents one outstanding wait; use tool lifecycle
events to display all concurrent calls. Host tools remain responsible for their
own resource synchronization and cooperative cancellation.

Custom backends can continue emitting `toolCallRequested` for one call, or emit
`toolCallsRequested` for a batch and accept results by invocation ID. The existing
`AgentTurnStream(events:submitToolResult:)` initializer remains available.

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
sample tools and displays observed concurrency. The interactive backend enables
reasoning summaries; model output still determines whether summaries arrive.

See [Try the runtime features](../DemoApp/README.md#try-the-runtime-features) for
steps, expected behavior, and the distinction between live account data and fixed
sample tool outputs.

## Migration

Update exhaustive switches for the added event cases, `AgentTurnStatus.interrupted`,
and `AgentSystemEventType.turnInterrupted`. Cancellation now produces interrupted
status rather than failed status. Existing tools stay serial unless explicitly
opted in, and existing stored messages decode with `phase == nil`.
