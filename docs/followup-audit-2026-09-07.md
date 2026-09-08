# Follow-up audit and fixes — 7 September 2026

This review follows the [earlier audit and fixes](codebase-audit-2026-09-07.md). All four findings below are addressed in the working tree, with permanent regression coverage in [DefinitionValidationTests](../Tests/CodexKitTests/DefinitionValidationTests.swift) and [ToolOutputFidelityTests](../Tests/CodexKitTests/ToolOutputFidelityTests.swift).

A [subsequent deeper review](deep-audit-2026-09-07.md) identified seven further edge cases, including a top-level policy-key typo outside the nested-field validation fixed here. All seven were fixed on 8 September 2026, with 29 permanent regression tests and successful package/iOS build verification. See the deeper review for the completed work and remaining optional integration checks.

## 1. P1 — Malformed skill policies silently removed restrictions

The original loader suppressed execution-policy decoding failures and returned a skill with no policy. A JSON skill with `allowedToolNames: []` and a malformed string-valued `maxToolCalls: "0"` loaded successfully with the entire policy discarded. Runtime policy compilation also treated an empty allowlist as unrestricted.

**Fixed:** [AgentDefinitionSourceLoader](../Sources/CodexKit/Runtime/AgentDefinitionSource.swift) now decodes structured skills once and rejects malformed JSON, invalid policy types, unknown policy keys, invalid tool names, and negative call limits with `invalid_skill_definition`. A leading UTF-8 byte-order mark cannot bypass structured validation. Plain-text skills and absent, null, or empty policy objects remain supported. [Policy compilation](../Sources/CodexKit/Runtime/AgentRuntime+Skills.swift) now treats an explicit empty allowlist as disallowing every tool; `nil` remains unrestricted.

Coverage checks all policy fields, valid optional policies, plain text, byte-order marks, and an actual runtime call blocked by an empty allowlist.

## 2. P2 — Tool output lost every text block after the first

The adapter serialized only `primaryText`. A result containing `First result` and `Second result` reached the provider as only `First result`; fallback replies and effective compaction context had the same omission.

**Fixed:** [ToolResultEnvelope](../Sources/CodexKit/Tools/ToolModels.swift) provides one internal combined-text representation that joins all nonempty text blocks in order with blank-line separators. Provider input, fallback replies, and effective context use it. First-block previews retain `primaryText`.

Coverage inspects the next provider request body, the fallback assistant reply, effective context, mixed text/image rendering, and empty-result behavior. Reopening both SQLite and Realm stores also reconstructs every tool text block for model and compaction context.

## 3. P2 — Failed or non-image downloads became PNG attachments

The adapter accepted unsuccessful HTTP responses and defaulted unknown media types to PNG. Both a 404 HTML error body labeled `image/png` and a successful `text/html` response became image attachments.

**Fixed:** [The image adapter](../Sources/CodexKit/Runtime/CodexResponsesToolOutputAdapter.swift) requires a successful HTTP response. [Payload validation](../Sources/CodexKit/Runtime/RuntimeDownloadedImage.swift) detects a supported image type and decodes a tiny thumbnail through ImageIO before accepting the original bytes. Accepted formats are PNG, JPEG, GIF, WebP, HEIC, and HEIF. Byte limits and cancellation remain enforced; rejected downloads are cancelled. Invalid bodies are omitted from attachments.

Coverage includes HTTP failures even with valid image bytes, HTML with truthful or misleading headers, truncated data, PNG/JPEG/GIF with absent media headers or misleading URL extensions, byte preservation, oversized response headers, and cancellation. Storage remains unchanged: SQLite and Realm store attachment references; image bytes live in disk blobs.

## 4. P2 hardening — Definition downloads and file reads had no size bound

The loader previously buffered whole files and remote bodies before text/JSON decoding. Source inspection established this allocation risk; an out-of-memory failure was not deliberately reproduced.

**Fixed:** `AgentDefinitionSourceLoader.maximumDefinitionBytes` defaults to 1 MiB and applies to persona, skill, and direct text loading. Regular files are read in bounded chunks; remote responses are streamed. Known oversized lengths fail early, and the actual bytes are checked even when lengths are absent or understated. Oversized content throws `definition_too_large`; nonpositive limits throw `invalid_definition_limit`. See [configuration and migration behavior](personas-and-skills.md#dynamic-persona-and-skill-sources).

Coverage includes exact UTF-8 byte boundaries, a sparse 128 MiB file rejected by a small configured limit, known/unknown/understated HTTP lengths, both definition entry points, invalid limits, cancellation, and existing HTTP/UTF-8 errors.

## Verification scope

The final complete package run passed 466 tests, with two opt-in tests skipped and zero failures (468 total), including 20 new regressions. The signed iOS simulator demo build passed. All 202 production Swift files remain at or below 600 physical lines, and the diff passes whitespace checks. Local evidence: [package results](/tmp/codexkit-four-fixes-full-tests.log), [iOS build](/tmp/codexkit-four-fixes-ios-build.log).

The initial review used three temporary probes that produced four assertion failures for findings 1–3. Their [source](/tmp/codexkit-next-audit-2026-09-07/NextAuditProbeTests.swift) and [results](/tmp/codexkit-next-audit-2026-09-07/diagnostic-tests.log) are historical local artifacts; the permanent tests above supersede them.

Live-provider compatibility remains unverified because the checked environments have no current signed-in session. That is a verification prerequisite, separate from these resolved code findings.
