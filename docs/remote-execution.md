# Remote execution and completion pushes

[Documentation index](index.md) · [SDK integration](sdk-integration.md)

`CodexRemoteExecutionClient` submits already-prepared text/JSON requests to `POST /codex` and images to `POST /codex/images` on an mp-api-compatible middleware. It returns `CodexRemoteJob` acceptance metadata; `job(id:)` reads `GET /codex/{id}`. The host supplies the middleware base URL, its authentication/device headers, and current provider credentials. Middleware responses use a `{ "data": { ...job metadata... } }` envelope.

## Choose the preference when creating the execution

```swift
import CodexKit

let client = try CodexRemoteExecutionClient(
    baseURL: middlewareBaseURL,
    headers: middlewareHeaders
)

// preparedResponse contains the original provider bytes, SHA-256 and routing IDs.
let remoteExecution = CodexRemoteExecution(
    preparedRequest: .response(preparedResponse),
    completionPush: .regular
)
let job = try await client.execute(
    remoteExecution: remoteExecution,
    authentication: CodexRemoteAuthentication(session: session)
)
print(job.jobID, job.completionPush)
```

Omitting `completionPush` selects `.silent`. Explicit `.silent` has the same behavior:

```swift
let silentResponse = CodexRemoteExecution(preparedRequest: .response(preparedResponse))
let silentImage = CodexRemoteExecution(preparedRequest: .image(preparedImage), completionPush: .silent)
let regularImage = CodexRemoteExecution(preparedRequest: .image(preparedImage), completionPush: .regular)

let imageJob = try await client.execute(
    remoteExecution: regularImage,
    authentication: CodexRemoteAuthentication(session: session)
)
let current = try await client.job(id: imageJob.jobID)
```

The preference belongs to each immutable `CodexRemoteExecution`. There is no mutable client-wide push setting. See the compiling [Swift example](../Examples/RemoteExecution.swift).

## Prepared packets and wire format

`CodexRemotePreparedResponse` accepts `body: Data`, `sha256`, `sessionID`, `clientRequestID`, and `originator`. Use it for both text and JSON provider bodies. `CodexRemotePreparedImage` accepts `body: Data`, `sha256`, `clientRequestID`, `imageTurnID`, `originator`, and `action` (default `.generate`). Image action availability depends on the middleware; the current mp-api contract accepts generation.

These types wrap bytes from your existing preparation/export integration. They do not reconstruct provider JSON, replace request identities, or recalculate a supplied digest. The client verifies the digest before sending. Public runtime request export, automatic conversation routing, completed-result retrieval/import, and app persistence coordination remain separate integration work.

The SDK constructs this middleware envelope:

```json
{
  "preparedRequest": {
    "bodyBase64": "<original provider bytes as base64>",
    "sha256": "<original digest>",
    "sessionId": "<original session ID>",
    "clientRequestId": "<original client request ID>",
    "originator": "<original originator>"
  },
  "authentication": {
    "accessToken": "<current token>",
    "accountId": "<account ID>"
  },
  "completionPush": "regular"
}
```

Image envelopes use `action` and `imageTurnId` in the prepared packet in place of `sessionId`. The top-level `completionPush` is always sent, including `"silent"` when the caller omits the option. It never enters the provider body or changes its SHA-256. Existing direct Swift execution and the TypeScript provider bridge retain their behavior.

## Retries and metadata

The client encodes the entire submission once and reuses it for bounded HTTP retries. It preserves the preference, prepared bytes, digest, credentials and client request ID. `RequestRetryPolicy` controls retry counts and delays; `.disabled` makes one attempt. HTTP 409 always stops retries because the backend rejects a reused `clientRequestId` whose request or completion preference differs. Transient network failures and configured transient HTTP statuses may retry; server `Retry-After` is honored. Cancellation stops local submission/status waiting and does not cancel an already-accepted middleware job.

Retain and reuse the same `remoteExecution` for an explicit submission retry. It is `Codable`, so a host journal can persist the prepared packet and preference together, without provider credentials. Restoring a value whose `completionPush` is absent defaults to `.silent`. The host still owns account/device binding and must supply credentials for the same account and device when resubmitting. Do not rebuild an existing request ID using a changed preference.

Both submission and status replies decode `CodexRemoteJob.completionPush`. Missing or null values in legacy metadata decode as `.silent`; unrecognized values fail decoding. Job metadata also includes `jobID`, `status`, optional device/kind/timestamps/expiry, and optional failure details. The preference describes that job's requested delivery style, not a delivery receipt.

The middleware sends one completion push after all outstanding requests for the device finish. If the batch contains both preferences, `.regular` wins. CodexKit forwards the selection; device registration, batching, SNS delivery, and notification presentation remain middleware/app responsibilities.

## Verification

`CodexRemoteExecutionTests` exercises text, JSON and image envelopes with omitted, explicit silent and explicit regular preferences; byte/digest preservation; submission retries; persisted executions; legacy and explicit job metadata; terminal conflicts; invalid digests; and cancellation. All requests use synthetic offline fixtures.

Both Debug demos include a **Remote Execution** panel under **Structured → Local Cloud**. It displays real HTTP job submission/status, completed text/JSON and PNG results, retry counts, and simulated device completion events. **Verify All Remote Features** runs the full 16-job matrix, including all preferences for text/JSON/image generation/editing, changed-preference conflicts, lost acceptance replies, a mixed batch and legacy metadata. The same path is required by both CI demo lanes. Run `python3 Scripts/verify_local_cloud.py` for macOS or add `--platform ios` for a temporary simulator. See the [demo walkthrough](../DemoApp/README.md#local-cloud-api-test) for interactive controls and the distinction between local simulated events and production SNS/APNs delivery.
