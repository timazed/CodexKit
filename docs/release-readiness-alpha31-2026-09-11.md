# Alpha.31 host-app recovery verification

This prerelease adds injectable model preparation, delegating recovery adapters, lifecycle suspension, durable attempt budgets, linked explicit manual retry, receipt handoff, cleanup, and structured telemetry through the existing log sink. Host-specific model policies, result applicability, UI, and gameplay persistence remain outside CodexKit.

## Verification evidence

The implementation and CI fixture fix were verified at `dcc4b92ad69539710854a349ecff62317ddd9628`. Release preparation changes only documentation. The release workflow additionally requires complete successful CI for the exact tagged commit; the earlier implementation run is not a substitute for that gate.

| Check | Result |
| --- | --- |
| Full local package suite, warnings as errors | 651 tests, 6 opt-in skips, zero failures |
| Optimized recovery, compatibility, performance, and storage checks | 80 tests, zero failures; 40 stress rounds per file, SQLite, and Realm adapter |
| [Implementation CI](https://github.com/timazed/CodexKit/actions/runs/34555038294) | Current and minimum SDK suites, optimized SDK checks, iOS/macOS demos, iOS 17 verifier build/runtime, and final verification gate all passed |
| Physical iPhone full verifier | SQLite, Realm, local adapters, controlled recovery scenarios, and live plain/structured provider checks passed |
| Physical iPhone cold relaunch | Saved validated completion retrieved by a new app process with zero generation POSTs and zero attempt authorizations |

The physical-device checks ran the same production implementation before the test-only CI fixture fix. Their run identity was `74afb74-1789093094152`. Background expiration was an injected lifecycle callback on physical hardware, not a measurement of actual OS background-time exhaustion.

The opt-in Mac live image, remote-compaction, and database-reopen matrix was **skipped**, because no app-owned authenticated session was available. Passing deterministic tests and CI do not establish that this live matrix passed. Physical-device live checks covered plain and structured requests only. This coverage gap remains explicit for this alpha prerelease; no general production-readiness guarantee is implied.

## Recovery and compatibility boundaries

- Completed-result durability begins only after a complete, validated response has been persisted locally. A provider completion that never reaches local durable storage cannot be retrieved; recovery may instead authorize a replacement within the remaining budget.
- Replacement generation is not stream resumption. Model configuration and request contents are frozen before generation; wrappers delegate SDK recovery safeguards rather than replacing them.
- Owning-task cancellation or background expiration suspends recovery. Explicit permanent cancellation remains terminal. Inactive executions do not publish late results, and hosts must separately guard their commit transaction and lifecycle.
- Each independent job keeps its own recovery identity and budget. Restarting does not reset budgets. Deliberate manual retry creates a linked operation with a new bounded budget.
- The handoff remains: persist the handle, generate or retrieve the saved completion, commit host state idempotently, then acknowledge. CodexKit cannot atomically commit host-owned state or decide whether a result is still applicable.
- Version 2 records retain supported alpha.30 handles, attempt accounting, saved receipts, and permanent cancellation. Incompatible contracts and unknown record versions fail without silently deleting progress or generating replacements.
- Public domain properties now include typed enums. Existing string constructor overloads and serialized values remain supported where documented, but callers that require strings may need `.rawValue`; see the changelog and migration guide.
- The asynchronous session-restoration behavior predates this release. The CI fix changes XCTest lifecycle hooks only, not the session-restoration API.

## Publication

Publish an annotated `v2.0.0-alpha.31` tag from `main` only after its exact commit passes the mandatory CI jobs. The automated release gate validates the tag identity, versioned changelog entry, and same-commit verification evidence before publishing a GitHub prerelease. A green earlier commit or a skipped live test is not reported as new verification evidence.
