# Personas and skills

[Documentation index](index.md) · [CodexKit](../README.md)

Compose agent instructions, constrain tool use with skills, load definitions, and inspect resolved instructions.

## Pinned And Dynamic Personas

`CodexKit` supports layered persona precedence:

- base runtime instructions
- thread-pinned persona
- turn override

Persona swaps are runtime metadata, not transcript messages, so they do not materially grow the transcript context.

```swift
let supportPersona = AgentPersonaStack(layers: [
    .init(name: "domain", instructions: "You are an expert customer support agent for a shipping app."),
    .init(name: "style", instructions: "Be concise, calm, and action-oriented.")
])

let thread = try await runtime.createThread(
    title: "Support Chat",
    personaStack: supportPersona
)

let reviewerOverride = AgentPersonaStack(layers: [
    .init(name: "reviewer", instructions: "For this reply only, act as a strict reviewer and call out risks first.")
])

let stream = try await runtime.stream(
    Request(
        text: "Review this architecture and point out the risks.",
        personaOverride: reviewerOverride
    ),
    in: thread.id
)
```

Personas follow runtime → thread → turn precedence. A thread persona replaces the runtime/backend personality, and a request persona override replaces the thread persona for that turn. The next request falls back to the thread's normal persona.

## Skill Examples

`CodexKit` skills are behavior modules, not just tone layers. They can carry both instructions and execution policy (tool allow/require/sequence/call limits).

An omitted or `nil` `allowedToolNames` leaves tools unrestricted by that skill. An explicit empty array disallows every tool. Multiple skill allowlists are intersected, and tool-call limits must be nonnegative.

```swift
let healthCoachSkill = AgentSkill(
    id: "health_coach",
    name: "Health Coach",
    instructions: "You are a health coach focused on daily step goals and execution. For every user turn, call the health_coach_fetch_progress tool exactly once before your final reply.",
    executionPolicy: .init(
        allowedToolNames: ["health_coach_fetch_progress"],
        requiredToolNames: ["health_coach_fetch_progress"],
        maxToolCalls: 1
    )
)

let travelPlannerSkill = AgentSkill(
    id: "travel_planner",
    name: "Travel Planner",
    instructions: "You are a travel planning assistant for mobile users. Provide concise day-by-day itineraries, practical logistics, and a compact packing checklist.",
    executionPolicy: .init(
        allowedToolNames: ["lookup_flights", "lookup_hotels"],
        requiredToolNames: ["lookup_flights"],
        toolSequence: ["lookup_flights", "lookup_hotels"],
        maxToolCalls: 3
    )
)

let runtime = try AgentRuntime(configuration: .init(
    authProvider: authProvider,
    secureStore: secureStore,
    backend: backend,
    approvalPresenter: approvalPresenter,
    stateStore: stateStore,
    skills: [healthCoachSkill, travelPlannerSkill]
))

let healthThread = try await runtime.createThread(
    title: "Skill Demo: Health Coach",
    skillIDs: ["health_coach"]
)

let tripThread = try await runtime.createThread(
    title: "Skill Demo: Travel Planner",
    skillIDs: ["travel_planner"]
)

let stream = try await runtime.stream(
    Request(
        text: "Review this plan with extra travel rigor.",
        skillSelection: .append(["travel_planner"])
    ),
    in: healthThread.id
)
```

## Dynamic Persona And Skill Sources

You can load persona/skill instructions from local files or remote URLs at runtime.

```swift
let localPersonaURL = URL(fileURLWithPath: "/path/to/persona.txt")
let thread = try await runtime.createThread(
    title: "Dynamic Persona Thread",
    personaSource: .file(localPersonaURL)
)
```

```swift
let remoteSkillURL = URL(string: "https://example.com/skills/shipping_support.json")!
let skill = try await runtime.registerSkill(
    from: .remote(remoteSkillURL)
)

try await runtime.setSkillIDs([skill.id], for: thread.id)
```

For persona sources:

- plain text creates a single-layer persona stack
- JSON can be a full `AgentPersonaStack`

For skill sources:

- JSON supports `{ "id": "...", "name": "...", "instructions": "...", "executionPolicy": { ... } }`
- plain text is supported when you pass `id` and `name` in `registerSkill(from:id:name:)`

The only supported JSON root fields are `id`, `name`, `instructions`, and `executionPolicy`. Unknown fields, including `executionPolciy` or an unrecognized `metadata` object, throw `invalid_skill_definition`. There is no permissive metadata extension namespace.

A skill source beginning with `{` after leading whitespace (and an optional UTF-8 byte-order mark) is treated as a JSON object definition. Invalid JSON, incorrect field types, unknown root or execution-policy keys, invalid tool names, and negative tool-call limits throw `AgentDefinitionSourceError` with code `invalid_skill_definition`. Such definitions never fall back to plain text or silently lose their policy. An absent, `null`, or empty execution-policy object remains valid.

Both persona and skill sources default to a **1 MiB (1,048,576 byte)** limit. Files and remote responses are read with this limit before UTF-8 or JSON decoding; an oversized body throws `definition_too_large`, including when a server omits or understates `Content-Length`. Configure a larger positive limit when your definitions need it:

```swift
let definitionLoader = AgentDefinitionSourceLoader(
    maximumDefinitionBytes: 2 * 1_024 * 1_024
)

let configuration = AgentRuntime.Configuration(
    sessionProvider: sessionProvider,
    backend: backend,
    approvalPresenter: approvalPresenter,
    stateStore: stateStore,
    definitionSourceLoader: definitionLoader
)
```

The same limit applies when calling the loader directly. Zero or negative limits throw `invalid_definition_limit` on loading. File sources must be regular local files, and cancellation stops reading or downloading.

## Debugging Instruction Resolution

You can preview the compiled instructions that would be produced from the current thread,
memory-store, and renderer state. A preview is point-in-time: a later send resolves once again,
so it can differ if those inputs change in between.

```swift
let preview = try await runtime.resolvedInstructionsPreview(
    for: thread.id,
    request: Request(
        text: "Give me a strict step plan."
    )
)
print(preview)
```

Use the detailed preview when tooling also needs the memory query, matches, rendered text,
record IDs, and placement:

```swift
let details = try await runtime.resolvedInstructionsPreviewDetails(
    for: thread.id,
    request: Request(text: "Give me a strict step plan.")
)

print(details.instructions)
print(details.memory?.includedRecordIDs ?? [])
```
