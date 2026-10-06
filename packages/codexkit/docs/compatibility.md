# CodexKit compatibility fixtures

These are synthetic fixtures derived from the local CodexKit source at commit `f16d7b873c298e729d8f26cba18b6ffd70ec98e2`. They contain no real requests, credentials, accounts, or model output. `codexkit-fixture-model` is deliberately a non-live model identifier.

The library was imported from the standalone `CodexKitCloud` directory into this repository as `@timazed/codexkit-cloud@0.1.0`. Version `0.1.1` renames the npm package to `@timazed/codexkit` and moves it to `packages/codexkit`. Develop and release the library from this package directory. These packaging changes preserve the source and fixtures and do not update the compatibility pin or establish compatibility with every later Swift revision. Paths below are relative to the CodexKit repository root; the fixture path is relative to this npm package.

Sources used:

- `Sources/CodexKit/Runtime/CodexResponsesTransport.swift`: exact request body transmission, session/client request IDs, originator, content negotiation, tool-free recovery mode.
- `Sources/CodexKit/Runtime/CodexResponsesBackend+Models.swift`: `ResponsesRequestBody`, `ResponsesTextFormat`, and one-shot message serialization.
- `Sources/CodexKit/Runtime/CodexResponsesBackend+Recovery.swift`: frozen bytes and lowercase hexadecimal SHA-256.
- `Sources/CodexKit/Runtime/CodexResponsesEventPayload.swift`: terminal status/error checks and optional terminal output.
- `Sources/CodexKit/Runtime/JSONSchemaVocabulary.swift` and `AgentJSONSchemaValidator.swift`: supported assertions, local references, Unicode scalar lengths, and bounded validation.
- `Sources/CodexKit/Runtime/AgentStrictJSON.swift`: duplicate-key and UTF-8 rejection.
- `Tests/RecoveryIntegrationSupport/FixtureTransport.swift`: indexed output-item completion followed by `response.completed` without an output snapshot/status.

`test/fixtures/text-request.json` in the source checkout exercises the supported Swift body shape. Stream and schema fixtures are composed in the test files so each failure boundary is explicit. Tests hash the original fixture bytes and assert byte-for-byte transmission, including whitespace.

These tests characterize this TypeScript consumer. They are not newly published canonical CodexKit offload fixtures, a test of a Swift export API, or evidence of live provider authentication support. Future CodexKit-owned handoff fixtures should be imported unchanged and this compatibility pin updated alongside them.

Swift request export, request-level remote routing, history support, and importing backend results into Swift's normal persistence flow remain separate integration work. An API service also needs to own durable request IDs, job storage, result lookup after disconnection, authorization, and retry coordination. Importing this library adds none of those services and does not enable tool calling.
