**CodexKit codebase audit — 7 September 2026**

**Resolution:** The nine reproduced bugs below are fixed in the working tree, with permanent coverage in `AuditRegressionTests.swift` and `StructuredValidationTests.swift`. The fixes also freeze tool registrations per turn, consolidate turn execution, avoid disabled-log payload processing, remove incremental-write normalization, and make structured parsing incremental with a payload bound. HTTP context-limit recovery, shared refreshes, replacement-session races, and tool replacement during approval have dedicated tests. The findings and line references below describe the audited baseline, not the updated files.

The follow-up also bounds retained live history with durable deduplication lookups, adds lossless bounded event queues across the HTTP/backend/runtime layers, and introduces tool/time/model-pass/response budgets. Provider output items and queued steering input are bounded. Regression coverage includes zero- and one-record history caches across SQLite/Realm runtime reloads, paused consumers with one-event queues, cancellation and approval deadlines, and byte budgets across retries and model passes.

The final SDK follow-up also implements the remaining design proposals: injectable session providers, execution handles with independent readiness/cancellation, async observation with bounded/coalesced policies, and typed HTTP/retry metadata. It additionally prevents cross-account unauthorized replay, honors server retry delays, normalizes non-finite delays, and bounds standalone image-response ingestion. Existing streaming and ChatGPT sign-in initializer calls remain available; configuration inspection properties for built-in auth are now optional. See [SDK integration](sdk-integration.md) and [migration notes](migration.md).

A subsequent review reproduced an additional P2 tool-result correlation bug: direct backend submissions accepted unknown, duplicate, and mismatched results, and a custom executor could return another call's identity. Pending results now belong only to registered calls; invalid submissions fail without consuming or replacing valid results, and completion/cancellation clear pending buffers. Executor identity mismatches become failed results of the original call before persistence. `ToolResultValidationTests` covers these cases, out-of-order submission, interrupted waits, and saved history. This finding was discovered after the original nine-item audit.

A further targeted cancellation review reproduced another P2 bug: after backend readiness, cancellation or a deadline while the initial runtime event queue was full could end the execution without calling the custom backend's interrupt handler. Backend cleanup now belongs to execution ownership and runs before terminal events, including failures before backend event consumption starts. `ExecutionCleanupTests` covers plain/structured cancellation, deadlines, and ordinary completion.

**Fix verification:** The complete package suite passes: 468 cases, with 466 passed, two opt-in cases skipped, and zero failures, including 20 new definition/tool-output tests, six tool-result regressions, and three execution-cleanup tests. Earlier optimized parser, full HTTP-to-SQLite pipeline, and SDK ownership checks also passed when explicitly run. The 100-turn pipeline processed 5,000 deltas in 1.329 seconds while retaining 16 history records/eight messages; process peak RSS increased by about 3.7 MiB. See [performance verification](performance-2026-09-07.md) for method and limitations. All 202 checked production Swift files meet the 600-line limit, and the diff passes whitespace checks.

Before the final cancellation cleanup fix, a signed iOS demo build installed and launched on the connected iPhone; its verifier passed SQLite, Realm, structured completion, and cancellation checks. A locally signed iOS 18.6 simulator build passed the same checks. The signed simulator build was repeated successfully after the cleanup and definition/tool-output fixes. Enabling local signing restored the simulator application identity required for Keychain and resolved its earlier `keychain_read_failed` result. Both devices and the Mac's documented SDK/demo Keychain entries had no current session, so live-provider compatibility remains unverified pending sign-in. The opt-in harness, simulator signing command, and exact scope are documented in [verification instructions](verification.md). No physical-device energy measurement was performed.

The implementation items described above are addressed in the working tree. The four later findings in tool-output handling and definition loading are also fixed: malformed skill policies fail explicitly, empty allowlists disallow tools, all tool text reaches provider/fallback/context paths including database reactivation, remote image bytes are validated, and definition sources have a configurable 1 MiB limit. See [follow-up findings and resolutions](followup-audit-2026-09-07.md). Runtime turns now default to a five-minute duration, including approval waits; see [execution limits](messaging.md#event-buffering-and-execution-limits) before integrating workflows that intentionally wait longer.

Original audit baseline: commit `87f4d5a700aff88a6da636eba05d48dc2def1e9c`. The SDK contains 153 Swift source files and 35,449 lines. The review covered authentication, turn execution, streaming, tools, observation, structured output, and the memory/persistence architecture, with focused inspection of SQLite, Realm, and file storage. No production code was changed during that initial review.

The latest [deeper audit](deep-audit-2026-09-07.md) reproduces seven additional open edge cases around compaction, cancellation before startup, one-shot schema enforcement, and top-level policy keys. Its findings and evidence are separate from the resolved baseline below.

The existing 374 tests passed on macOS. Nine temporary diagnostic tests were then run: eight failed with 11 assertion failures, confirming the nine issues below; one additional deactivation probe passed. The two UI issues share a diagnostic. All diagnostic failures were expected-behavior assertions, with no unexpected errors in the final run. The diagnostics were removed from the test target after saving the reproduction source and logs.

Evidence: [diagnostic source](/tmp/codexkit-audit-2026-09-07/AuditDiagnosticTests.swift), [diagnostic results](/tmp/codexkit-audit-2026-09-07/diagnostic-tests.log), [existing test results](/tmp/codexkit-audit-2026-09-07/existing-tests.log). These evidence files are local temporary artifacts. To rerun, copy the diagnostic source into `Tests/CodexKitTests` and run `swift test --filter AuditDiagnosticTests`; the assertions intentionally fail until the corresponding bugs are fixed.

**Confirmed findings, in suggested priority order**

1. **P1 — An in-flight refresh can undo sign-out or overwrite a replacement session.**

   [ChatGPTSessionManager.swift:81](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Auth/ChatGPTSessionManager.swift:81) awaits the refresh request and then saves its result without checking whether the session changed during that wait. Actor isolation does not prevent another method from running during the await. The reproduction paused the HTTP refresh, signed out, and then released the response: both the manager and Keychain contained the refreshed session again.

   Introduce a session generation that changes on sign-out, sign-in, and externally supplied sessions. Commit a refresh only if its starting generation remains current. Keep one shared in-flight refresh per generation so concurrent turns do not refresh the same token independently. Apply the stale-result guard to interactive sign-in as well. The sign-out race is reproduced; concurrent duplicate refreshes and replacement-session overwrite follow from the same unguarded code path but were not separately exercised.

2. **P1 — The built-in backend bypasses the runtime's unauthorized recovery.**

   [AgentRuntime+Messaging.swift:363](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+Messaging.swift:363) wraps `beginBackendTurn` in unauthorized recovery, but [CodexResponsesBackend.swift:225](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesBackend.swift:225) returns a stream before opening the network request. HTTP errors arrive later from the producer at [line 343](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesBackend.swift:343). The stream consumer marks the turn failed instead of recovering the session.

   A real Responses-backend reproduction returned HTTP 401 after placing a valid replacement token in Keychain. The call failed with `unauthorized` and never made the queued successful request. Existing recovery fixtures throw directly from `beginTurn`, so they miss this boundary. The context-limit recovery at [AgentRuntime+Messaging.swift:383](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+Messaging.swift:383) has the same boundary problem by inspection.

   Recover initial request failures where they actually occur, with a retry boundary that tracks whether output or tool effects have already happened. Add integration tests through `CodexResponsesBackend` for both HTTP 401 and context-limit failures; do not replay an entire turn after tool side effects.

3. **P2 — Switching conversations during a reply can display the previous conversation's messages.**

   [AgentRuntimeStore.swift:163](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKitUI/AgentRuntimeStore.swift:163) consumes a stream using its captured thread ID while writing shared `messages`, `streamingText`, and progress properties. It does not compare the stream's thread to the currently selected thread. Completion at [line 211](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKitUI/AgentRuntimeStore.swift:211) explicitly loads the old thread's messages into the current view.

   Reproduced by starting a reply in thread A, selecting empty thread B, and completing A: B's displayed messages became A's transcript. Track display state per thread, or guard thread-specific UI updates with the current selection and a selection generation, including after awaited reads. Continue updating shared thread metadata and account limits as appropriate.

4. **P2 — New SQLite threads do not retain the configured message bound.**

   [AgentRuntime+Threads.swift:481](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+Threads.swift:481) trims the message working set, but every persistence call invokes `state.normalized()` at [AgentRuntime+Persistence.swift:25](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+Persistence.swift:25). [StoredRuntimeState+Queries.swift:27](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/StoredRuntimeState+Queries.swift:27) then reconstructs messages from full history. Only threads marked partially loaded keep their bounded message arrays, and fresh threads are not marked that way.

   Reproduced with SQLite, `maximumMessageCount: 2`, and three exchanges: `messages(for:)` returned six messages. Live history also keeps accumulating in [AgentRuntime+History.swift:194](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+History.swift:194), so repeated global sorting and projection work grows with the session.

   Represent new and resumed persistent threads consistently as bounded working sets. Preserve durable history in the store and update active projections incrementally. When evicting live history, preserve sequence allocation and tool-result deduplication through durable lookups; simply truncating that array would introduce correctness risks.

5. **P2 — Structured streaming accepts values that violate the declared schema.**

   [AgentRuntime+StructuredTurnConsumption.swift:158](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+StructuredTurnConsumption.swift:158) treats successful `Decodable` decoding as validation. However, a Swift `String` accepts values outside a JSON Schema enum, and normal decoding ignores extra object properties. Streaming uses a prompted hidden JSON block rather than the one-shot `json_schema` response format; see [AgentStructuredOutput.swift:137](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentStructuredOutput.swift:137).

   A built-in-backend reproduction declared `priority` as a string enum containing `low` and `high`. A response with `priority: "INVALID"` was emitted as `structuredOutputCommitted`.

   Validate committed JSON against the declared supported schema before emitting or persisting a commit, then decode the Swift value. Define partial validation separately so incomplete snapshots can remain useful. Make unsupported raw-schema validation explicit. Merely renaming decoding errors does not enforce the contract.

6. **P2 — Existing per-thread subscriptions silently stop after deactivation.**

   [AgentRuntimeObservation.swift:149](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntimeObservation.swift:149) removes the subjects from its registries. Existing subscribers still hold the old subject, while subsequent changes create a new subject. The old stream receives an empty value but neither future updates nor completion.

   Reproduced by subscribing, publishing a message, deactivating, and publishing again for the same thread. The subscriber never received the second message. Preserve subject identity while subscribed and clear its payload, or explicitly terminate subscriptions and document resubscription semantics. Add deactivate/resume coverage for each per-thread publisher.

7. **P2 — Retrying a disconnected stream duplicates already-emitted text.**

   [CodexResponsesTurnRunner+Events.swift:402](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesTurnRunner+Events.swift:402) blocks replay after committed messages and tool calls, but permits retries after text deltas. There is no event instructing consumers to replace the abandoned attempt's text.

   Reproduced with a first response that emitted `Hello` and closed without `response.completed`, followed by a successful response emitting `Hello`: consumers accumulated `HelloHello`. This affects the README's append/print-style consumer even though the final committed message is correct.

   Either expose an attempt/message reset that consumers can process or stop automatic replay after visible output. Reset structured-parser state on a new attempt as well. Keep the rule that tool effects cannot be replayed.

8. **P2 — A custom backend can finish early and still produce a successful `send`.**

   [AgentRuntime+TurnConsumption.swift:258](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+TurnConsumption.swift:258) finishes successfully when backend events end without `turnCompleted`. The structured consumer repeats this at [AgentRuntime+StructuredTurnConsumption.swift:377](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+StructuredTurnConsumption.swift:377). The ordinary collector returns the most recent assistant message.

   A custom backend emitted `turnStarted`, an assistant message, and EOF. `send` returned that message successfully while the persisted thread stayed `streaming`. The built-in transport already checks for `response.completed`; the public runtime contract needs its own completion invariant.

   Require exactly one valid terminal turn event. Treat EOF before completion as a typed failure and persist the failed state consistently. Share that invariant across plain and structured consumers.

9. **P2 — The UI store inserts the user's message twice during streaming.**

   [AgentRuntimeStore.swift:131](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKitUI/AgentRuntimeStore.swift:131) fetches runtime messages after `runtime.stream` has already appended the user message. The stream's initial `messageCommitted` event is then appended again at [line 203](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKitUI/AgentRuntimeStore.swift:203).

   Reproduced by holding the backend open: the UI contained two user messages for one send. Completion eventually reloads the transcript, hiding the issue. Upsert messages by ID, or use a single consistent mechanism for the initial snapshot and subsequent events.

**Additional performance improvements**

These were source-based opportunities at audit time; follow-up implementation and parser measurements are recorded above. Follow-up local pipeline throughput and process peak-memory results are recorded above; energy has not been measured.

- **Make logging payloads lazy.** [CodexResponsesTransport.swift:350](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesTransport.swift:350) decodes, recursively redacts, and pretty-prints every event even when logging is disabled. Check whether the relevant log level/category is enabled before calling the sanitizer. This is a small, localized improvement, especially for large image events. An autoclosure-based metadata API could prevent the same mistake elsewhere.
- **Avoid reparsing the entire structured buffer on every chunk.** [CodexResponsesBackend+StructuredOutput.swift:48](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesBackend+StructuredOutput.swift:48) copies and JSON-decodes the growing buffer whenever another chunk arrives. Small chunks of one large JSON value cause repeated prefix work approaching quadratic cost. Track lexical completeness incrementally, throttle snapshot attempts, and apply a total structured-payload size limit. Benchmark realistic long objects and strings, including malformed/incomplete output.
- **Keep normalization off ordinary incremental writes.** The bounded-message bug above is also a performance warning: normalization sorts every active thread's retained history and rebuilds projections on each flush. Use normalization for restore/migration or explicit repair, and update only affected thread state during ordinary execution.
- **Give event buffering an explicit policy.** The transport, backend, and runtime all create default-buffered `AsyncThrowingStream` values. A slow consumer can accumulate events without backpressure. Consider a bounded asynchronous channel or coalesced text/progress updates; terminal events, tool calls, and approvals must remain lossless. Do not apply a dropping buffer indiscriminately.
- **Keep SQLite/Realm as the scalable persistence path.** File-store `apply` loads and rewrites the complete snapshot at [FileRuntimeStateStore.swift:65](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/FileRuntimeStateStore.swift:65). That is reasonable for a simple adapter, but the architecture guide still recommends it for production iOS while the persistence guide recommends SQLite. Align the guidance with the expected data volume.

**SDK design changes I would make**

- **Consolidate turn execution before adding more overloads.** The plain and structured startup paths in [AgentRuntime+Messaging.swift](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/AgentRuntime+Messaging.swift) repeat request preparation, reservations, background activity, session resolution, compaction, cancellation, and failure handling. Their consumers repeat lifecycle and persistence rules. Extract one prepared turn context and one lifecycle driver, with structured decoding as an additional event handler. The duplicated recovery and EOF bugs show the maintenance cost of the current split.
- **Introduce a narrow session-provider boundary.** Configuration currently requires concrete ChatGPT auth and Keychain types even with a custom backend. A small injectable session-provider interface would support host-managed authentication and deterministic race tests, while retaining today's ChatGPT/Keychain setup as the default. Avoid adding protocols to every value type.
- **Return an explicit execution handle for advanced callers.** A handle containing events, turn identity/readiness, and cancellation would make ownership clearer and remove the need to discover an ID after `turnStarted`. Keep `send` as the convenience API and preserve the existing streaming entry points during migration. Expose AsyncSequence observation alongside Combine so concurrency-based clients do not need to bridge it themselves.
- **Use typed retry/error information.** The runtime currently detects HTTP status from string error codes and context pressure from message substrings. Preserve HTTP status, provider error code, retry delay, and retry safety as structured data. Keep human-readable messages for presentation and retain compatibility with existing public codes.
- **Add explicit execution budgets and freeze tool registrations per turn.** Concurrency is bounded, but [CodexResponsesTurnRunner.swift:245](/Users/tima/Projects/AssistantAI/CodexKit/Sources/CodexKit/Runtime/CodexResponsesTurnRunner.swift:245) can keep making model/tool passes until the model stops. Offer configurable pass/tool/time budgets. Capture each tool's definition and executor together for an invocation or turn so `replaceTool` during an approval wait cannot change the executor after the approval was based on an earlier definition. This replacement race was identified by inspection, not reproduced.

**What I would retain and how I would sequence the work**

Keep the separate core, UI, SQLite, and Realm products; the opt-in tool parallelism; the database query pushdown; and the attachment staging/recovery design. All checked SDK and demo production sources satisfy the 600-line rule. The persistence and migration tests provide a useful foundation; a broad persistence rewrite is not justified by this audit.

First fix session generation and the streamed error-recovery boundary. Then address UI isolation, bounded active state, schema enforcement, and the remaining stream/subscription correctness issues with permanent regression tests. Take the localized logging improvement next. Consolidate turn execution in a separate refactor backed by the expanded tests, followed by targeted performance measurements.

The original audit used stubbed HTTP responses and local storage. It did not exercise live ChatGPT endpoints, run the iOS demo on a device, verify upstream provider compatibility, or measure release-build performance. Follow-up parser/pipeline measurements and simulator/physical-device checks are recorded above; live-provider validation remains incomplete. The context-limit boundary, duplicate refresh risk, tool replacement race, and performance opportunities are identified explicitly as inspection findings; the nine numbered issues were reproduced.
