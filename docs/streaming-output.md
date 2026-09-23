# Streaming structured output

CodexKit's turn-based output API applies one decoder to one assistant final message, streams provisional format events, validates the complete value, and commits the typed result only after the turn succeeds and, for persistent requests, its storage transaction succeeds. It is additive to the existing `response:` structured-reply APIs and ordinary assistant text streaming.

## Choose a format

| Format | Generation contract | Stream events | Validation |
| --- | --- | --- | --- |
| `AgentTextResponseFormat` | One final text message | Bounded UTF-8-safe text deltas | UTF-8 and configured limits |
| `AgentJSONResponseFormat<Value>` | Native provider JSON Schema | Provisional raw JSON text deltas | Strict JSON, schema, `Decodable`, optional app validation |
| `AgentRecordResponseFormat<Record>` | One JSON object per physical line | A record after each complete valid line | Strict JSON, optional JSON Schema, `Decodable`, count bounds, optional app validation |
| `AgentXMLResponseFormat` | One XML 1.0 document following the supplied XSD | SAX-derived element/text events | XML syntax, XSD 1.0, limits, optional app validation |

Native constrained generation is used for `AgentJSONResponseFormat`. JSON Lines and XML are instructed formats and are validated locally; CodexKit does not claim that their wire syntax improves a model's reasoning accuracy. JSON Lines is currently the only record codec. Alternative compact codecs remain prototypes unless they demonstrate reliable quality as well as a meaningful end-to-end benefit.

## Turn-based use

All formats use the same API shape. A streaming execution exposes lifecycle events and typed, provisional format events; `send` collects the same pipeline and returns after commit.

```swift
let format = AgentRecordResponseFormat(
    name: "assessments",
    record: Assessment.self,
    schema: .object(
        properties: ["title": .string(), "priority": .string(enum: ["low", "medium", "high"])],
        required: ["title", "priority"],
        additionalProperties: false
    ),
    minimumRecords: 1
)

let execution = try await runtime.start(
    Request(text: "Assess these options."),
    in: thread.id,
    output: format
)

for try await event in execution.events {
    switch event {
    case let .format(_, .recordCompleted(index, assessment)):
        // Provisional: render it, but do not treat it as a committed result yet.
        render(assessment, at: index)
    case let .outputCommitted(_, collection):
        accept(collection.records)
    case let .validationFailed(_, failure):
        showOutputError(failure.message)
    case let .lifecycle(event):
        handle(event)
    default:
        break
    }
}
```

For one-shot use, call `send(_:in:output:)`. `sendWithSummary(_:in:output:)` returns the value, turn summary, request ID, and memory application result. `fetchLatestOutput(in:output:)` restores the latest compatible persisted result for a thread. A custom decoder can omit persistence only for an ephemeral request.

Existing `AgentStructuredOutput` types can reuse their schema, description, and strictness with `AgentJSONResponseFormat(Assessment.self)`. For records, specify either `record: Assessment.self` as above or `AgentRecordResponseFormat<Assessment>(name: "assessments")`; the type need not be repeated.

Generic consumers can refer to `Format.Event` and `Format.Output` without reaching through `Format.Decoder`. Custom formats may use throwing getters for `formatInstructions`, `schemaRepresentation`, and `persistence`; nonthrowing properties still conform. The runtime prepares these values once before starting the turn and retains that snapshot through commit. XML formats generate their XSD source once and propagate schema errors rather than substituting placeholder instructions.

Events before `.outputCommitted` are provisional. The model may finish a syntactically complete root or record and still fail later, the backend may fail, the source text may not match the completed message, application validation may reject it, or storage may fail. In each case there is no committed typed result. Steering remains available until the final structured output begins; after that point, the runtime rejects steering so the candidate cannot silently mix multiple output attempts.

The stream uses bounded event-count and byte budgets with awaited delivery. A slow consumer applies back pressure instead of allowing unbounded queued output. Configure `AgentStructuredOutputLimits` to fit the application's expected response size; CodexKit enforces input, encoded output, semantic-unit, nesting, schema, and event limits before commit.

Malformed records throw `AgentRecordDecodingError`, with a zero-based `recordIndex` and `underlyingError`. The terminal `validationFailed` event exposes the same index and typed error through `AgentOutputFailure`. Cancellation, limit, and event-delivery failures retain their own types; they are not mislabeled as malformed records.

## XML schema and events

The XML schema DSL mirrors the compact value-oriented JSON schema API while representing XML's distinct concepts: element declarations, content particles, attributes, simple types, and occurrence bounds.

```swift
let format = AgentXMLResponseFormat(
    name: "assessment",
    description: "An assessment with a recommended action.",
    schema: .element("response", children: .sequence([
        .element("assessment", text: .string),
        .element("recommendation", text: .string, attributes: [
            "priority": .required(.string(enum: ["low", "medium", "high"]))
        ]),
        .element("limitations", text: .string, occurs: .optional)
    ]))
)
```

The DSL supports attributes (including required, optional, and enumerated values), simple content with attributes, nested sequence/choice/all groups, optional and repeated particles, namespaces, mixed content, reusable named types, and common XSD simple types/facets. For schema constructs outside the DSL, use `XMLSchema.xsd(_:root:)` with a self-contained XSD 1.0 document. The selected root is explicit. External schema resolution (`include`, `import`, and `redefine`) and XSD 1.1 are not supported.

The XML decoder uses the system libxml2 push/SAX parser and XSD validator. It retains the exact UTF-8 source and an immutable ordered element/content tree. Element IDs are stable within that decoded document; names compare by namespace URI and local name, not prefix. `AgentXMLStreamingOptions` controls text deltas, completed subtree selection, and optional application-identity attributes.

Schema preflight uses its own bounded parser configuration and respects `maximumSchemaBytes`. Response depth and node limits apply to the response, not the XSD that describes it; a one-element response can therefore use `maximumNestingDepth = 1` and `maximumSemanticUnits = 1`.

```swift
let execution = try await runtime.start(request, in: thread.id, output: format)
for try await event in execution.events {
    switch event {
    case let .format(_, .textDelta(elementID, text)):
        appendProvisionalText(text, to: elementID)
    case let .format(_, .elementCompleted(element)):
        renderProvisionalSection(element)
    case let .outputCommitted(_, document):
        accept(document.root)
    default:
        break
    }
}
```

Text callbacks are provisional and their chunk boundaries are unspecified. A completed subtree is also provisional until the enclosing output is committed. The parser rejects DTDs and custom/external entities; XML comments and processing instructions are not represented in the content tree. XML attributes and text remain lexical strings after XSD validation—application-level typed conversion is explicit.

## Persistence and compatibility

The committed result is stored in the existing structured-output metadata envelope, alongside the exact source message and versioned codec/schema identity. This avoids a parallel XML history record or store-specific schema migration. Fetch checks the codec, format version, and schema representation before decoding; incompatible results fail explicitly. Redacted metadata tombstones do not restore a result.

Persisted output is decoded using the format's persistence adapter and checked against its codec/version/schema identity and limits. XML restoration reparses the source and reruns XSD validation; Codable-backed formats restore their encoded typed value. Keep a compatible format/schema definition available when restoring results. If the format changes incompatibly, use a new version/identity and an explicit migration or discard policy rather than interpreting old bytes under the new schema.

Existing `response:` APIs, ordinary text streams, and legacy structured outputs are unchanged. The new `output:` family is opt-in. Partial parser state is execution-local and is not resumed after process termination.
