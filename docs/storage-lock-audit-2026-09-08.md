# Storage-lock cancellation audit — 8 September 2026

**Status: fixed in the working tree.** The original diagnostic and the new permanent cancellation/queue tests pass. The sections below preserve the original finding and reproduction.

The fix uses nonblocking lock attempts with cancellable suspension and descriptor cleanup. Storage queues preserve predecessor completion barriers when a waiter cancels, and a shared task primitive separates cancellable waiting from atomic commit completion. Shared SQLite/Realm preparation owns its cleanup. Runtime startup can stop waiting before a disk lease is available while accepted input/interruption writes drain in order; persistence flushes track their generations across background batch handoffs. No public API or schema migration is required. See [the cancellation contract](persistence.md#cancellation-and-commits).

## P2 — A cancelled storage-lock waiter continues waiting and acquires the lock afterward

`RuntimeStoreInterprocessLock.acquire` awaits a detached task that calls blocking `flock(LOCK_EX)`. Cancelling the caller neither cancels that detached task nor interrupts the lock wait. The lock acquisition also does not check cancellation before returning the acquired lease.

A temporary diagnostic held one SDK lock, started a second acquisition for the same temporary store, cancelled the waiter, and checked its result while the original lock was still held. The waiter had not completed after 200 ms. Releasing the original lease let the cancelled waiter acquire the lock normally. Both cancellation assertions failed as expected, with no unexpected errors. The probe released both locks and removed its temporary store.

The observed output was:

```text
LOCK_PROBE before_unlock=still_waiting after_unlock=acquired
```

The [lock implementation](../Sources/CodexKit/Runtime/RuntimeStoreInterprocessLock.swift) is used by [runtime-store mutation coordination](../Sources/CodexKit/Runtime/RuntimeStoreMutationCoordinator.swift). That coordinator also awaits unstructured operation tasks without forwarding caller cancellation. Runtime persistence has another queue, so a complete fix must review cancellation propagation through those layers rather than only replacing `flock`.

Impact: cancellation cannot promptly abandon a contended lock wait; it depends on the owner eventually releasing the lock. Blocking acquisition also occupies a worker thread. The probe confirms waiting and late acquisition, not data loss or a reproduced executor deadlock.

Implemented change: lock waiting suspends without blocking an executor worker, cancellation before acquisition closes abandoned descriptors, and writes already underway finish atomically. Cross-process exclusion and migration lock ordering are retained.

Acceptance coverage should include cancellation before/during acquisition, contending processes, descriptor cleanup, queued-write ordering, shared preparation, and cancellation after a transaction has begun.

## Evidence and verification scope

The historical diagnostic source and failing log are saved under `.build/audit/storage-lock-cancellation`. Its assertions now pass. Permanent coverage lives in `StorageLockCancellationTests` and `StorageQueueCancellationTests`; run `swift test --filter 'StorageLockCancellationTests|StorageQueueCancellationTests|RuntimeStoreInterprocessLockTests|PreparationCancellationTests'`.

The original ordinary suite contained 511 tests and did not cover this contention/cancellation case. Ten new permanent tests cover cancellation before/during acquisition, an external lock owner, descriptor cleanup with many waiters, release of partially acquired exclusive leases, queue ordering, shared preparation, direct store mutations, and runtime startup across file/SQLite/Realm stores. Existing tests cover migration exclusion, committed-input preservation, and concurrent persistence snapshots. See [release readiness](release-readiness-2026-09-08.md) for the final verification results.

The subsequent `RuntimeConcurrencyStressTests` workload passed 40 waves per adapter, combining six overlapping operations, cancellation, compaction, slow consumers, shared image bytes, and database/runtime reopening across file/SQLite/Realm stores. CI and release verification now include that workload and the optimized storage regressions. See [verification instructions](verification.md) for its independent transcript checks and configurable run length.

Other remaining verification work is live-provider acceptance with a saved session, hosted CI on the release revision, and runtime checks on the minimum supported operating systems. The new workload exercises cooperative cancellation and orderly reopening; abrupt process termination during a commit remains outside its scope. These are coverage gaps, not additional confirmed bugs.
