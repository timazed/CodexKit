# Local API and Swift demo test

This development API hosts the real `CodexKitBridgeClient` on `127.0.0.1`. It accepts a versioned packet containing the exact Swift-prepared request bytes, their Swift-calculated SHA-256, routing metadata, and separate authentication. It never reconstructs the provider request or selects a model.

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

Live mode uses the library's fixed Codex endpoint and the authentication supplied with each call. The API never loads credentials from disk, refreshes them, or logs or persists request bodies, credentials, or results. Both modes call the bridge once per accepted request. Tool calling remains unsupported.

## Use either Swift demo

Build a Debug version of the macOS demo or iOS simulator app. Open **Structured → Local Cloud**, keep **Fixture** selected, and press **Run Local Cloud Test**. The macOS connection screen also exposes the fixture test without signing in. The expected result is `Local cloud bridge OK`.

For a live test, first sign in through the app, start the API with `--live`, and choose **Live ChatGPT session** in the card. The app checks the API's mode before sending the packet. One click sends one provider request using the selected model and an isolated, tool-free structured request. The app's existing authentication state is left intact.

The shared Debug-only `LocalCloudDemoTransport` captures the actual URLRequest prepared by CodexKit's existing structured-recovery path, computes its digest in Swift, and packages it without modifying its body. It adapts the bridge's validated completed result back to the SDK's decoder, then reopens the saved local recovery receipt to verify the same typed result. Temporary test storage is removed afterward. This adapter is test-app code, not a public Swift request-export API.

This sample exercises an **ephemeral structured request**. Production request export, ordinary conversation/history routing, and saving cloud replies into those conversations remain separate Swift integration work. The local API does not provide durable jobs, request-ID retrieval after a dropped connection, or background execution. A disconnect cancels the in-flight bridge operation; a provider outcome may still be unknown, so the app does not retry automatically.

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

`POST /v1/images/execute` accepts the same envelope with `action: "generate"` or `"edit"` and `imageTurnId` in `preparedRequest`, replacing `sessionId`. Its exact body bytes follow the [image request contract](images.md). Success returns an `ImageExecutionResult` in the same `result` field. Fixture mode returns a synthetic 2×1 PNG for either action; live mode calls the dedicated Images endpoint once. The current Swift Local Cloud card still tests structured text; image routing from the app is separate integration work.

The host limits text envelopes to 6 MiB and image envelopes to 64 MiB (including the outer base64 encoding), concurrent executions to four, and provider execution to 90 seconds. Library limits also apply. Configure `maximumImageBytes` or `executionTimeoutMs` in `createLocalAPIServer` for a local test that needs different host limits. It rejects browser Origin headers and non-local Host headers and provides no CORS access. It is an HTTP development sample bound to loopback, not a deployed authentication or credential-custody service.

## Verification

`npm run verify` includes real loopback HTTP tests for successful execution, byte/authentication fidelity, malformed packets, tools, digest mismatch, provider authentication failure, cancellation, timeout, and concurrency limits, using injected providers only.

From the repository root, run either signed app against a temporary fixture API:

```sh
python3 Scripts/verify_local_cloud.py
# Use a disposable iOS simulator instead:
python3 Scripts/verify_local_cloud.py --platform ios
# Reuse already-built app and library:
python3 Scripts/verify_local_cloud.py --skip-build
```

The harness starts the API on a free loopback port, runs the same Swift path as the demo card, saves reports under `.build/local-cloud/<platform>`, and stops its API process. The iOS check also removes the simulator it created. This explicit integration check requires Node 22 or 24; ordinary Swift builds and Swift consumers remain independent of Node.
