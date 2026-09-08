# Persistence and observation

[Documentation index](index.md) · [CodexKit](../README.md)

Choose a storage adapter, migrate existing state, query saved threads, observe changes, and compact effective context.

## Package Products

- `CodexKit`: core runtime, auth, backend, tools, approvals
- `CodexKitUI`: optional SwiftUI-facing helpers
- `CodexKitSQLite`: optional SQLite runtime and memory stores backed by GRDB
- `CodexKitRealm`: optional Realm runtime and memory stores backed by RealmSwift

Only add the persistence product your application uses. Most application files continue importing only `CodexKit`; the adapter import is needed only where the concrete store is constructed. Do not add both adapter products for normal application use—link both only while running a one-time cross-store migration or in tooling that deliberately supports switching adapters.

An application using SQLite selects these products in its own package target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "CodexKit", package: "CodexKit"),
        .product(name: "CodexKitSQLite", package: "CodexKit"),
    ]
)
```

An application using Realm selects Realm instead of SQLite:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "CodexKit", package: "CodexKit"),
        .product(name: "CodexKitRealm", package: "CodexKit"),
    ]
)
```

Then import only the selected adapter alongside the core module in the composition file:

```swift
import CodexKit
import CodexKitSQLite

let memoryStore = try SQLiteMemoryStore()
let stateStore = try SQLiteRuntimeStateStore()
```

Or, for Realm:

```swift
import CodexKit
import CodexKitRealm

let memoryStore = try RealmMemoryStore.builder().build()
let stateStore = try RealmRuntimeStateStore()
```

SwiftPM resolves the repository's declared dependency graph when it resolves the package, so both upstream package pins can appear in `Package.resolved`. Product selection still keeps GRDB out of `CodexKit` and out of applications that link only `CodexKitRealm`, while RealmSwift stays out of applications that link only `CodexKitSQLite`.

This is a SwiftPM resolver limitation of keeping both adapters in one package manifest: choosing one product controls what the application compiles and links, but does not make the other package declaration disappear during dependency resolution. Completely independent resolution would require publishing the adapters as separate Swift packages; it cannot be expressed as conditional target dependencies in this manifest.

If the host application already uses RealmSwift through SwiftPM, keep its direct `RealmSwift` product dependency. SwiftPM identifies both requirements as the same `realm-swift` package and resolves one compatible 20.x version for the application; CodexKit does not vendor or rename a second Realm binary. An incompatible host constraint, such as a pin to an older major version, is reported by SwiftPM during dependency resolution rather than producing two Realm copies at runtime.

CodexKit does not accept host-provided file URLs for its Realm stores. It derives two fixed, separate files under the host application's Application Support directory at `<bundle-id>/CodexKit/Realm/runtime-state.realm` and `<bundle-id>/CodexKit/Realm/memory.realm`. A Realm file has one schema version and one migration lifecycle, so keeping these files separate from the host application's Realm prevents the schemas from being opened against each other. The stores install only CodexKit's object schemas and do not change `Realm.Configuration.defaultConfiguration`.

SQLite stores follow the same managed-location rule. `SQLiteRuntimeStateStore()` and `SQLiteMemoryStore()` use `<bundle-id>/CodexKit/SQLite/runtime-state.sqlite` and `<bundle-id>/CodexKit/SQLite/memory.sqlite`; the public API cannot point either store at an application database. This prevents CodexKit's GRDB migrations and tables from being applied to a host-owned SQLite file. Earlier alpha releases accepted arbitrary SQLite URLs, so databases at those caller-selected locations are not discovered automatically after updating.

Realm persistence is new in this unreleased line, so both Realm stores ship with schema version 1. Development iterations are intentionally folded into that initial schema rather than exposed as fictional public migrations. SQLite migrations, by contrast, advance only from previously released SQLite schema versions.

With lazy persistent stores, `activeThreads()` returns only the bounded set currently hydrated by the runtime. Use `persistedThreads(_:)` for the durable thread catalog shown by navigation or restart UI; resuming one of those threads hydrates it into the active set.

The SwiftPM manifest uses explicit target paths under `Sources/`. The checked-in `DemoApp/` is not part of any package product or target; it is an example app only.

Supported package platforms:

- iOS 17+
- macOS 14+

## Recommended Live Setup

The recommended production path for iOS and macOS is:

- `ChatGPTAuthProvider`
- `KeychainSessionSecureStore`
- `CodexResponsesBackend`
- `SQLiteRuntimeStateStore`
- `ApprovalInbox` and `DeviceCodePromptCoordinator` from `CodexKitUI`

Bundled runtime-state stores now include:

- `SQLiteRuntimeStateStore` from `CodexKitSQLite`
  Uses SQLite through GRDB and supports migrations, query pushdown, redaction, whole-thread deletion, paged history reads, and lazy per-thread activation after restore.
- `RealmRuntimeStateStore` from `CodexKitRealm`
  Uses RealmSwift, supports schema migrations, incremental transactional per-thread writes, query pushdown, redaction, whole-thread deletion, paged history reads, externalized image attachments, and lazy per-thread activation after restore.
- `FileRuntimeStateStore`
  A simple JSON-backed fallback for small apps, tests, or export/import-style workflows.
- `InMemoryRuntimeStateStore`
  Useful for previews and tests.

All store APIs have explicit work bounds. An omitted list or history-page limit means
`AgentStoreLimits.defaultListResultCount` (currently 256), not “load everything.”
Oversized filter sets, write batches, redaction matches, messages, embedded JSON,
tool payloads, and image batches are rejected atomically before a store is changed.
The public constants in `AgentStoreLimits` make those contracts visible to host apps.
`loadState()` and `saveState(_:)` remain intentionally complete-snapshot operations
for migration, import/export, and tests; normal startup and thread resumption use
metadata queries and bounded lazy activation instead.

Persistent image bodies are never encoded into database rows. SQLite and Realm keep
only validated attachment metadata and content-addressed storage keys; the bytes live
in adapter-specific sidecar directories. Promotion, deletion, orphan reconciliation,
and crash recovery process bounded batches so a large thread does not require an
unbounded in-memory attachment set.

### Cancellation and commits

Waiting for a runtime-store lock suspends without occupying an executor worker. Cancelling a direct store mutation before it acquires its leases removes that queued operation; it will not write later when the lock becomes available. Cancelling a queued read also stops its wait, while later operations retain their original ordering.

Once a database/attachment commit has started, it finishes atomically and reports its result. Cancelling one caller waiting for shared SQLite/Realm preparation does not cancel or restart preparation needed by other callers. Custom state stores do not expose a commit boundary, so the runtime conservatively allows an entered `apply` call to finish.

The runtime owns writes it has already accepted into its in-memory state. Cancelling startup while its disk lease is unavailable returns promptly and marks the thread interrupted/idle without starting a backend. Accepted input and its interruption record stay queued in order and flush when storage becomes available, even if the original caller stops waiting. Cancellation after a preparation write has begun allows that write and its interruption cleanup to finish.

The bundled persistent memory stores are:

- `SQLiteMemoryStore` from `CodexKitSQLite`
  Uses SQLite through GRDB with a structured `memory_records` table plus ordered evidence, tag, related-ID, and normalized search-token tables. The database counts distinct matching tokens and applies the configured minimum and structural predicates while scanning the selected composite ranking index into a bounded `limit + 1` candidate window. Aggregate character packing and any temporary ordering operate only on that bounded window, never the complete matching set. Only selected records are assembled as `MemoryRecord` values. Diagnostics read trigger-maintained per-namespace totals and indexed dimension snapshots instead of grouping the memory table at read time.
- `RealmMemoryStore` from `CodexKitRealm`
  Uses RealmSwift with a structured `RealmMemoryRecord`; tags, relationships, and search tokens are indexed linked entities, while the remaining rule fields are native scalar properties rather than an encoded `MemoryRecord` payload. Realm Core applies the configured token-count predicate, structural predicates, and one multi-column native sort, and Swift advances only the bounded `limit + 1` prefix instead of scanning or ranking the candidate set. Each namespace has one transactionally maintained diagnostics snapshot, so diagnostics use a primary-key lookup instead of walking memories or aggregate rows.

`MemoryTextMatchPolicy` controls text eligibility with `.anyToken`, `.atLeastTokens(_:)`, or `.allTokens`. Direct store queries preserve the compatible `.anyToken` default; runtime prompt selection requires two distinct tokens when the prompt contains at least two, uses any-token matching for a one-token prompt, and can be overridden through `AgentMemoryContext` or `MemorySelection`. An explicit minimum is exact: a two-token minimum does not match a one-token query. Ordering is selected independently with `MemoryRankingProfile.importanceThenRecency` (the default) or `.recencyThenImportance`, so text relevance never becomes an undocumented ranking boost. Match explanations report the selected ranking profile, whether execution was in memory or database-native, and the exact matched/query token counts.

Memory inputs and result materialization are bounded by the public constants in
`MemoryStoreLimits`. SQLite and Realm enforce eligibility, token coverage, structural
filters, ordering, renderability, and result limits in their query engines before
constructing `MemoryRecord` values. The in-memory and file-backed implementations are
fallback stores and necessarily evaluate their bounded working sets in Swift.

Persistent stores prepare themselves lazily on the first operation. Applications that want migration or schema errors before serving requests can explicitly call `try await memoryStore.prepare()` during startup. Runtime prompt selection uses a ranking cursor and makes at most one bounded database query per selected record. Every query includes the exact remaining character budget, so SQLite or Realm skips oversized rows and returns the next fitting record without materializing or scanning those rows in Swift. The default eight-item budget therefore performs at most eight small database queries.

If you are migrating from the older file-backed store, both persistent runtime adapters automatically import a sibling `*.json` runtime state file on first open. For example, `runtime-state.sqlite` or `runtime-state.realm` will import from `runtime-state.json` if it exists and the destination store is still empty.

To switch an existing application from SQLite to Realm, temporarily include both adapter products and run the protocol-based migrator once:

```swift
import CodexKit
import CodexKitRealm
import CodexKitSQLite

let report = try await RuntimeStoreMigrator.migrate(
    from: SQLiteRuntimeStateStore(),
    to: RealmRuntimeStateStore()
)
print("Migrated \(report.threadCount) threads")
```

The source store is left untouched. Runtime thread metadata, histories, and memory records are copied and verified with stable keyset pages of 256 by default; pass `batchSize:` to tune that bound. The migrators reject a source and destination that resolve to the same built-in store, require an empty destination, and reject `overwriteDestination: true` when data is present because a destructive overwrite cannot be rolled back safely. Built-in persistent runtime and memory stores hold an exclusive cross-instance and cross-process lease for the migration. If a copy fails, rollback removes only the thread or memory IDs inserted by that migration and surfaces a rollback failure instead of hiding it. Memory records can be copied with `MemoryStoreMigrator.migrate(namespaces:from:to:)`.

## Persistent State And Queries

`CodexKit` now treats runtime persistence as a queryable store instead of a single “load the whole thread” blob. For most apps, the main thing to know is:

- use `SQLiteRuntimeStateStore` for persisted production state
- use `fetchThreadHistory(id:query:)` and `fetchLatestStructuredOutputMetadata(id:)` for common thread inspection
- use the typed `execute(_:)` query surface when you need more control over filtering, sorting, paging, or cross-thread reads
- use hidden context compaction when you want to optimize future turns without removing preserved thread history from UI or inspection APIs
- new and resumed SQLite/Realm threads keep bounded message and history working sets; durable history remains queryable without being loaded wholesale

```swift
let stateStore = try SQLiteRuntimeStateStore()

let runtime = try AgentRuntime(configuration: .init(
    authProvider: authProvider,
    secureStore: secureStore,
    backend: backend,
    approvalPresenter: approvalPresenter,
    stateStore: stateStore,
    threadActivationPolicy: .init(
        maximumMessageCount: 128,
        maximumEstimatedTokens: 16_000,
        maximumHistoryRecordCount: 512
    )
))

// Releases hydrated context only. SQLite history and semantic memory remain durable.
await runtime.deactivateThread(id: thread.id)

let page = try await runtime.fetchThreadHistory(
    id: thread.id,
    query: .init(limit: 40, direction: .backward)
)

let snapshots = try await runtime.execute(
    ThreadSnapshotQuery(limit: 20)
)
```

`maximumHistoryRecordCount` bounds retained history throughout live execution, including fresh threads created without `restore()`. Values are clamped to 0–2,048; zero retains no live history records. Eviction preserves durable records, summaries, and sequence allocation. Deduplication flushes pending writes and consults durable history when a message, tool result, or structured commit is absent from the live cache. A failed lookup fails the turn instead of executing a potentially completed tool again. Snapshot-based file and in-memory adapters remain suitable for smaller workloads.

Use relationship filters to retrieve linked records without loading unrelated history:

```swift
let toolRecords = try await runtime.execute(HistoryItemsQuery(
    threadID: thread.id,
    kinds: [.toolCall, .toolResult],
    relationship: .toolInvocation(id: invocationID)
))
```

`.message(id:)` selects a message and its linked structured output; combine it with `kinds` to narrow the result. Relationship queries use existing database indexes in SQLite and Realm and have matching semantics in the file and in-memory stores.

This path also supports explicit history redaction and whole-thread deletion without forcing hosts to replay raw event streams themselves.

## Live Observation

`CodexKit` exposes Combine publishers so apps can react to runtime state changes without polling or manual callback wiring.

```swift
import Combine

var cancellables = Set<AnyCancellable>()

await runtime.observeThread(id: thread.id)
    .receive(on: DispatchQueue.main)
    .sink { thread in
        print("Observed title:", thread?.title ?? "Untitled")
    }
    .store(in: &cancellables)

await runtime.observeMessages(in: thread.id)
    .receive(on: DispatchQueue.main)
    .sink { messages in
        print("Observed message count:", messages.count)
    }
    .store(in: &cancellables)

await runtime.observeThreadContextState(id: thread.id)
    .receive(on: DispatchQueue.main)
    .sink { contextState in
        print("Observed compaction generation:", contextState?.generation ?? 0)
    }
    .store(in: &cancellables)

await runtime.observeThreadContextUsage(id: thread.id)
    .receive(on: DispatchQueue.main)
    .sink { usage in
        print("Estimated effective tokens:", usage?.effectiveEstimatedTokenCount ?? 0)
    }
    .store(in: &cancellables)

try await runtime.setTitle("Shipping Triage", for: thread.id)
```

Available built-in publishers:

- `observeThreads()`
- `observeThread(id:)`
- `observeMessages(in:)`
- `observeThreadSummary(id:)`
- `observeThreadContextState(id:)`
- `observeThreadContextUsage(id:)`

The checked-in demo app includes a thread detail `Observation Demo` card that exercises these publishers live, along with a rename control that calls `setTitle(_:for:)`.

## Effective Context Compaction

`CodexKit` can compact the runtime's effective prompt context without mutating canonical thread history.

- canonical visible history stays intact for `fetchThreadHistory(...)`; with lazy stores, `messages(for:)` reflects the bounded active working set
- compacted effective context is used only for future turns
- compaction markers are persisted for audit/debug semantics and hidden from normal history reads by default
- manual compaction is always available when the feature is enabled; `.automatic` additionally lets the runtime compact pre-turn or after a context-limit retry path

```swift
let runtime = try AgentRuntime(configuration: .init(
    authProvider: authProvider,
    secureStore: secureStore,
    backend: backend,
    approvalPresenter: approvalPresenter,
    stateStore: stateStore,
    contextCompaction: .init(
        isEnabled: true,
        mode: .automatic
    )
))

let contextState = try await runtime.compactThreadContext(id: thread.id)
print(contextState.generation)

let usage = try await runtime.fetchThreadContextUsage(id: thread.id)
print(usage?.effectiveEstimatedTokenCount ?? 0)
```

For debug tooling or host inspection, you can also read the compacted effective context and the current estimated context-window usage directly:

```swift
let contextState = try await runtime.fetchThreadContextState(id: thread.id)
let usage = try await runtime.fetchThreadContextUsage(id: thread.id)
let contexts = try await runtime.execute(
    ThreadContextStateQuery(threadIDs: [thread.id])
)
```
