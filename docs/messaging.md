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

`CodexKit` sends that through the OpenAI Responses structured-output path and stores the assistant's final JSON reply in thread history like any other assistant turn.

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
