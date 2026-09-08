# Deeper audit — 7 September 2026

**Status — 8 September 2026:** All seven findings below have been addressed in the working tree, including the disabled-debug logging cleanup. The descriptions preserve the original failure modes. Permanent coverage is in [DeepAuditRegressionTests](../Tests/CodexKitTests/DeepAuditRegressionTests.swift), [CompactionTransportTests](../Tests/CodexKitTests/CompactionTransportTests.swift), [PreparationCancellationTests](../Tests/CodexKitTests/PreparationCancellationTests.swift), and [OneShotValidationTests](../Tests/CodexKitTests/OneShotValidationTests.swift).

**Verification — 8 September 2026:** 497 package tests executed: 495 passed, two opt-in checks skipped, zero failures. All 29 new regression tests passed. The signed iOS simulator demo build passed. All 204 production Swift files meet the 600-line limit, and `git diff --check` is clean. Live-provider and opt-in pipeline benchmark execution were not part of this run.

The image acceptance test exposed a related response-side gap: compact responses retained inline images in provider context and omitted their attachments. This is also fixed. Compacted image messages and generated images now retain attachments for blob storage, and their provider payload contains references that resolve after SQLite/Realm reopening.


## Status and scope

Seven additional findings remain open. Seven temporary diagnostic tests produced ten expected assertion failures, with no unexpected errors. No production sources were changed during this audit. The diagnostic source and results were saved outside the test target; the latest complete ordinary suite remains the previous run of 468 cases: 466 passed and two opt-in tests skipped.

This review follows the [initial audit](codebase-audit-2026-09-07.md) and [four subsequent fixes](followup-audit-2026-09-07.md). It examined how those changes interact with context compaction, cancellation before execution ownership, alternate structured-response entry points, policy decoding, provider context, and persistence. Additional inspection covered observation queues, tool-result deduplication, storage coordination, attachment staging, migration, and memory queries. This is a targeted review of failure paths, not a claim that every remaining branch is correct.

Evidence: [diagnostic source](/tmp/codexkit-deep-audit-2026-09-07/DeepAuditProbeTests.swift) and [diagnostic results](/tmp/codexkit-deep-audit-2026-09-07/diagnostic-tests.log). These are local temporary artifacts. To reproduce, copy the source into `Tests/CodexKitTests` and run `swift test --filter DeepAuditProbeTests`. The assertions describe the desired behavior and failed on the original reviewed working tree. They have now been promoted and expanded into permanent regression coverage.

## 1. P1 — Compaction can erase a newer completed turn from model context

[AgentRuntime+ContextCompaction.swift:234](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+ContextCompaction.swift:234) captures the current context, then awaits remote compaction. The public method does not reserve the thread, and the continuation installs its result without checking whether the context changed while awaiting it.

**Reproduction:** Start manual compaction and hold the backend response. Complete another user turn on the same thread, then release compaction. Both operations report success, but the newer user message disappears from effective context. Reopening SQLite preserves this stale context. A control assertion confirms that the visible transcript still contains the newer message: this is loss of model context, not deletion of transcript records.

**Change:** Give manual compaction exclusive ownership of thread context while it runs, coordinated with turn startup. Also validate the context revision before committing a compaction result. Concurrent compactions and deactivation/restore interactions should have explicit behavior. Rejecting conflicting operations is simpler than attempting an implicit merge of opaque provider state.

**Acceptance:** A concurrent send either receives a clear busy error or remains represented after compaction. Verify both in-memory state and SQLite/Realm reopen behavior. No stale compaction marker should hide newer history.

## 2. P2 — Compaction sends internal image references to the provider

[CodexResponsesBackend+Compaction.swift:48](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesBackend+Compaction.swift:48) copies provider-context items directly into the request. Normal turn requests first expand the SDK's internal image references using attachment bytes; compaction skips that step.

**Reproduction:** Externalize an image-bearing provider context, then inspect the compact request body. Its `image_url` contains `codexkit-image-ref:data-url:…` instead of the original image data URL. This establishes an invalid transport representation without requiring a live provider request.

**Change:** Restore image references from effective-history attachments before constructing compact input. Share the request-boundary transformation with ordinary turns. Missing attachments should produce the existing explicit missing-image error. Keep stored bytes in disk blobs and database payloads reference-based.

**Acceptance:** Test image-bearing client-managed contexts, missing blobs, and the server-managed previous-response path. Outbound compact payloads must contain no internal reference strings.

## 3. P2 — An already-cancelled caller can start and persist a new execution

[AgentRuntime+TurnExecution.swift:14](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+TurnExecution.swift:14) begins preparation without checking cancellation. [AgentRuntime+Execution.swift:21](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+Execution.swift:21) subsequently launches a separate producer, whose cancellation state does not reject the already-cancelled caller's request.

**Reproduction:** Cancel the calling task before invoking `runtime.start`. The call still returns an execution, backend readiness succeeds, the execution completes, and user/assistant messages are persisted.

**Change:** Check cancellation before reserving a thread or writing a user message, and again before transferring ownership to the producer. Define cleanup when cancellation happens during preparation. Keep the existing rule that cancelling an individual readiness waiter does not cancel an accepted execution.

**Acceptance:** Cover cancellation before preparation and during a paused preparation write, across plain/structured and persistent/ephemeral entry points. A request cancelled before starting must not launch a backend or execute tools.

## 4. P2 SDK consistency — One-shot structured output skips local schema validation

[AgentRuntime+OneShotMessaging.swift:122](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+OneShotMessaging.swift:122) only performs Swift decoding. It does not receive the declared schema. Streaming structured output now validates its schema locally, so the two entry points enforce different contracts.

**Reproduction:** A custom backend returns `{"priority":"impossible"}` for a format whose allowed values are `low` and `high`. `send(..., response:)` returns the decoded value successfully. The same class of value is rejected by the streaming validator.

**Scope:** The built-in one-shot path requests provider-side `json_schema` enforcement, and the current guide explicitly describes local validation for streaming. This finding is a client-side consistency gap exposed by custom backends; the probe does not establish that the live provider returns invalid strict-schema output.

**Change:** Use a common schema acceptance step before committing a one-shot assistant result and marking the turn successful. Preserve the distinction between partial snapshots and final output. Decide and document how unsupported raw schemas behave across both paths.

**Acceptance:** Enum, required-property, additional-property, and decoding failures should have consistent terminal status and persistence behavior across `send`, `sendWithSummary`, and structured streaming.

## 5. P2 — Remote compaction bypasses unauthorized-session recovery

[AgentRuntime+ContextCompaction.swift:389](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+ContextCompaction.swift:389) invokes compaction directly. The compact endpoint also returns a generic error without HTTP metadata at [CodexResponsesBackend+Compaction.swift:115](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesBackend+Compaction.swift:115).

**Reproduction:** Queue an HTTP 401 followed by a successful compact response and provide a working session-recovery provider. Manual `remoteOnly` compaction fails with `responses_compact_failed`, and the recovery provider is never called. By inspection, `preferRemoteThenLocal` handles the same failure by falling back locally instead of first attempting authentication recovery.

**Change:** Preserve typed HTTP details and run remote compaction through the existing recovery boundary, including the same-account guard. Retry only before accepting a compact result. Explicitly distinguish authentication recovery, transient failures, and intentional local fallback.

**Acceptance:** Test successful refresh, replacement-account rejection, cancellation, and failed recovery for both compaction strategies.

## 6. P2 hardening — Compact responses remain unbounded

[CodexResponsesBackend+Compaction.swift:96](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesBackend+Compaction.swift:96) buffers the entire response with `URLSession.data`, then parses and copies it. It bypasses the response-byte limit used by normal model turns, including for error bodies.

**Reproduction:** Configure `maximumResponseBytes: 8` and return a larger valid compact response. Compaction accepts it. This demonstrates that the configured limit is not applied; an out-of-memory failure was not deliberately induced. If compact responses need a separate budget, that budget must be explicit and finite.

**Change:** Stream and bound success/error bodies before decoding, reject oversized declared lengths early, and check actual bytes for unknown or understated lengths. Cancel rejected downloads. Apply an explicit timeout to standalone manual compaction as well.

**Acceptance:** Test exact limits, oversized responses, chunked/understated lengths, bounded errors, and cancellation while receiving bytes.

## 7. P2 hardening — A misspelled top-level policy key still loads as unrestricted

[AgentDefinitionSource.swift:75](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentDefinitionSource.swift:75) validates keys inside a recognized `executionPolicy`, but ignores unknown keys at the document root.

**Reproduction:** A skill containing `executionPolciy: {"allowedToolNames":[],"maxToolCalls":0}` loads successfully with `executionPolicy == nil`. The recent fix correctly rejects malformed fields inside `executionPolicy`; this additional typo case never enters that validation path. Normal approvals and global execution limits still apply.

**Change:** Validate top-level skill-document keys too. If extensions are needed, give metadata an explicit namespace or define a deliberate permissive mode; the default policy-bearing format should report misspellings clearly.

**Acceptance:** Cover policy-key misspellings, unexpected root keys, correct policy objects, explicit null, and any supported metadata extension.

## Performance and SDK follow-up

The original compaction path evaluated payload sanitization and JSON pretty-printing before `logger.debug` checked whether it was enabled, at [request logging](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesBackend+Compaction.swift:84) and [response logging](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesBackend+Compaction.swift:121). The normal streaming transport was already fixed. Compaction now uses the same logging guard. No speedup percentage is claimed.

The highest-value simplifications are one thread-operation ownership mechanism, shared bounded HTTP response handling, and one final structured-output acceptance pipeline. These address the duplicated behaviors behind the findings rather than adding more public overloads. Keep the separate core/UI/database products and attachment sidecars.

Extend deterministic tests with a matrix of startup, completion, compaction, cancellation, and persistence-reopen boundaries. The [CI workflow](/Users/tima/Projects/AssistantAI/CodexKit/.github/workflows/ci.yml) now executes the signed simulator verifier and requires fresh passing SQLite/Realm results, including database reopening. This passed locally on iOS 26.5; see [release readiness](release-readiness-2026-09-08.md). Live image-plus-compaction checks remain gated on an authenticated session.

The [8 September workload measurements](performance-2026-09-08.md) now cover request construction and compaction with image-heavy histories, database paging at 2,000/20,000 records, and cancellation latency under slow consumers. The existing parser/pipeline benchmarks are valuable, but they do not establish performance for these workloads. No physical-device energy or live-provider result was measured in this audit.

## Suggested implementation order

1. Coordinate compaction with thread writes and reject stale commits; make top-level policy parsing strict.
2. Fix image-reference expansion, authentication recovery, and bounded ingestion together in the compact request path; make its logging lazy.
3. Close cancellation-before-start and one-shot schema-consistency gaps.
4. Promote the probes to permanent coverage, rerun package/iOS verification, add simulator execution to CI (completed), and run authenticated provider checks when a session is available.
