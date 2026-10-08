# Local API and Swift demo test

This development API hosts the real `CodexKitBridgeClient` on `127.0.0.1`. It accepts exact prepared request bytes, SHA-256, routing metadata, and separate authentication. The synchronous `/v1` routes use versioned packets; the remote demo uses `/codex` job envelopes with a top-level `completionPush`. It never reconstructs the provider request or selects a model.

## Start the API

From the repository root:

```sh
cd packages/codexkit
npm ci
npm run dev:api
```

The default address is `http://127.0.0.1:8787`. Use `npm run dev:api -- --port 8788` to select another port. The default **fixture** mode substitutes a synthetic provider response while retaining the real bridge's request validation, SSE parsing, and result validation. It makes no provider calls. The fixed text result is `Local cloud bridge OK`; JSON-schema requests receive `{"message":"Local cloud bridge OK"}` and must accept that schema.

To explicitly enable real provider requests:

```sh
npm run dev:api -- --live
```

Live mode uses the library's fixed Codex endpoint and the authentication supplied with each call. The API never loads credentials from disk, refreshes them, logs them, or writes request bodies, credentials or results to disk. Demo jobs retain input in memory until execution finishes and results while the local process remains running, within bounded demo capacity. Both modes call the bridge once per accepted job. Tool calling remains unsupported.

## Use either Swift demo

Build a Debug version of the macOS demo or iOS simulator app. Open **Structured → Local Cloud**, keep **Fixture** selected, and press **Run Local Cloud Test**. The macOS connection screen also exposes the fixture test without signing in. The expected result is `Local cloud bridge OK`.

For a live test, first sign in through the app, start the API with `--live`, and choose **Live ChatGPT session** in the card. The app checks the API's mode before sending the packet. One click sends one provider request using the selected model and an isolated, tool-free structured request. The app's existing authentication state is left intact.

The shared Debug-only `LocalCloudDemoTransport` captures the actual URLRequest prepared by CodexKit's existing structured-recovery path, computes its digest in Swift, and packages it without modifying its body. It adapts the bridge's validated completed result back to the SDK's decoder, then reopens the saved local recovery receipt to verify the same typed result. Temporary test storage is removed afterward. This adapter is test-app code, not a public Swift request-export API.

The original **Run Local Cloud Test** exercises an **ephemeral structured request** over the synchronous `/v1/execute` route. Disconnecting from that route cancels its in-flight operation. Production runtime request export, automatic conversation/history routing, and saving cloud replies into conversations remain separate Swift integration work.

The **Remote Execution** panel below it uses the public `CodexRemoteExecutionClient` to submit jobs, poll metadata and display returned text, decoded JSON, or a PNG. Choose Text/JSON/Image/Image edit and Default (silent)/Silent/Regular. The demo owns preparation of those tool-free packets and downloads the completed result; the public Swift SDK owns submission encoding, preference defaults, integrity checks and HTTP retries. **Run Mixed Batch** holds three accepted jobs until all are queued, then releases them and shows one regular completion event after the device queue drains.

In fixture mode, **Simulate a lost submission reply** injects HTTP 503 after acceptance; the SDK's second submission reuses the same job and invokes the provider once. **Verify All Remote Features** runs 16 jobs: all four request kinds with all three preferences and retries, a mixed batch, and a legacy-metadata case. It also checks restored execution values, HTTP 409 on a changed preference, exact provider digests, and byte-identical retry envelopes using server-side evidence. Fixture mode needs no account. Live mode sends real provider requests; fault injection and the complete verification suite are fixture-only.

Completion events are explicitly simulated. The local API demonstrates middleware batching but does not register devices or deliver SNS/APNs notifications. Jobs survive an HTTP disconnect while the process runs; all local jobs/results disappear on API restart.

The loopback address works from macOS and the iOS simulator. Physical-device access is outside this local-only sample; `127.0.0.1` on an iPhone refers to the phone.

## HTTP contract

`GET /health` returns:

```json
{"version":1,"status":"ok","mode":"fixture"}
```

`POST /v1/execute` requires `Content-Type: application/json` and this envelope:

```json
{
  "version": 1,
  "preparedRequest": {
    "bodyBase64": "<base64 of exact CodexKit-prepared UTF-8 bytes>",
    "sha256": "<lowercase SHA-256 of those bytes>",
    "sessionId": "<CodexKit session_id>",
    "clientRequestId": "<CodexKit x-client-request-id>",
    "originator": "codex_cli_rs"
  },
  "authentication": {
    "accessToken": "<current access token; use synthetic values in fixture mode>",
    "accountId": "<matching account ID>"
  }
}
```

Success is HTTP 200 with `{ "version": 1, "mode": "fixture", "result": <ExecutionResult> }` (or mode `live`). Failure is `{ "version": 1, "error": { "code": "...", "outcome": "..." } }`; bridge failures also include its sanitized message and diagnostics. Invalid packets and bridge preflight failures return 400, oversized envelopes 413, incorrect content type 415, excess concurrent work 429, provider failures 502, and execution timeout 504. A provider authentication failure remains 502 with `authentication_failed` so the app can distinguish it from API access control.

`POST /v1/images/execute` accepts the same envelope with `action: "generate"` or `"edit"` and `imageTurnId` in `preparedRequest`, replacing `sessionId`. Its exact body bytes follow the [image request contract](images.md). Success returns an `ImageExecutionResult` in the same `result` field. Fixture mode returns a synthetic 2×1 PNG for either action; live mode calls the dedicated Images endpoint once. The Remote Execution panel exercises generation and editing through the job routes below.

## Local middleware job routes

All job/demo routes require an `x-demo-device` identifier, used only to isolate local demo queues. It is not production device authentication.

| Route | Behavior |
| --- | --- |
| `POST /codex`, `POST /codex/images` | Accept `preparedRequest`, `authentication`, optional `completionPush`; return HTTP 202 with `{ "data": <CodexRemoteJob> }`. Omission means silent. Repeated IDs reuse the job; changed content/routing/account/preference returns 409. |
| `GET /codex/{id}` | Return queued/running/succeeded/failed metadata and the selected preference. |
| `GET /codex/{id}/result` | Return a local output link after successful completion. |
| `GET /codex/{id}/output` | Return the bridge result in `{ "data": ... }`. This loopback route is a demo contract. |
| `GET /demo/queue` | Return metadata, provider-call counts, submission digests and simulated completion events; exclude prompts and credentials. |
| `POST /demo/release` | Release this device's held jobs for deterministic batch checks. |

The demo uses `x-demo-hold: 1` to queue a batch, `x-demo-retry-once: 1` to lose the first acceptance reply (fixture mode only), and `x-demo-legacy-job: 1` to omit the preference in response metadata. These headers are local test controls. The middleware releases credentials after execution and expires abandoned held requests after its execution timeout. Capacity and retention are bounded; production durability and delivery remain the deployed middleware's responsibility.

The host limits text envelopes to 6 MiB and image envelopes to 64 MiB (including the outer base64 encoding), concurrent executions to four, and provider execution to 90 seconds. Library limits also apply. Configure `maximumImageBytes` or `executionTimeoutMs` in `createLocalAPIServer` for a local test that needs different host limits. It rejects browser Origin headers and non-local Host headers and provides no CORS access. It is an HTTP development sample bound to loopback, not a deployed authentication or credential-custody service.

## Verification

`npm run verify` includes real loopback HTTP tests for successful execution, byte/authentication fidelity, malformed packets, tools, digest mismatch, provider authentication failure, cancellation, timeout, and concurrency limits, using injected providers only. Job tests cover default/silent/regular preferences for responses and images, lost replies, duplicate/conflicting IDs, schema validation, provider failures, legacy metadata and completion batching.

From the repository root, run either signed app against a temporary fixture API:

```sh
python3 Scripts/verify_local_cloud.py
# Use a disposable iOS simulator instead:
python3 Scripts/verify_local_cloud.py --platform ios
# Reuse already-built app and library:
python3 Scripts/verify_local_cloud.py --skip-build
```

The harness starts the API on a free loopback port, runs the original recovery test and the same 16-job feature matrix used by the demo panel, saves reports under `.build/local-cloud/<platform>`, and stops its API process. It rejects outdated binaries that only report the original test. The iOS check also removes its temporary simulator. Both CI demo lanes run this check after building the signed apps. The harness requires Node 22 or 24; ordinary Swift builds and Swift consumers remain independent of Node.
