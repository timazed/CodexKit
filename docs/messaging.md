# Messaging, structured output, and images

[Documentation index](index.md) · [CodexKit](../README.md)

Send text, attach typed context and fulfillment options, decode structured replies, and work with images.

## Typed Completions

For most apps, there are four common send paths:

- `stream(...)`
  Stream deltas, tool events, approvals, and final turn completion.
- `stream(..., response:)`
  Stream normal turn events plus typed structured-output events in the same turn.
- `send(...)`
  Return the assistant's final text as a `String`.
- `send(..., response:)`
  Return a typed `Decodable` value from a structured response.

### Event buffering and execution limits

`AgentRuntime.Configuration.maximumBufferedEvents` defaults to 64 and is clamped to 1–4,096. The runtime uses a bounded, lossless queue: when a reader pauses, producers await capacity. Completion and failure can reserve up to four additional lifecycle events so a full queue cannot hide the terminal outcome. Events already admitted to the queue retain their order. The built-in backend and HTTP event parser use the same policy, configured separately through `CodexResponsesBackendConfiguration.maximumBufferedEvents`.

A caller cancelled before `start`, `stream`, or `send` begins preparation cannot reserve a thread, persist input, or launch backend work. If cancellation arrives during storage preparation, accepted input is retained, the turn is recorded as interrupted, and the thread returns to idle. A startup waiter can leave promptly while a disk lock is unavailable; accepted writes and interruption records then flush in order when storage is available. A commit already underway finishes safely. See [storage cancellation](persistence.md#cancellation-and-commits). Cancelling a readiness waiter for an accepted execution only cancels that waiter.

Consume each stream from one task. Cancelling that consumer or releasing the stream and its iterator cancels its producer. If you keep the stream alive after leaving a loop, use `runtime.interrupt(in:)` to end a persistent turn. `send` consumes the stream for you. Custom backends are responsible for their own internal buffering; these bounds cover SDK-owned event queues, not URLSession internals or total process memory.

Runtime turns now default to 128 requested tool calls and 300 seconds:

```swift
let runtime = try AgentRuntime(configuration: .init(
    authProvider: authProvider,
    secureStore: secureStore,
    backend: backend,
    approvalPresenter: approvalPresenter,
    stateStore: stateStore,
    maximumBufferedEvents: 64,
    turnLimits: .init(maximumToolCalls: 128, maximumDuration: 300)
))
```

These limits apply to plain, structured, and ephemeral turns. A tool batch must fit the remaining budget before any executor in that batch starts; requested calls count even when denied or satisfied from stored results. The duration runs from producer launch until a valid completion is accepted, including session resolution, approvals, tools, and waiting for event consumers. Final persistence and cleanup complete afterward. Cancellation is cooperative: custom backends, tools, and activity providers must honor it for prompt shutdown.

Pass `nil` for either limit to remove it, or `turnLimits: .unlimited` to remove both runtime budgets. Invalid tool counts or non-finite/nonpositive durations fail runtime construction; finite durations may be at most one year. The [backend's model-pass and response limits](backend-configuration.md#response-and-model-pass-limits) remain independently configured.

Budget exhaustion emits `turnFailed`, throws an `AgentRuntimeError`, clears pending waits, and marks persistent turns failed. Inspect `error.executionLimit` for `.toolCalls`, `.duration`, `.modelPasses`, `.responseBytes`, or `.responseItems`. Ordinary user cancellation still records interruption. Increasing the duration is appropriate for workflows that intentionally wait longer for human approval.

### Typed request context

If you need to send host-app context or fulfillment policy separately from human prompt text, use `Request` with `context` and `options`. CodexKit keeps both in developer-message space so the model can see them without pretending they are user-authored text.

- `context`
  Optional authoritative machine context for the turn.
- `options`
  Optional fulfillment policy for the turn. Use this to describe how lookup, retrieval, or enrichment work should be performed.
- `response:`
  The typed response contract CodexKit transmits, validates, and decodes.

```swift
struct PlannerContext: Codable, Sendable {
    let objective: String
    let customerTier: String
}

let draft = try await runtime.send(
    try Request(
        text: "Draft a response for the delayed package.",
        context: PlannerContext(
            objective: "Resolve the shipping complaint quickly.",
            customerTier: "plus"
        ),
        contextSchemaName: "PlannerContext"
    ),
    in: thread.id,
    response: ShippingReplyDraft.self
)
```

### Request options

For retrieval-style workflows, `options` can carry app-owned declarative requirements that render into fulfillment instructions:

```swift
protocol NaturalLanguageRenderable {
    var naturalLanguage: String { get }
}

protocol RequestMode: NaturalLanguageRenderable, Sendable { }
protocol RequestRequirement: NaturalLanguageRenderable, Sendable { }

struct NutritionProfile: Codable, Sendable {
    let dietaryGoal: String
    let allergies: [String]
}

enum DietPlanningMode: RequestMode {
    case planning

    var naturalLanguage: String {
        "Plan a healthy diet recommendation tailored to the known nutrition profile."
    }
}

enum DietRequirement: RequestRequirement {
    case proteinTarget
    case fiberTarget
    case mealIdeas

    var naturalLanguage: String {
        switch self {
        case .proteinTarget:
            "Recommend meals that support a high-protein diet."
        case .fiberTarget:
            "Include foods that help increase daily fiber intake."
        case .mealIdeas:
            "Suggest practical breakfast, lunch, and dinner ideas."
        }
    }
}

struct DietPlanningOptions: RequestOptionsRepresentable {
    let mode: DietPlanningMode
    let requirements: [DietRequirement]
}

struct HealthyDietPlan: AgentStructuredOutput {
    let summary: String
    let breakfast: String
    let lunch: String
    let dinner: String

    static let responseFormat = AgentStructuredOutputFormat(
        name: "healthy_diet_plan",
        description: "A healthy diet recommendation tailored to the user's needs.",
        schema: .object(
            properties: [
                "summary": .string(),
                "breakfast": .string(),
                "lunch": .string(),
                "dinner": .string(),
            ],
            required: ["summary", "breakfast", "lunch", "dinner"],
            additionalProperties: false
        )
    )
}

let dietPlan = try await runtime.send(
    try Request(
        text: "Create a healthy diet plan for this week.",
        context: NutritionProfile(
            dietaryGoal: "Lose weight while maintaining energy",
            allergies: ["peanuts"]
        ),
        options: DietPlanningOptions(
            mode: .planning,
            requirements: [.proteinTarget, .fiberTarget, .mealIdeas]
        )
    ),
    in: thread.id,
    response: HealthyDietPlan.self
)
```

That request is sent conceptually as:

```text
Developer message: context
{"dietaryGoal":"Lose weight while maintaining energy","allergies":["peanuts"]}

Developer message: turn policy
Mode: Plan a healthy diet recommendation tailored to the known nutrition profile.
Requirements:
- Recommend meals that support a high-protein diet.
- Include foods that help increase daily fiber intake.
- Suggest practical breakfast, lunch, and dinner ideas.

User message
Create a healthy diet plan for this week.

Response contract
Return the final result serialized as `HealthyDietPlan`.
```

### Typed replies

For App Intents, share flows, widgets, or other non-chat surfaces, `CodexKit` can return a typed value directly from `send`:

```swift
let summary = try await runtime.send(
    Request(text: "Summarize the latest thread activity."),
    in: thread.id
)
```

### Ephemeral turns

Use `executionMode: .ephemeral` when a turn should be fast and transient. Ephemeral turns still stream events, run tools, and decode structured output, but they do not replay prior thread history, compact context, write transcript/history records, update thread pending state, or capture memories:

```swift
let quickSummary = try await runtime.send(
    Request(
        text: "Summarize this notification payload.",
        executionMode: .ephemeral
    ),
    in: thread.id
)
```

Ephemeral turns may still retrieve and inject configured memory. Here, “capture memories” means
automatic memory writes from the completed transcript, which remain disabled for ephemeral work.

### Per-request behavior

More specific personas replace less specific ones: a thread persona replaces the runtime/backend personality, and `personaOverride` replaces both for one request.

Provide `personaOverride` when a transient execution agent should use a request-local personality:

```swift
let browserPersona = AgentPersonaStack(layers: [
    .init(
        name: "reservation_browser_automation_loop",
        instructions: "Complete the browser task deterministically. Return only the structured outcome."
    )
])

let decision = try await runtime.send(
    Request(
        text: "Inspect the current reservation page and choose the next action.",
        executionMode: .ephemeral,
        personaOverride: browserPersona
    ),
    in: thread.id,
    response: ReservationPageDecision.self
)
```

Request overrides replace inherited behavior for that turn: `personaOverride` replaces the runtime/thread persona, and `skillSelection: .replace(...)` replaces thread skills. Use `skillSelection: .append(...)` to keep thread skills and add request-local skills.

### Structured output schemas

Structured output is schema-driven and decoded into your `Decodable` type:

```swift
struct ShippingReplyDraft: AgentStructuredOutput {
    let subject: String
    let reply: String
    let urgency: String

    static let responseFormat = AgentStructuredOutputFormat(
        name: "shipping_reply_draft",
        description: "A concise shipping support reply draft.",
        schema: .object(
            properties: [
                "subject": .string(),
                "reply": .string(),
                "urgency": .string(enum: ["low", "medium", "high"]),
            ],
            required: ["subject", "reply", "urgency"],
            additionalProperties: false
        )
    )
}

let draft = try await runtime.send(
    Request(text: "Draft a response for the delayed package."),
    in: thread.id,
    response: ShippingReplyDraft.self
)
```

### Streaming structured output

If you want streamed prose and typed machine output in the same turn, use the streaming overload:

```swift
let stream = try await runtime.stream(
    Request(text: "Draft a response for the delayed package."),
    in: thread.id,
    response: ShippingReplyDraft.self,
    options: .init(required: true)
)

for try await event in stream {
    switch event {
    case let .assistantMessageDelta(_, _, delta):
        print("visible:", delta)
    case let .structuredOutputPartial(snapshot):
        print("partial:", snapshot)
    case let .structuredOutputCommitted(snapshot):
        print("final:", snapshot)
    default:
        break
    }
}
```

The structured payload is delivered out-of-band from assistant prose. CodexKit keeps request-time structured metadata separate from runtime instructions, strips its internal framing before emitting text deltas or committed assistant messages, and persists the final committed payload metadata with the assistant message for later restore/inspection.

One-shot structured replies use the Responses `json_schema` format. Streamed structured replies use a framed JSON block alongside prose. Both paths validate the declared schema locally before accepting output.

If you need something more specialized, `AgentStructuredOutputFormat` still supports a raw-schema escape hatch via `rawSchema: JSONValue`.

## Image Attachments

`CodexKit` supports:

- user text + image attachments
- image-only messages
- persisted image attachments in runtime state
- assistant image attachments returned by backend content
- hosted Responses image generation results

```swift
let imageData: Data = ...

let stream = try await runtime.stream(
    Request(
        text: "Describe this image",
        images: [.jpeg(imageData)]
    ),
    in: thread.id
)
```

Custom tools can also return image URLs via `ToolResultContent.image(URL)`, and `CodexKit` attempts to hydrate those into assistant image attachments for chat rendering.

Image bytes are externalized from runtime state. Attachments are written to flat files under the runtime attachment directory, while SQLite and Realm store the attachment id, MIME type, relative storage key, and any generation metadata. On restore, `CodexKit` follows that storage key and reloads the bytes into `AgentImageAttachment`.

For hosted image generation, enable the Responses image generation tool on the backend:

```swift
let backend = CodexResponsesBackend(
    configuration: CodexResponsesBackendConfiguration(
        enableImageGeneration: true
    )
)
```

Generated `image_generation_call` items with a base64 `result` are converted into assistant `AgentImageAttachment` values so existing transcript rendering and persistence paths work without app-defined tool plumbing. The result can arrive while the item status is still `"generating"`, so apps should use the presence of `images` rather than status text to decide whether there is something renderable.

When the backend includes generation details, they are available on `AgentImageAttachment.generationMetadata`:

```swift
if let image = message.images.first,
   let metadata = image.generationMetadata {
    print(metadata.revisedPrompt ?? "")
    print(metadata.size ?? "")
    print(metadata.quality ?? "")
}
```

The attachment remains the stable app-facing shape:

```swift
for image in message.images {
    render(data: image.data, mimeType: image.mimeType)
}
```

### Structured validation and backend completion

`send(..., response:)`, `sendWithSummary(..., response:)`, and `stream(..., response:)` check the declared schema before starting a turn. It validates JSON before decoding into the Swift output type or storing/emitting a structured commit. This enforces enums, required properties, and `additionalProperties`, even when Swift decoding alone would accept the value. Partial snapshots relax missing-required and minimum-size checks; type, enum, additional-property, and maximum-size checks still apply. A partial must also decode into the requested Swift type to be emitted.

One-shot replies also decode into the requested Swift type before the assistant message is saved or the turn is marked successful. Schema or decoding failures fail the turn and do not commit the invalid reply. Explicit `.commentary` messages may contain prose; at least one valid non-commentary response is required. The caller receives the already-decoded value, preserving custom decoder behavior and integer precision. One-shot JSON payloads are limited to 4 MiB.

All `JSONSchema` builder cases are supported. Raw schemas use the same supported subset for one-shot and streaming output, including Boolean schemas and these assertion keywords:

- `type`, `properties`, `required`, `additionalProperties`, `items`, `enum`, `const`
- `anyOf`, `oneOf`, `allOf`, `not`, `$defs`, `definitions`, and root-local JSON-pointer `$ref`
- `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`
- `minLength`, `maxLength`, `minItems`, `maxItems`, `uniqueItems`, `minProperties`, `maxProperties`

Common annotations (`$schema`, `$id`, `$comment`, `title`, `description`, `default`, `examples`, `deprecated`, `readOnly`, `writeOnly`) do not assert validity. Other keywords, including `pattern`, `format`, and remote references, are rejected rather than silently ignored. This is a supported subset, not a complete JSON Schema implementation. Validation has nesting/work bounds; the built-in framed-stream parser also caps a structured payload at 4 MiB and avoids decoding every incomplete prefix.

Custom backends must emit a valid `turnCompleted` event for a successful turn. EOF alone is insufficient, including after an assistant message: `send` and both stream forms fail with `turn_summary_missing`, and persistent turns move to failed status.

Backends that start network requests asynchronously can supply `waitUntilReady` in the full `AgentTurnStream` initializer. Resolve readiness once the initial request is accepted, before publishing response content or starting tool effects. Fail readiness only when it is safe for the runtime to recover/retry the initial request. Once ready, later failures belong to the event stream and must not cause whole-turn replay. The default readiness handler returns immediately for existing custom backends.
