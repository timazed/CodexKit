# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning.

## [Unreleased]

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

[Unreleased]: https://github.com/timazed/CodexKit/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/timazed/CodexKit/releases/tag/v1.1.0
[1.0.0]: https://github.com/timazed/CodexKit/releases/tag/v1.0.0
