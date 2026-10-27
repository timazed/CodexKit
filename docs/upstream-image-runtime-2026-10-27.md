# Upstream image and runtime update — October 27, 2026

Audited local `codex-src` at `2cab11ca4` against CodexKit 2.0.0.

## Image allowance compatibility

Upstream `166aed985` recognizes `imagegen_premium` alongside `image_gen`.
Swift and TypeScript now preserve the matching bucket ID and reset time. An
explicit active bucket takes precedence over unrelated header telemetry. Body
`resets_at` takes precedence; otherwise the latest reset among exhausted windows
of the selected bucket is used. Missing reset times remain unknown. No automatic
image request retry is added.

## Image progress and the desktop percentage loader

The audited `codex-rs/codex-api/src/endpoint/images.rs` executes a single JSON POST
and decodes the completed body. The image extension backend uses that client.
Neither this contract nor CodexKit's authenticated `/images/generations` and
`/images/edits` path exposes generation percentage. Read-only inspection of the installed desktop app then located
`webview/assets/image-loading-progress-badge-72f0f3fdfcab.js` inside
`/Applications/ChatGPT.app/Contents/Resources/app.asar`. That UI computes progress
from elapsed time, starting at 3%, reaching 90% at 45 seconds, and asymptotically
approaching a 99% cap. It updates every 500 ms while visible. It does not consume
server generation percentages. No installed application files were modified.

Swift `generate`/`edit` and TypeScript `executeImage` accept optional `onProgress`
callbacks with `requesting`, `receiving`, `decoding`, and `completed` stages.
Callbacks are awaited in order; keep them short. `completed` means image bytes
have passed validation, not that a host has persisted or displayed them. Failure
and cancellation do not fabricate a completed stage. Cancellation from a callback
still cancels the operation. TypeScript callback failures use
`progress_callback_failed`. Without a callback, existing transport timing is
preserved. The legacy Swift Responses configuration emits requesting, receiving,
and completed; decoding happens as part of stream consumption.

Both demos use `AgentImageGenerationEstimate.percent(elapsedSeconds:)` to show
an explicitly labelled "Estimated …%" while the request runs. The TypeScript
package exports the equivalent `estimateImageGenerationProgress(elapsedSeconds)`.
These pure presentation helpers use the inspected time curve, never return 100,
and do not control retries, timeouts, or completion. A host stops its estimate on
success, failure, or cancellation. The demos start the clock at `.requesting`.
Receiving may still include server wait time. Transport stages are independent of
the estimate, and HTTP byte counts would measure transfer rather than computation.

The public Images/Responses APIs document partial image previews, but that does
not establish support on the authenticated Codex image route. We did not change
endpoints, add speculative stream parameters, or make billable live probes.
[Public image streaming documentation](https://developers.openai.com/api/docs/guides/image-generation#streaming).

## GPT-6.1 Terra

Upstream `126a0ee92` adds `gpt-6.1-terra`. The Swift constant, fallback catalog,
and picker list now include it, with text/image input, original image detail,
low default reasoning, low through ultra reasoning, and the upstream default
500,000-token window. The optional upstream maximum of 872,000 is not substituted
for the default. Server discovery and account access remain authoritative.

## Safety explanations

Upstream `118aae2a5` consumes `response.metadata` with
`metadata.openai_chatgpt_moderation_metadata.safety_recourse`.
Swift exposes validated guidance through `AgentRuntimeError.safetyRecourse` only
when the terminal provider code is the matching `bio_policy` or `cyber_policy`.
The original error code and message are preserved. Schema version, domain/topic,
source role/kind, text limits, and suggestion shape are checked. Command-like
suggestions are filtered. Raw metadata and source message IDs are not retained or
logged. Guidance is scoped to one HTTP response, cleared at completion/failure,
and preserved by retry/interruption error wrappers and Codable persistence.

Host applications may show the explanation and suggestions; suggestions are data,
not commands, and require explicit user selection before a new request. No
automatic rewrite, resubmission, or demo action is added. Loading-only metadata,
unsupported versions, and guidance arriving after a terminal failure are ignored.
The TypeScript bridge continues to expose its existing privacy-safe provider code;
it does not export free-text safety suggestions in its sanitized failure contract.

## Verification

- Full Swift regression suite with warnings treated as errors: 801 core tests
  (14 existing skips), plus 20 recovery integration tests, zero failures.
- After adding the presentation estimate: 31 focused Swift tests covering image
  progress/cancellation, quota handling, model metadata, and safety guidance passed.
- TypeScript: 256 tests, plus packed CommonJS, ESM, declaration and route-example
  consumer checks passed.
- Public API comparison against `main`: no breaking diagnostics for CodexKit or
  CodexKitUI; original image method and error initializer signatures are retained.
- Signed macOS demo smoke verification and iOS simulator build passed. Demo
  fixtures cover estimate capping and stopping after completion/cancellation.
- Source-size and whitespace checks passed. No live image generation was used.
