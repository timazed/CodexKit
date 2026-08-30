# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

## [2.0.0-alpha.25] - 2026-08-30

### Added

- Added first-class memory attribution to `AgentTurnResult`, including the exact applied snapshot, explicit omission reasons, top-level request correlation, and authoritative nonpersistent attribution for ephemeral `sendWithSummary` calls without a second memory query.

## [2.0.0-alpha.24] - 2026-08-29

### Added

- Added the optional `CodexKitRealm` product with `RealmRuntimeStateStore` and `RealmMemoryStore`.
- Added protocol-based runtime and memory store migration utilities for copying existing data between adapters.
- Added `MemoryTextMatchPolicy` with any-token, minimum-token, and all-token eligibility, plus exact token coverage and query-execution details in match explanations.
- Added an optional background-activity provider and an iOS implementation that gives active turns the system's finite background completion window.
- Added configurable memory instruction placement with `.beforePersonas`, `.beforeSkills`, and backward-compatible `.afterSkills` anchors.
- Added durable memory-attribution snapshots to completed-turn and context-compaction history, non-blocking observer notifications, host request correlation, completed-turn result APIs, detailed instruction previews, and conservative renderer attribution.

### Changed

- Context compaction now resolves active semantic skill instructions without turn-only execution-policy wording, records memory only when an instruction-aware backend applied it, skips empty pre-turn history, and never compacts the pending request before sending it.
- Moved `SQLiteRuntimeStateStore` and `SQLiteMemoryStore` into the optional `CodexKitSQLite` product so the core `CodexKit` product no longer depends on GRDB.
- Updated the demo and package documentation to select concrete persistence adapters only in the runtime composition layer; the demo now links both adapters and can switch its runtime and memory stores between SQLite and Realm.
- Made Realm and SQLite store locations CodexKit-managed and removed host-provided database URLs from their public APIs, preventing application-owned databases from being opened or migrated with CodexKit schemas by mistake. Existing SQLite databases at arbitrary alpha-era locations are not discovered automatically.
- Updated the demo's lazy-store restart path to query persisted thread metadata, keep stored threads visible while signed out, and resume a selected thread on demand.
- Pushed SQLite memory filtering, list ordering and limits, diagnostics aggregation, and expiry pruning into indexed database queries so irrelevant records are not decoded in memory.
- Pushed Realm runtime history and typed metadata queries, plus Realm memory structural filtering, ordering, and expiry pruning, into indexed Realm operations before result materialization; Realm memory diagnostics now use one transactionally maintained snapshot per namespace.
- Changed Realm history writes to append and redact only the affected records instead of decoding and rewriting an entire thread, and bounded generic SQLite history paging and latest-structured-output queries at the database layer.
- Added SQLite runtime query indexes for thread status and ordering, pending states, snapshots, turn-scoped history, and context generation.
- Made generic history queries honor ascending and descending order consistently across stores, including timestamp ties and sort-bound cursors.
- Replaced encoded memory payloads and duplicated query projections with structured adapter schemas: SQLite stores ordered evidence, tags, and related IDs in normalized tables, while Realm stores queryable collections as indexed linked entities and the remaining rule fields as native properties.
- Split Realm memory construction, queries, diagnostics, models, and schema migration into focused components under the repository's 600-line source-file limit; `RealmMemoryStore.builder()` owns the dedicated Realm configuration and connects the standalone migration component.
- Replaced adapter-specific weighted ranking with explicit portable `importanceThenRecency` and `recencyThenImportance` profiles. Text and structural criteria are predicates and no longer change result order through adapter-specific relevance scores.
- Added SQLite composite order indexes and normalized search-token predicates that preserve native index ordering without temporary sorts, plus a Realm-native multi-column sort with a bounded result prefix, keeping candidate scanning and ranking out of Swift.
- Added explicit memory match explanations so persistent stores' database-native execution is not misrepresented as a weighted relevance score.
- Replaced the ambiguous ranking-method explanation with independent ranking-profile and execution-method fields, and made runtime memory selection use ranking cursors plus the exact remaining prompt budget so persistent stores skip oversized rows inside the database.
- Made SQLite and Realm memory-store preparation asynchronous, lazy, and single-flight so construction does not perform schema migration or Realm opening synchronously.
- Split the Realm runtime, SQLite runtime, and Responses turn runner into focused source files so every production Swift source remains within the 600-line repository limit.
- Changed SQLite and Realm archive, delete, compaction, and expiry paths to use set-based database mutations, and included the memory prompt header in the configured character budget.
- Made generic history pages explicitly forward- or backward-directed and changed runtime and memory adapter migrations to stream, verify, and roll back bounded batches instead of materializing whole stores.
- Made the active working set and durable thread catalog explicit through `activeThreads()` and `persistedThreads(_:)`, so lazy restoration cannot be mistaken for data loss.
- Moved aggregate memory-budget packing into the memory-store query contract. SQLite now selects a deterministic ranked prefix in one window query, while Realm evaluates one indexed native result stream. Neither adapter searches lower-ranked rows in application memory for a smaller replacement.

### Fixed

- Preflight memory attribution before backend execution with conservative identifier headroom, validate queries and query-conformant custom-store results before rendering, enforce renderer and renderer-metadata budgets, propagate cancellation through memory retrieval, completion, compaction, and attribution-history paging, freeze the turn's original model settings in completed attribution, validate every backend event against the active turn, make accepted completion terminal, return durable attribution newest-first, bound attribution-history scans and aggregate payloads, clear compaction summary previews during redaction, preserve store-validation details in diagnostics, and require a matching completion summary for persisted memory applications.
- Bounded SQLite memory ranking to an index-ordered `limit + 1` candidate window before aggregate packing, made runtime persistence failure recovery generation-safe across concurrent callers, and preserved unrelated thread groups after a batch failure.
- Kept Realm-repaired attachments when a later promotion fails, made missing or duplicate Realm dedupe ownership fail closed, and bounded tool-image, base64-image, SSE-event, and HTTP-error-body ingestion before materialization.
- Made attachment paths traversal-safe, content-addressed, and adapter-specific so SQLite and Realm files with the same basename cannot share or overwrite sidecars.
- Added durable SQLite and Realm attachment cleanup queues, post-commit reconciliation, legacy-sidecar migration, and generation-based file-store snapshots so interrupted writes and cleanup retry safely.
- Made legacy file imports retry after failed attempts, scoped SQLite structured-output identities to their thread, and made Realm memory composite and dedupe identities collision-safe and transactionally unique.
- Avoided loading attachment bodies while rebuilding summaries after redaction and removed Realm's per-thread latest-structured-output query loop.
- Replaced startup-wide attachment payload decoding with normalized SQLite and Realm attachment-reference indexes, and bounded post-redaction summary rebuilding to indexed latest-record projections.
- Added transactional SQLite and Realm migrations into their normalized memory schemas, rejected invalid memory records, non-finite query thresholds, and negative budgets, and made history-page overfetch arithmetic safe at `Int.max`.
- Aligned exact Unicode token matching across all memory adapters and replaced redundant SQLite and Realm bulk-write lookups with set-based constraint checks so large batches remain transactional without per-record database queries.
- Coalesced Realm diagnostics deltas across bulk mutations and migrated legacy aggregate rows into structured per-namespace snapshots, keeping diagnostics reads to one primary-key lookup without adding a second write pipeline.
- Moved Realm memory mutations onto actor-isolated Realm instances and Realm's native asynchronous write serialization, keeping collision checks and managed-object lookup inside the transaction across concurrent store instances.
- Replaced Realm memory dedupe string references with native linked claim objects and report dangling or mismatched ownership as integrity errors instead of silently repairing it during mutation.
- Preserved the demo's saved-thread catalog across logout and app relaunch, separated custom SQLite and Realm files, and surfaced persistence initialization errors instead of crashing.
- Made runtime-store preparation single-flight, moved Realm runtime access to one actor-isolated asynchronously opened Realm with native asynchronous writes, and serialized database-plus-attachment mutations across store instances.
- Made SQLite expiry pruning one atomic delete, added bounded busy handling for concurrent store instances, and made memory migration prevalidate every requested namespace before copying keyset pages.
- Replaced record-scanning SQLite diagnostics with trigger-maintained keyed snapshots and added composite ranking indexes for queries that include archived memories.
- Pushed minimum-token matching and exact selected-record token counts into SQLite and Realm queries, keeping eligibility work in the database while materializing only the bounded result set.
- Canonicalized signed-zero importance ordering in both persistent stores and made zero-character query behavior consistent.
- Externalized image bytes from durable cached context, tool results, tool-interaction history, and provider state; SQLite and Realm transactions now persist only staged attachment references and remove promoted files after failed commits.
- Added an advisory per-store process lock around database-plus-sidecar mutations, recovered abandoned attachment staging on startup, and made generation-based file-store updates atomic across store instances.
- Made failed Realm opening single-flight retries generation-safe.
- Made file manifests fail closed on malformed or future versions, validated generation paths, and migrated released inline context images without risking an empty legacy-state rewrite.
- Avoided restaging unchanged content-addressed images, added durable promotion journals for process-crash recovery, and reduced normal startup cleanup to indexed interrupted/queued keys after one compatibility reconciliation.
- Rejected memory compactions that list their replacement as a source, preserved retained history sequences during adapter migration, and removed empty Realm diagnostics snapshots after predictable one-pass removal aggregation.
- Added stable keyset cursors for thread metadata, ranked memory queries, and memory lists; migrations now preserve tied timestamps without offset scans.
- Rejected same-store migrations and unsafe non-empty overwrites, coordinated built-in persistent runtime and memory migrations exclusively across instances and processes, limited rollback to migration-owned IDs, and surfaced rollback failures.
- Unified incremental and snapshot history validation across in-memory, file, SQLite, and Realm stores, including retained-history gaps and item ownership checks.
- Made current file-store generations fail closed on missing or legacy-shaped history files, avoided decoding unrelated contexts during targeted reads, and added content-digest verification plus repair for externalized image attachments.
- Propagated cancellation through runtime, backend, and SSE producer tasks so an expired iOS background allowance records a failed turn instead of leaving stale streaming state.
- Bounded memory query tokens, result limits, and combined structural filters to prevent pathological database statements and in-memory query work.
- Bounded runtime query defaults, aggregate query materialization, filter sets, write batches, redaction matches, message and context text, embedded JSON depth and node counts, tool-result content, and attachment batches; oversized operations now fail before mutation or unbounded decode across every bundled store.
- Validated decoded runtime and memory payloads against their indexed SQLite and Realm projections, bounded normalized child collections, and added a batched Realm projection backfill so malformed, oversized, stale, or mismatched persisted rows fail closed instead of being materialized as trusted state.
- Reworked whole-thread attachment deletion, snapshot replacement, promotion recovery, and orphan reconciliation to use database-native selection plus bounded storage-key batches rather than thread-sized in-memory sets.
- Made diagnostics and bulk-memory cardinality explicit and bounded, retained constant-time snapshot reads, and added adversarial coverage for oversized contexts, aggregate payloads, corrupt normalized collections, structured payloads, duplicate redaction matches, large attachment sets, and migration/recovery batch boundaries.
- Persisted each thread's next history sequence as an atomically advanced database field, replacing activation and append-time aggregate scans in both adapters.
- Added indexed history relationship keys and relationship-complete activation windows so message/output and tool-call/result records cannot be split at a hydration boundary.
- Collapsed unreleased schema iterations to release boundaries: Realm runtime and memory stores remain schema v1, SQLite runtime advances from released v2 to v3, and SQLite memory advances from released v1 to v2.
- Added an exact-tag release gate so manually dispatched releases cannot publish an untagged or mismatched revision.

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

[Unreleased]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.24...HEAD
[2.0.0-alpha.24]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.23...v2.0.0-alpha.24
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
