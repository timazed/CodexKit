# Runtime performance verification — 7 September 2026

The structured parser now tracks JSON lexical completeness incrementally and decodes a snapshot only when the value is complete. The regression benchmark in `Tests/CodexKitTests/RuntimePerformanceTests.swift` compares that parser with the former repeated-prefix decoding pattern. Both paths assemble and decode the same single JSON object, delivered in 16-byte fragments, and their decoded values must match.

Run the optimized benchmark with:

```sh
swift test -c release --filter RuntimePerformanceTests
```

One local run on arm64 macOS 26.5.1 with Apple Swift 6.3.3 produced:

| Fragments | Payload bytes | Repeated-prefix decoding | Incremental parser | Snapshot decodes |
| ---: | ---: | ---: | ---: | ---: |
| 500 | 8,011 | 2.546 ms | 0.562 ms | 1 |
| 2,000 | 32,011 | 22.561 ms | 1.787 ms | 1 |
| 8,000 | 128,011 | 281.755 ms | 7.460 ms | 1 |

At the largest input, the incremental parser took about 38 times less time in this run. Increasing input size by four times, from 2,000 to 8,000 fragments, increased incremental time by about 4.2 times, versus 12.5 times for repeated decoding. These are kernel measurements from one run, not an end-to-end comparison against a previous package checkout. Timing is reported rather than asserted; machine load and optimization affect the numbers.

Separate correctness and capacity tests cover:

- 10,000 ordered channel events with a two-event buffer, including terminal-event delivery.
- A paused consumer receiving 200 Unicode text deltas through the HTTP parser, backend, and runtime with each queue configured for one event.
- Cancellation and deadline expiry while a queue is full, including release of blocked producers.
- SQLite and Realm live-history eviction with zero- and one-record caches, followed by runtime reload and replay of a previously completed tool call without re-execution.
- Shared response-byte budgets across model passes and retries, accumulated provider-item limits, and steering-queue saturation.

`StructuredValidationTests` also covers long fragmented values, escaping, malformed/oversized payload handling, parser reset, and schema validation work bounds. Those are correctness checks and do not add timing claims for malformed output.

The event limits bound SDK-owned queues, with up to four additional lifecycle events at termination. Active producers can each hold an event while awaiting capacity. URLSession buffering, decoded provider context, host tool allocations, durable database size, and total process memory are outside this measurement. The parser measurement alone does not measure process memory, energy, live-provider latency, or device behavior. The additional pipeline measurement below includes process peak RSS.


## HTTP-to-SQLite pipeline

`RuntimeSystemBenchmarkTests.testHTTPToSQLiteThroughputAndProcessPeakMemory` runs 100 complete turns through stubbed HTTP, SSE parsing, the Responses backend, the public runtime collector, and SQLite persistence. Each turn emits 50 text fragments and commits an 800-byte assistant message. Both event queues are configured for two events; the retained context is bounded to eight messages and 16 history records. The test checks output equality, working-set bounds, and that durable history survives eviction.

```sh
CODEXKIT_RUN_PERFORMANCE_TESTS=1 swift test -c release --filter RuntimeSystemBenchmarkTests
```

One optimized run on the same arm64 macOS machine produced:

| Completed turns | Deltas | Elapsed | Process CPU time | Process peak RSS | Live history / messages |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 500 | 0.141 s | 0.109 s | 113,147,904 bytes | 16 / 8 |
| 50 | 2,500 | 0.676 s | 0.550 s | 113,770,496 bytes | 16 / 8 |
| 100 | 5,000 | 1.329 s | 1.145 s | 114,409,472 bytes | 16 / 8 |

The process started this benchmark at a peak RSS of 110,559,232 bytes. Its peak increased by 3,850,240 bytes (about 3.7 MiB) over the run. At this workload, throughput was approximately 75 turns or 3,762 deltas per second. This is a local synthetic workload without provider inference or network latency; it is not a production throughput forecast. Peak RSS is the process-wide high-water mark reported by `getrusage`, including the XCTest runner and linked libraries. CPU time is user plus system time, not an energy measurement. The 100-turn observation does not prove that every workload or indefinitely long session has constant memory.

The pipeline benchmark is opt-in so normal tests avoid timing-dependent performance work. SDK ownership tests also passed under release optimization. Live-provider checks are separately opt-in through `LiveProviderTests`; see [verification instructions](verification.md).
