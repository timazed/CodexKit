# Enum sweep — 11 September 2026

The sweep covers the core SDK, SQLite and Realm adapters, UI, both demos, examples,
Swift tests, and Python verification scripts. The criteria are fixed domain choices
and control flow, not the number of quotation marks in a file.

| Domain | Change |
| --- | --- |
| Storage selection | Shared typed test backend with an exhaustive store factory; typed demo adapter selection. |
| Memory diagnostics | `MemoryStoreImplementation` identifies built-in stores and preserves custom identifiers. |
| Persistent state | Typed attachment ownership, migration kinds, history relationship kinds, SQLite sort columns, and Realm diagnostic dimensions. |
| Runtime and auth errors | Typed `AgentRuntimeErrorCode` constructors and `knownCode` routing; raw custom codes remain supported. Definition errors have their own code enum. |
| Responses protocol | Typed item, content, event, tool, request-choice, and search-status values. Event-specific `Decodable` payloads produce associated-value events directly. Unknown payloads remain usable. |
| HTTP and OAuth | Typed methods, supported URL schemes, and grant types at request and callback boundaries. |
| Schema validation | Typed schema value types, supported keywords, composition operators, and numeric constraints. |
| Tools and images | Centralized legacy tool-denial classification; shared MIME values replace repeated MIME checks. |
| Demo and verification | Typed demo tool names and travel budgets; reused structured-output identifiers; typed Python modes, phases, and probe events. |

Conversions are confined to compatibility initializers, serialization, and external
data parsing. Code does not decode an enum merely to compare a JSON value with one
known case. Single accepted constants do not get one-case enums solely to remove a
string literal.

The response stream client delegates JSON interpretation to
`CodexResponsesEventPayload`. One discriminator switch selects a payload struct;
Swift synthesizes field decoding and validates the relevant payload. Nested items
decode using the original decoder rather than encoding JSON and decoding it again,
preserving the original error path. Item progress uses typed message and search
payloads. Unknown events ignore unrelated fields, while raw output items retain
provider fields for history round trips.

Optional parsing chains now use explicit validation and fallback branches. Schema
type parsing is shared by schema and value validation and rejects invalid list
entries instead of discarding them. Catalog parsing distinguishes missing lists
from explicit empty lists and preserves custom effort names. Invalid optional
rate-limit telemetry does not discard a valid usage window. Remaining production
`flatMap` calls flatten collections.

The following values intentionally stay open:

- User text, instructions, model IDs, tool names, memory categories/tags/scopes,
  custom tool-session statuses, and provider-supplied image metadata.
- Unknown provider event types, error codes, catalog fields, and opaque stored
  payloads. The SDK classifies known values without discarding unknown ones.
- JSON/database field names, URLs, file extensions, SQL, protocol syntax, and
  expected wire strings in tests. Tests retain independent literal fixtures so
  changing a serialization spelling still fails a test.
- Demo prompt/response fixtures and arbitrary travel-companion labels. These are
  content rather than internal state choices.

## Public API migration

`MemoryStoreDiagnostics.implementation` is now `MemoryStoreImplementation`, and the
`AgentProgress.webSearch` associated status is now `AgentWebSearchStatus`. Both
preserve custom values. Existing string construction overloads remain available.
Consumers that need string APIs use `.rawValue`; consumers that branch use enum cases:

```swift
if diagnostics.implementation == .sqlite { /* SQLite-specific display */ }
if error.knownCode == .quotaExceeded { /* Show quota guidance */ }
if case let .webSearch(_, status, _) = progress, status == .completed {
    // Mark the search complete.
}
```

Memory diagnostic JSON still stores a single string for `implementation`. Runtime
errors still store the original string `code`, including application-defined codes.
No database schema migration is required.

This refactor improves type safety and removes some repeated parsing/allocation.
It does not establish a measured end-to-end performance improvement.

## Verification

- Full Swift suite after the event-decoder refactor, with warnings treated as
  errors: 623 tests, 6 skipped, no failures.
- Subsequent optional-parsing cleanup: 51 focused tests passed with warnings
  treated as errors, covering schema validation, model discovery, rate limits,
  HTTP failures, image details, compaction, and event decoding.
- Event-decoder regressions cover unrelated fields, unknown events, original
  nested error paths, missing optional fields, rate-limit metadata, and typed
  search progress with raw output preservation.
- Python verification suite: 38 tests passed.
- macOS offline smoke verification, including process-reopen recovery: passed.
- Signed iOS simulator build: passed.
- API audit: the two documented public type changes and intended package-internal
  type changes; no removed declarations or changed protocol requirements.
- Source-size limit and `git diff --check`: passed.
