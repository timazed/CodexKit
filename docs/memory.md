# Memory

[Documentation index](index.md) · [CodexKit](../README.md)

Configure automatic capture, write guided or raw memory records, control retrieval, and inspect attribution.

## Memory Layer

`CodexKit` now supports three memory layers:

- high-level automatic capture policies for apps that want the runtime to extract memory after successful turns
- a guided `MemoryWriter` layer that resolves defaults into concrete records
- the raw `MemoryRecord` / `MemoryStoring` APIs for apps that want exact control

The SDK owns storage, retrieval, ranking, and optional prompt injection. Your app can choose how automatic or explicit memory authoring should be.

### Instruction placement

Rendered memory stays inside the backend instruction string. Its placement is configurable:

```swift
let memory = AgentMemoryConfiguration(
    store: memoryStore,
    promptRenderer: RacingMemoryPromptRenderer(),
    instructionPlacement: .beforeSkills,
    automaticCapturePolicy: nil
)
```

The default, `.afterSkills`, preserves the original CodexKit behavior. A thread can override
the runtime default through `AgentMemoryContext.instructionPlacement`, and one request can
override both through `MemorySelection.instructionPlacement`. `.beforePersonas`
inserts memory after base instructions and before every persona or skill section.
`.beforeSkills` inserts it immediately before the first active skill, so domain learnings can
inform an analysis while the skill remains the later instruction. Placement never changes the
relative order of existing base, persona, and skill sections. In particular, personas continue
to replace base instructions, and an existing thread skill continues to precede a turn persona
override. Placement is precedence signalling within one instruction string, not a security or
validation boundary.

### Automatic capture

High-level automatic capture looks like this:

```swift
let runtime = try AgentRuntime(configuration: .init(
    authProvider: try ChatGPTAuthProvider(
        method: .deviceCode,
        deviceCodePresenter: deviceCodeCoordinator
    ),
    secureStore: KeychainSessionSecureStore(
        service: "CodexKit.ChatGPTSession",
        account: "demo"
    ),
    backend: CodexResponsesBackend(
        configuration: .init(model: .gpt56Sol)
    ),
    approvalPresenter: approvalPresenter,
    stateStore: try SQLiteRuntimeStateStore(),
    memory: .init(
        store: try SQLiteMemoryStore(),
        automaticCapturePolicy: .init(
            source: .lastTurn,
            options: .init(
                defaults: .init(
                    namespace: "demo-assistant",
                    category: "preference"
                ),
                maxMemories: 2
            )
        )
    )
))

let thread = try await runtime.createThread(
    title: "Health Coach",
    memoryContext: .init(
        namespace: "demo-assistant",
        scopes: ["feature:health-coach"]
    )
)

_ = try await runtime.send(
    Request(text: "Be direct with me when I fall behind on steps."),
    in: thread.id
)
```

### Guided writing

Mid-level guided authoring looks like this:

```swift
let writer = try await runtime.memoryWriter(
    defaults: .init(
        namespace: "demo-assistant",
        scope: "feature:health-coach",
        category: "preference",
        tags: ["steps", "tone"]
    )
)

let record = try await writer.upsert(
    MemoryDraft(
        summary: "Health Coach should use direct accountability when the user is behind on steps.",
        evidence: ["The user responds better to blunt reminders than soft encouragement."],
        importance: 0.9,
        dedupeKey: "health-coach-direct-accountability"
    )
)
```

### Explicit capture

If you want the SDK to capture memory for you, `AgentRuntime` can extract durable memory candidates from a thread or transcript and write them automatically:

```swift
let thread = try await runtime.createThread(
    title: "Health Coach",
    memoryContext: .init(
        namespace: "demo-assistant",
        scopes: ["feature:health-coach"]
    )
)

let result = try await runtime.captureMemories(
    from: .threadHistory(maxMessages: 6),
    for: thread.id,
    options: .init(
        defaults: .init(
            namespace: "demo-assistant",
            scope: "feature:health-coach",
            category: "preference"
        ),
        maxMemories: 3
    )
)

print(result.records.count)
```

### Raw store access

If you want full control, the low-level store API is still there:

```swift
let memoryStore = try SQLiteMemoryStore()

try await memoryStore.upsert(
    MemoryRecord(
        namespace: "demo-assistant",
        scope: "feature:health-coach",
        category: "preference",
        summary: "Health Coach should use direct accountability when the user is behind on steps.",
        evidence: ["The user responds better to blunt coaching than soft encouragement."],
        importance: 0.9,
        tags: ["steps", "tone"]
    ),
    dedupeKey: "health-coach-direct-accountability"
)

let runtime = try AgentRuntime(configuration: .init(
    authProvider: try ChatGPTAuthProvider(
        method: .deviceCode,
        deviceCodePresenter: deviceCodeCoordinator
    ),
    secureStore: KeychainSessionSecureStore(
        service: "CodexKit.ChatGPTSession",
        account: "main"
    ),
    backend: CodexResponsesBackend(),
    approvalPresenter: approvalInbox,
    stateStore: try SQLiteRuntimeStateStore(),
    memory: .init(store: memoryStore)
))

let thread = try await runtime.createThread(
    title: "Press Chat",
    memoryContext: AgentMemoryContext(
        namespace: "demo-assistant",
        scopes: ["feature:health-coach", "thread:daily-checkin"]
    )
)
```

### Per-turn retrieval

Per-turn memory can be narrowed, expanded, replaced, or disabled with `MemorySelection`:

```swift
let reply = try await runtime.send(
    Request(
        text: "How should the health coach respond when the user is behind on steps?",
        memorySelection: MemorySelection(
            mode: .append,
            scopes: ["feature:travel-planner"],
            tags: ["steps"],
            text: "daily step adherence coaching",
            instructionPlacement: .beforeSkills
        )
    ),
    in: thread.id
)
```

`MemorySelection.text` is the retrieval query override. Without it, CodexKit searches with
`Request.text`. Typed `Request.context`, request options, and image contents are deliberately
not converted into search text or exposed to the memory store. Applications whose visible
prompt is generic—such as a typed race-analysis request—should build a bounded, deterministic
query from the domain features that are safe and useful for retrieval.

### Rendering and attribution

Memory renderers can also declare exactly which selected records contributed to their prompt.
Existing renderers remain source compatible, but their attribution is conservatively empty.
A custom renderer must implement `renderWithMetadata` to provide exact attribution:

```swift
struct RacingMemoryPromptRenderer: MemoryPromptRendering {
    func render(result: MemoryQueryResult, budget: MemoryReadBudget) -> String {
        renderWithMetadata(result: result, budget: budget).instructions
    }

    func renderWithMetadata(
        result: MemoryQueryResult,
        budget: MemoryReadBudget
    ) -> RenderedMemoryPrompt {
        let included = Array(result.matches.prefix(max(0, budget.maxItems)))
        let instructions = included
            .map { "- \($0.record.summary)" }
            .joined(separator: "\n")
        return RenderedMemoryPrompt(
            instructions: instructions,
            includedRecordIDs: included.map(\.record.id)
        )
    }
}
```

Before memory reaches the backend, CodexKit validates the resolved query before calling even a
custom store, verifies returned records against its scope, text, ordering, cursor, and size
contract before rendering, requires renderer output to fit the effective
`MemoryReadBudget.maxCharacters`, bounds renderer metadata, and reserves worst-case identifier
encoding in the attribution snapshot. Invalid or oversized memory is omitted with a
memory-category warning, so a successful model turn cannot fail later merely because its
attribution record is unsafe to persist. Task cancellation is never converted into an ordinary
memory miss, and a completion emitted after cancellation cannot create attribution.

### Persisted attribution and turn results

Every successful threaded runtime turn durably stores its `MemoryApplicationSnapshot` inside
the same `turnCompleted` history event. It includes the real thread and turn IDs, optional
host correlation ID, model and reasoning settings, active skill IDs, renderer identifier,
SHA-256 digest of the complete compiled instructions, query result, exact rendered memory
text, declared record IDs, and placement. Recover persisted attribution without relying on a
callback:

```swift
let request = Request(text: "Analyse this race")
    .correlated(with: assessmentID)
let completed = try await runtime.sendWithSummary(
    request,
    in: thread.id,
    response: RaceAssessment.self
)
let applied = completed.memoryApplicationSnapshot
assert(applied?.turnID == completed.summary.turnID)

let durable = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
assert(durable.first == applied)
```

`AgentTurnResult.memoryApplication` is explicit about successful turns that did not apply memory:

- `.applied(snapshot)` returns the exact query result and rendered instructions used for the turn.
- `.notApplied(.disabled)` means the request explicitly disabled memory.
- `.notApplied(.noMatches)` means retrieval succeeded but neither the result nor renderer produced instructions.
- `.notApplied(.unavailable)` means the memory store could not complete the query; the model turn continued without memory.
- Other reasons distinguish missing selection context, empty renderer output, rejected unsafe data, an unconfigured runtime, and attribution omitted by manual result construction.

The result also exposes `clientRequestID` at the top level, so callers can correlate a successful
turn even when memory was not applied. CodexKit resolves memory once before backend execution and
captures the outcome at accepted completion; returning attribution does not run another query.

For an ephemeral request, `sendWithSummary` returns the same first-class outcome without writing a
turn or attribution record:

```swift
let completed = try await runtime.sendWithSummary(
    Request(
        text: "Analyse this transient race payload",
        executionMode: .ephemeral
    ).correlated(with: assessmentID),
    in: thread.id,
    response: RaceAssessment.self
)

if case let .applied(snapshot) = completed.memoryApplication {
    learningPipeline.recordEvidence(from: snapshot)
}
```

`sendWithSummary` requires a backend completion-summary event. The existing `send` overloads retain
their value-only, message-completion behavior for source and behavioral compatibility with custom
backends. Manually initialized `AgentTurnResult` values default to `.notApplied(.notReported)`.

`MemoryObserving.handle(application:)` is a non-blocking notification of that durable record;
it is not the source of truth and may be missed if the process exits. Query previews, empty
rendered memory, failed or cancelled turns, and runtime-rejected completions do not produce
application snapshots. For ephemeral `sendWithSummary` calls, the returned outcome is authoritative
for that call while the observer remains best effort. A completed runtime turn means the model
received the attributed memory and the runtime accepted its completion; an application with
additional domain validation should keep the snapshot pending until that validation succeeds.

The runtime validates every custom-backend event against the active thread and turn, using the
correlation fields that event exposes, before it is published, executed, or persisted. An accepted
completion is terminal: later duplicate events or backend failures cannot add a second attribution
record or change the completed turn to failed.

The attribution convenience queries page through system history in bounded batches, reject stalled
or malformed cursors, cap aggregate decoded payloads, and stop at
`AgentStoreLimits.maximumMemoryAttributionScanCount`. They throw `AgentStoreError.invalidInput`
when those safety bounds prevent the requested result from being completed. Apps that intentionally
need older raw events can page `fetchThreadHistory(id:query:)` directly with their own cursor policy.

Successful compactions performed by an instruction-aware backend similarly store
`MemoryCompactionApplicationSnapshot` beside the `contextCompacted` marker and can be recovered with
`fetchMemoryCompactionApplicationSnapshots(id:)`. Compaction uses the same resolved memory and
placement but excludes turn-only skill execution-policy wording. Automatic pre-turn compaction
only compacts prior history; it never folds the pending request into history and sends it again.
Local-only compaction and local fallback never claim memory attribution because they do not consume
the compiled instructions. Automatic capture remains a separate opt-in policy.

Durable snapshots contain complete matched memory records, which may include evidence and
attributes. Treat runtime history as sensitive application data and use the existing history
redaction/deletion controls where retention is not appropriate.

### Inspection and diagnostics

For debugging and tooling, memory stores also support direct inspection:

```swift
let stored = try await memoryStore.record(
    id: "some-memory-id",
    namespace: "demo-assistant"
)
let records = try await memoryStore.list(
    namespace: "demo-assistant",
    scopes: ["feature:health-coach"],
    includeArchived: true,
    limit: 20
)
let diagnostics = try await memoryStore.diagnostics(namespace: "demo-assistant")
```

The demo app now includes a dedicated `Memory` tab that shows:

- high-level automatic capture after a normal turn
- mid-level automatic capture from transcript
- guided authoring with `MemoryWriter`
- raw record writes against the underlying store
- preview of the exact prompt block injected into a turn
