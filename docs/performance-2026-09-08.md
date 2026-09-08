# Workload measurements — 8 September 2026

The image, history, and cancellation workloads passed under release optimization. The initial measurements below identified costs for follow-up; the final section records the resulting changes and a fresh before/after comparison. They were collected on arm64 macOS 26.5.1, Xcode 26.6, Apple Swift 6.3.3. Other development tooling was active, so the values are single-run observations rather than stable latency thresholds or a comparison with the previous release.

Reproduce with:

```sh
CODEXKIT_RUN_PERFORMANCE_TESTS=1 swift test -c release \
  --filter 'RealisticPerformanceTests|RuntimeSystemBenchmarkTests|RuntimePerformanceTests|SDKDesignTests'
```

All 16 selected tests passed. Correctness assertions verify results, bounded activation, distinct paged records, and cancellation. Timing is reported without machine-dependent pass/fail thresholds.

## Image-heavy context

Each image is a distinct, valid 512×512 PNG containing deterministic high-entropy pixels, approximately 905 KiB. The history includes one user image and one assistant response per pair. Input provider state contains persisted image references. A stub HTTP turn measures request restoration/encoding and completion; compact processing also reads a response containing those images, retains their attachments, and externalizes the provider payload again. Logging is disabled.

| Images | Attachment bytes | Largest encoded request | Request + stub completion | Compaction |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 926,510 | 1,257,365 bytes | 13.374 ms | 77.991 ms |
| 4 | 3,709,765 | 5,032,387 bytes | 27.546 ms | 338.520 ms |
| 8 | 7,421,435 | 10,066,944 bytes | 59.002 ms | 700.161 ms |

At eight images, the process peak resident memory was 132,120,576 bytes (126 MiB). This includes XCTest, libraries, fixtures, requests, and decoded responses. It is a process-wide high-water mark, not the size of a retained SDK context or a per-request allocation measurement. Every compacted provider payload remained below 32 KiB and retained the expected number of attachments.

Image compaction was the largest measured processing cost here. The follow-up below reduces byte accumulation and reference-validation work. JSON decoding and base64 conversion remain possible profiling targets. These tests use local URLProtocol responses and include no provider inference or real-network latency.

## Large database histories

Each database receives alternating user/assistant messages containing about 512 bytes of text. After reopening a new store instance, the workload hydrates at most 16 messages and retrieves five consecutive pages of 100 messages. It verifies that the newest message survives activation and that the 500 paged records contain no duplicates.

| Adapter | History records | Initial write | Activation after reopen | Five pages |
| --- | ---: | ---: | ---: | ---: |
| SQLite | 2,000 | 173.773 ms | 3.463 ms | 11.261 ms |
| SQLite | 20,000 | 1,760.433 ms | 16.253 ms | 11.443 ms |
| Realm | 2,000 | 532.172 ms | 5.951 ms | 14.209 ms |
| Realm | 20,000 | 1,064.139 ms | 32.989 ms | 43.544 ms |

Both adapters hydrated 16 messages at each size. Preparation runs before the activation/page timers. The initial-write timer covers creating the full saved history, not incremental production append throughput. Process memory during these tests includes the complete generated fixture array and database setup, so it does not establish steady-state runtime memory.

SQLite page retrieval stayed similar across the two sizes in this run. Realm page retrieval increased with history size; the follow-up below avoids sorting the full matching history for consecutive pages. A 20,000-record fixture does not establish behavior for arbitrarily large databases.

## Slow-consumer cancellation

Both SDK queues have capacity one. The backend attempts 10,000 deltas, and cancellation is requested after the consumer receives its first delta. The consumer optionally pauses after each event.

| Consumer delay per event | Backend producer stopped | Consumer finished draining |
| ---: | ---: | ---: |
| 0 ms | 0.621 ms | 0.828 ms |
| 25 ms | 0.092 ms | 103.715 ms |
| 100 ms | 0.090 ms | 403.080 ms |

Backend work stopped promptly in all three cases. Consumer completion includes its deliberate pauses and the bounded queued/lifecycle events. The persistent thread returned to idle in every case. These measurements exercise cooperative cancellation with a custom backend; they do not measure network-server cancellation or physical-device energy use.

## Existing pipeline and parser checks

The HTTP-to-SQLite pipeline completed 100 turns and 5,000 deltas in 1.374 seconds, with 1.488 seconds of process CPU time. Retained context remained at eight messages and 16 history records. The parser completed the 8,000-fragment workload in 7.772 ms with one snapshot decode; its repeated-prefix comparison took 327.358 ms. See the [earlier benchmark description](performance-2026-09-07.md) for their construction and limits.

Physical-device energy and live-provider latency remain outside these measurements. The later concurrent lifecycle workload is recorded below.

## Implemented performance follow-up

Compact responses now collect bytes in a reusable 64 KiB buffer before appending to `Data`. Exact response limits, truncated error-body handling, download cancellation, and network-error propagation remain enforced. Retained image references are validated by digest without constructing another expanded base64 JSON tree. Images continue to persist as disk attachments with references in provider metadata.

Realm now tries bounded primary-key reads for consecutive sequence windows used by ordinary history pages, unfiltered sequence queries, and activation. Missing rows or rows excluded by compaction/redaction filters fall back to the existing database query. Date sorting and additional filters retain their query paths. Cursor validation uses the history primary key, and existence checks stop at the first match instead of counting all matches. The schema and public API are unchanged.

A fresh baseline was collected immediately before these changes. The optimized verification run afterward passed all 16 performance/SDK tests:

| Workload | Before this follow-up | After this follow-up | Observed reduction |
| --- | ---: | ---: | ---: |
| Compact one image | 68.899 ms | 41.921 ms | 39% |
| Compact four images | 322.551 ms | 140.864 ms | 56% |
| Compact eight images | 543.972 ms | 280.348 ms | 48% |
| Realm: five pages, 2,000 records | 9.663 ms | 6.033 ms | 38% |
| Realm: five pages, 20,000 records | 44.577 ms | 9.219 ms | 79% |

An earlier post-change run measured 288.148 ms for eight-image compaction and 9.204 ms for five Realm pages at 20,000 records. This supports the direction of the changes, but these runs are not a controlled statistical latency study. The before/after baseline above differs from the earlier audit measurements because it was rerun for this implementation pass.

The final eight-image process high-water mark was 132,218,880 bytes, approximately 126 MiB; no reduction in process peak memory is claimed. Realm activation at 20,000 records measured 30.667 ms versus 33.735 ms before, so the strong paging improvement should not be generalized to cold activation. Backend cancellation stopped in 0.101–0.119 ms across the three consumer delays, and the 100-turn pipeline completed in 1.161 seconds while retaining eight messages and 16 history records.

Eight new regression tests cover buffer boundaries, interrupted downloads, nested/invalid image references, paging parity across filters and directions, restored histories, empty histories, and sequence arithmetic near integer limits. Timing remains diagnostic; correctness assertions determine test success.

## Verification after storage cancellation changes

After the [storage-lock fix](storage-lock-audit-2026-09-08.md), the optimized selection passed all 26 tests: the 16 performance/SDK checks above plus ten new storage cancellation regressions. This run treated warnings as errors. Eight-image compaction measured 283.557 ms, and five Realm pages at 20,000 records measured 8.775 ms, close to the earlier improved results. The 100-turn pipeline completed in 0.859 seconds while retaining eight messages and 16 history records; backend cancellation stopped in 0.093–0.190 ms across the three consumer delays. These are local diagnostic observations, not a controlled throughput comparison or sustained contention benchmark.

## Concurrent lifecycle verification

The expanded optimized selection passed 29 tests with warnings treated as errors. Its three new lifecycle tests each ran 40 waves using two runtimes and six conversations in one shared disk store. Every wave forced three completed turns, one interrupted turn, one completed compaction, and one cancelled compaction to overlap with a fresh database reader. Capacity-one queues and slow consumers exercised backpressure. Each wave compared saved messages, history sequences, images, lifecycle records, and compaction generations with an independent expected transcript. Both owning runtimes were replaced every four waves and reactivated their conversations before continuing.

| Adapter | Lifecycle operations | Reader reopens | Owning-runtime replacements | Workload duration |
| --- | ---: | ---: | ---: | ---: |
| File | 240 | 40 | 20 | 135.055 s |
| SQLite | 240 | 40 | 20 | 10.639 s |
| Realm | 240 | 40 | 20 | 6.025 s |

These durations include full saved-state reads, assertion work, activation, and deliberate consumer delays; they are diagnostic observations of this workload rather than incremental-write throughput measurements. The complete optimized selection took 160.917 seconds after compilation. The tests use a local custom backend and cooperative cancellation; they do not establish live-provider compatibility, abrupt-crash recovery, minimum-OS support, or physical-device energy use. [Verification instructions](verification.md) include the exact command, six-wave ordinary-suite default, and 1–200 wave configuration range.
