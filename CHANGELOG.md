# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

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

[Unreleased]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.10...HEAD
[2.0.0-alpha.10]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.9...v2.0.0-alpha.10
[2.0.0-alpha.9]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.8...v2.0.0-alpha.9
[2.0.0-alpha.5]: https://github.com/timazed/CodexKit/compare/v2.0.0-alpha.4...v2.0.0-alpha.5
[2.0.0-alpha.1]: https://github.com/timazed/CodexKit/compare/v1.1.0...v2.0.0-alpha.1
[1.1.0]: https://github.com/timazed/CodexKit/releases/tag/v1.1.0
[1.0.0]: https://github.com/timazed/CodexKit/releases/tag/v1.0.0
