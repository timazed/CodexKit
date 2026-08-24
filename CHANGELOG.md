# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

## [2.0.0-alpha.23] - 2026-08-24

### Added

- Added lazy, primary-key thread activation for SQLite runtimes with configurable message, token, and history-record bounds.
- Added `deactivateThread(id:)` so hosts can release hydrated working sets without deleting durable history, summaries, compaction state, or semantic memory.
- Added durable completed-tool interaction context that preserves invocation IDs, arguments, and results for exact Responses replay.

### Changed

- SQLite runtime startup now prepares metadata without decoding persisted threads or history, and thread resumption hydrates only the requested bounded context.
- Runtime persistence now detaches immutable per-thread batches, serializes store writes through an isolated coordinator, and publishes observations from committed snapshots only.
- SQLite history appends now validate and allocate against the persisted per-thread maximum sequence inside the database transaction.

### Fixed

- Fixed cold SQLite thread resumption failing with duplicate history sequence numbers after a process relaunch.
- Prevented failed persistence appends from poisoning later writes for unrelated threads.
- Retried same-thread resume sequence contention across concurrent runtimes while preserving monotonic history ordering.
- Preserved closed conversation turns, tool call/result pairs, structured output, and compaction boundaries during legacy history hydration.

## [2.0.0-alpha.22] - 2026-08-21

### Added

- Added explicit client-managed and server-managed Responses state modes through `CodexResponsesStateManagement`.
- Added opaque provider context persistence so backend-specific response state survives runtime reloads and remote compaction.

### Changed

- Client-managed Responses turns now request, preserve, and replay encrypted reasoning items in their original output order.
- Server-managed Responses turns now send `store: true` and chain stored responses with `previous_response_id` without replaying prior history.

### Fixed

- Prevented encrypted reasoning content from appearing as visible messages or being converted into compaction summaries.
- Redacted `encrypted_content` values from request, response, stream, compaction, and HTTP error logs.
- Discarded incomplete response items before retrying an interrupted stream.

## [2.0.0-alpha.21] - 2026-07-14

### Added

- Added `none`, `minimal`, `max`, `ultra`, and forward-compatible custom reasoning efforts, with Ultra mapped to the backend-compatible `max` inference value.
- Added the open-ended `CodexModel` identifier and `CodexModelInfo` catalog for GPT-5.6 Sol, Terra, Luna, GPT-5.5, GPT-5.4, GPT-5.4 Mini, GPT-5.3 Codex Spark, GPT-5.2, and Codex Auto Review.
- Added every user-facing catalog model to the demo with model-specific effort choices.

### Changed

- Updated the built-in backend and demo defaults to `gpt-5.6-sol` at low reasoning effort.
- Preserved string-based model configuration while adding typed backend and thread configuration conveniences.

### Fixed

- Reported model-specific context windows from each thread's configured model, including 372,000 tokens for GPT-5.6, 128,000 for GPT-5.3 Codex Spark, and 272,000 for the earlier catalog models.

## [2.0.0-alpha.20] - 2026-07-14

### Added

- Added `AgentRuntime.useSession(_:)` for loading and persisting a supplied ChatGPT session without interactive sign-in.
- Added the sendable `AgentTurnStream` and `AgentRuntimeObservationPublisher` value types for backend turn delivery and runtime observation.

### Changed

- Made `ChatGPTAuthProvider` and `KeychainSessionSecureStore` the concrete runtime authentication and session-storage configuration types.
- Made backend defaults and context-window metadata asynchronously readable so actor-backed custom backends no longer need nonisolated witnesses.
- Made runtime observation access actor-isolated and made `MemoryWriter.resolve(_:)` actor-isolated.

### Fixed

- Prevented stale demo observation-binding tasks from updating the active thread after a runtime or thread switch.

## [2.0.0-alpha.19] - 2026-05-31

### Added

- Added `AgentImageGenerationClient` and supporting models for authenticated image generation and editing with prompt and image inputs.

## [2.0.0-alpha.18] - 2026-05-26

### Fixed

- Retried dropped Responses streams after assistant text deltas when no assistant message or tool side effect has been committed yet.
- Added retry decision metadata to no-retry backend logs so blocked retries explain whether they hit max attempts, non-replayable output, or a non-retryable error.

## [2.0.0-alpha.17] - 2026-05-25

### Fixed

- Retried wrapped URL transport failures, including nested `NSURLErrorDomain` and `URLError` network connection loss errors, according to the configured retry policy.

## [2.0.0-alpha.16] - 2026-05-23

### Fixed

- Fixed generated image turns by keeping assistant image attachments out of replayed Responses request content.

### Changed

- Split the runtime agent model definitions into focused source files.
- Made SwiftPM target paths explicit and documented that the checked-in demo app is not part of published package products.

## [2.0.0-alpha.15] - 2026-05-22

### Changed

- Updated the demo app's default Codex model to `gpt-5.5`.
- Added hosted Responses image generation support, generated-image metadata, flat-file attachment persistence, and demo rendering.

## [2.0.0-alpha.14] - 2026-05-13

### Changed

- Removed prompt-only section labels from compiled persona and skill instructions to avoid sending debug metadata to the backend.
- Shortened request-visible context, options, and streamed structured-output helper prompts to reduce input token overhead.
- Coalesced redundant pending runtime store writes before persistence while preserving append/delete semantics.
- Added `.verbose` SDK logging for wire-level streaming payloads, keeping `.debug` focused on readable request/response and lifecycle diagnostics.
- Replaced the demo app's developer logging toggle with an `Off` / `Debug` / `Verbose` log-level picker.

## [2.0.0-alpha.13] - 2026-05-04

### Changed

- Changed persona precedence so thread personas replace runtime/backend personality and request-level persona overrides replace inherited thread/runtime behavior for that turn instead of appending to it.
- Replaced request skill overrides with `AgentSkillSelection` so turns can explicitly use thread skills, replace them, or append request-local skills.

## [2.0.0-alpha.12] - 2026-04-29

### Fixed

- Fixed a GitHub Actions loopback OAuth test race when an available localhost port is reused before the listener starts.

## [2.0.0-alpha.11] - 2026-04-29

### Fixed

- Hardened ephemeral request tests for GitHub Actions runner differences.

## [2.0.0-alpha.10] - 2026-04-29

### Added

- Added `RequestExecutionMode.ephemeral` for fast transient turns that skip prior thread history replay, context compaction, transcript/history persistence, pending state writes, and memory capture.
- Added demo app support for testing ephemeral turns from the Behavior Lab.

## [2.0.0-alpha.9] - 2026-04-29

### Added

- Added `AgentThreadConfiguration` so threads can carry their own model and reasoning effort.
- Added runtime APIs for updating thread configuration after thread creation.

### Changed

- Routed Codex responses requests and context compaction through thread-level model and reasoning configuration, with backend defaults as fallback.
- Updated the demo app and docs to create threads with model configuration and adjust reasoning per active thread.
- Restored the demo app's Xcode workspace metadata so local `CodexKit` and `CodexKitUI` package products resolve consistently.

## [2.0.0-alpha.5] - 2026-04-13

### Added

- Added typed, structured request APIs through `AgentMessageRequest<Input>` and structured section support for machine-context turns.
- Added support for running runtime turns with mixed freeform text and structured input/section payloads in streaming and one-shot message paths.

### Changed

- Renamed `GRDBRuntimeStateStore` to `SQLiteRuntimeStateStore` and aligned documentation/examples with the new naming.
- Improved runtime logging ergonomics to make request execution and turn lifecycle diagnostics easier to interpret.

## [2.0.0-alpha.1] - 2026-03-22

### Added

- Schema-driven structured output support through `AgentStructuredOutput`, `AgentStructuredOutputFormat`, and the Swift-friendly `JSONSchema` DSL.
- Imported/share-friendly message construction through `AgentImportedContent`.
- Dedicated structured output demo tab plus App Intents / Shortcuts examples in the demo app.
- Thread detail navigation in the demo app so conversation views are separated from the main dashboard.

### Changed

- Simplified the runtime messaging API so plain text uses `sendMessage`, typed replies use `sendMessage(..., expecting:)`, and streaming uses `streamMessage`.
- Updated the demo app to better separate assistant controls, structured output demos, and thread views.
- Expanded README coverage for structured output, imported content, and App Intents integration.

## [1.1.0] - 2026-03-21

### Added

- Runtime skill support with thread-pinned skills, per-turn skill overrides, and execution-policy enforcement for allowed tools, required tools, tool sequence, and max tool calls.
- Dynamic persona and skill loading from local files and remote URLs through `AgentDefinitionSource`.
- Resolved-instructions preview support so host apps can inspect the final compiled instructions for a turn.
- Transient request retry/backoff policy support in the Codex responses backend.
- Configurable reasoning effort (`low`, `medium`, `high`, `xhigh`) for `gpt-5.4` style thinking control.
- Demo app UI for switching thinking level on future requests.

### Changed

- Added CLI-style unauthorized-session recovery so runtime operations can refresh and retry once after auth expiry or invalidation.
- Improved the demo app’s skill and Health Coach flows to better show persona, skill, and tool orchestration together.
- Expanded README coverage for retries, skills, dynamic definition sources, and reasoning effort configuration.

## [1.0.0] - 2026-03-20

### Added

- Stable `CodexKit` + `CodexKitUI` runtime surface for iOS agent integration.
- ChatGPT auth with `.deviceCode` and `.oauth` (localhost loopback callback flow).
- Threaded runtime state restore, streaming output handling, and approval-gated tool execution.
- Layered persona model (base instructions, thread persona stack, per-turn override).
- Text + image user input support and assistant image attachment hydration.
- Demo iOS app with:
  - dual auth flows
  - tool registration and logging
  - persona demos
  - Health Coach tab with HealthKit integration and proactive AI-generated coaching feedback
  - local reminder scheduling

### Changed

- Refactored demo app into smaller Swift files for clearer ownership and readability.
- Updated README docs with production setup guidance and end-to-end examples.

[Unreleased]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.23...HEAD
[2.0.0-alpha.23]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.22...v2.0.0-alpha.23
[2.0.0-alpha.22]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.21...v2.0.0-alpha.22
[2.0.0-alpha.21]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.20...v2.0.0-alpha.21
[2.0.0-alpha.20]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.19...v2.0.0-alpha.20
[2.0.0-alpha.19]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.18...v2.0.0-alpha.19
[2.0.0-alpha.18]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.17...v2.0.0-alpha.18
[2.0.0-alpha.17]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.16...v2.0.0-alpha.17
[2.0.0-alpha.16]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.15...v2.0.0-alpha.16
[2.0.0-alpha.15]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.14...v2.0.0-alpha.15
[2.0.0-alpha.14]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.13...v2.0.0-alpha.14
[2.0.0-alpha.13]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.12...v2.0.0-alpha.13
[2.0.0-alpha.12]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.11...v2.0.0-alpha.12
[2.0.0-alpha.11]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.10...v2.0.0-alpha.11
[2.0.0-alpha.10]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.9...v2.0.0-alpha.10
[2.0.0-alpha.9]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.8...v2.0.0-alpha.9
[2.0.0-alpha.5]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.4...v2.0.0-alpha.5
[2.0.0-alpha.1]: https://github.com/timazed/CodexKit/compare/v1.1.0...v2.0.0-alpha.1
[1.1.0]: https://github.com/timazed/CodexKit/releases/tag/v1.1.0
[1.0.0]: https://github.com/timazed/CodexKit/releases/tag/v1.0.0
