# Runtime performance review — 23 October 2026

This review covers Swift response decoding, streamed output buffering and presentation, image reference expansion, SQLite/Realm history activation and paging, logging, and the HTTP-to-SQLite pipeline. The TypeScript SSE framer and response collector were also inspected; no TypeScript change was justified by that inspection.

## Changes

- Append unclassified output bytes through the dictionary's modifying accessor, avoiding a copy of the accumulated `Data` prefix on each delta.
- Coalesce `AgentRuntimeStore` answer and reasoning presentation updates at 33 ms. Flush on terminal events and errors; cancel pending publication when selecting another thread or resetting the account. The runtime event stream remains lossless. Reasoning retains its existing 8,000-character suffix.
- Construct typed response items from the already decoded `JSONValue`. Preserve missing/null/wrong-type validation, unknown wire values, raw provider fields, image parsing, and decoding error paths.
- Resolve only required image digests and cache expanded strings within one request. Repeated references share an encoded string; unrelated attachments are not hashed once all references are resolved. No cross-request cache retains image bytes.
- Replace Realm activation's broad relationship `IN` query with bounded indexed equality queries, retaining thread filtering and the existing relationship cardinality check.
- Use Foundation's ISO 8601 format style for log timestamps instead of allocating a date formatter for every console/OSLog entry.

## Reproduction

Use Apple Swift 6.4 on arm64 macOS with release optimization:

```sh
CODEXKIT_RUN_PERFORMANCE_TESTS=1 swift test -c release --force-resolved-versions \
  --filter 'StreamingPerformanceTests|StreamItemPerformanceTests|ImageReferencePerformanceTests|PresentationPerformanceTests|RealmActivationPerformanceTests|LoggingPerformanceTests|RealisticPerformanceTests|RuntimeSystemBenchmarkTests'
```

Run ordinary regression tests with `swift test --force-resolved-versions`. Performance tests are opt-in; timings are reported, never asserted. Equality, limits, malformed input, ordering, cancellation, and output correctness are asserted independently of timing.

## Same-process comparisons

The old implementations are retained in benchmark code only. Buffer, decode, image, relationship-query, and timestamp figures are medians of five samples; presentation figures below are single runs with explicit simulated frame boundaries. These isolate local work and are not provider/network speedup claims.

| Workload | Before | After |
| --- | ---: | ---: |
| Buffer: 2,000 × 256-byte chunks | 45.92 ms | 0.152 ms |
| Buffer: 8,000 × 256-byte chunks | 822.64 ms | 0.695 ms |
| Buffer: 16,000 × 256-byte chunks | 987.96 ms | 1.389 ms |
| Decode: 2,000 small text items | 62.39 ms | 47.68 ms |
| Decode: 50 large text items, 220 KB each | 11.33 ms | 7.91 ms |
| Decode: 20 image items, 1.33 MB each | 10.00 ms | 9.40 ms |
| Restore: 8 MB attachments, no references | 2.650 ms | 0.000250 ms |
| Restore: eight references to one image, 8 MB available attachments | 4.809 ms | 0.602 ms |
| Reasoning: 16,000 Unicode deltas, flush every 32 deltas | 338.23 ms | 11.41 ms |
| Answer publications: 16,000 deltas, flush every 32 deltas | 16,000 | 500 |
| Answer batching CPU overhead, same burst | 0.207 ms | 1.119 ms |
| Offscreen SwiftUI: 128 deltas, publish every eight deltas | 128 renders / 134.80 ms | 16 renders / 11.67 ms |
| Realm relationship lookup: 32 keys, 20,000 records | 34.16 ms | 8.23 ms |
| Log timestamp formatting: 2,000 entries | 147.08 ms | 0.743 ms |

The SwiftUI measurement renders real `Text` through `ImageRenderer` in a fixed 480 × 240 viewport on every publication. It measures avoided rendering work, not interactive frame rate, scrolling, GPU energy, or physical-device behavior. SwiftUI can already coalesce updates in a live app. The demo app uses its own pre-existing text batching; the presentation change here is in the SDK's `AgentRuntimeStore`.

Image-item decoding improved only slightly; the larger image benefit comes from eliminating unnecessary hashing and repeated base64 expansion. The buffer benchmark isolates the append kernel; it does not claim an equivalent speedup for a complete model turn.

## Broader workloads

These are separate baseline and updated runs, so caches and machine load affect the comparison. Even unchanged SQLite writes improved between runs. Treat these as scaling/smoke evidence rather than assigning the entire difference to the patch.

| Workload | Baseline | Updated |
| --- | ---: | ---: |
| Realm activation, 2,000 records | 5.38 ms | 1.91 ms |
| Realm activation, 20,000 records | 41.86 ms | 9.43 ms |
| SQLite activation, 20,000 records | 12.15 ms | 9.37 ms |
| Five 100-record pages, Realm / 20,000 records | 13.91 ms | 8.92 ms |
| Five 100-record pages, SQLite / 20,000 records | 6.04 ms | 3.99 ms |
| Eight-image request construction, 7.42 MB image data | 40.35 ms | 29.85 ms |
| Eight-image compaction | 42.53 ms | 33.72 ms |
| 100 HTTP-to-SQLite turns / 5,000 deltas | 1.809 s | 1.006 s |

Live history stayed bounded at 16 records and eight messages throughout the pipeline test. Backend cancellation stayed below 0.2 ms in both runs. Slow-consumer completion took about 400 ms with a 100 ms consumer delay because terminal events still have to be consumed; that is not evidence of a slow backend stop. Process-wide peak RSS from differently ordered test runs is not comparable, so no memory reduction is claimed.

## Areas left unchanged

- SQLite's existing bounded query and composite-index paths, memory-store query budgets, and history paging already have targeted scaling checks.
- Event channels already use a bounded ring buffer. Replacing small waiter arrays or changing backpressure/cancellation semantics was not supported by these measurements.
- Authentication checks remain on every event; removing them would weaken session invalidation guarantees without evidence of a useful gain.
- The file store's snapshot-oriented design remains unchanged. Database adapters provide the bounded large-history paths measured here.
- No alternate wire codec, global image cache, network retry relaxation, or public API change was introduced.

This is a bounded audit of the exercised workloads, not proof that every application or device is free of performance bottlenecks. Live provider latency and on-device interactive scrolling remain outside these local benchmarks.

## Validation

- Full Swift suite: 813 tests executed, 13 expected opt-in skips, zero failures (793 SDK tests plus 20 recovery integration tests).
- After the final account-publication guard and additional Realm benchmark: 18 optimized release regression/benchmark tests passed with zero failures. This includes UI store behavior, reasoning completion, timer cancellation, decoder compatibility, image reference ownership, timestamp compatibility, and the same-process Realm comparison.
- Repository verification: 46 Python tests passed.
- Source-size and whitespace checks passed; all production source files remain within 600 lines.

The benchmarks use local fixtures; no live provider calls were made.
