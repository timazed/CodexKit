# CodexKit for TypeScript

The independently versioned `@timazed/codexkit` npm package lives in [`packages/codexkit`](https://github.com/timazed/CodexKit/tree/main/packages/codexkit) in the CodexKit repository and is distributed through GitHub Packages. Its current version is `0.2.0`. Swift builds and Swift consumers do not require Node or npm; this package has its own manifest, lockfile, build, and tests.

A small TypeScript library that executes a CodexKit-prepared request against the Codex backend and returns its completed result. CodexKit is the authority for request construction, model/reasoning selection, response format, and retry policy.

The package exports `CodexKitBridgeClient` for the backend team to use from its routes or workers. It has **zero runtime dependencies**, makes **one generation POST per call**, and stores no credentials or job state. HTTP routes, caller authorization, credential custody, persistence, scheduling, and retry coordination belong to the importing backend.

## Install and use

Supported runtimes: Node.js 22 and 24. CommonJS with type declarations; also importable from Node ESM. TypeScript consumers should use TypeScript 5.9 or later and Node type declarations.

Add this scope mapping to the consuming backend's `.npmrc`:

```ini
@timazed:registry=https://npm.pkg.github.com
```

For local installation, [create a GitHub personal access token (classic)](https://github.com/settings/tokens) with `read:packages` and access to this package. Sign in with your GitHub username and use the token at the password prompt:

```sh
npm login --scope=@timazed --auth-type=legacy --registry=https://npm.pkg.github.com
npm install @timazed/codexkit
```

GitHub requires authentication even for public npm packages. In a consuming GitHub Actions workflow, use its `GITHUB_TOKEN` with `packages: read` and grant that repository access to this package; configure `actions/setup-node` with the same registry and scope. See [GitHub registry authentication](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry#authenticating-to-github-packages). Keep token values out of committed files.

```ts
import { CodexKitBridgeClient, CodexKitCloudError } from "@timazed/codexkit";
import type { PreparedRequest, Authentication } from "@timazed/codexkit";

const client = new CodexKitBridgeClient();

async function runCodex(
  preparedRequest: PreparedRequest,
  authentication: Authentication,
) {
  try {
    return await client.execute({ preparedRequest, authentication });
  } catch (error) {
    if (error instanceof CodexKitCloudError) {
      // Your API can serialize this structured failure with error.toJSON().
      // A failure alone does not authorize another generation attempt.
    }
    throw error;
  }
}
```

CommonJS: `const { CodexKitBridgeClient } = require("@timazed/codexkit")`.

For dedicated image generation or editing, use the same client:

```ts
const result = await client.executeImage({ preparedRequest: preparedImageRequest, authentication });
const png = Buffer.from(result.images[0]!.base64, "base64");
```

`preparedImageRequest` is a `PreparedImageRequest` containing CodexKit's exact image request bytes, digest, action and routing headers. Results include validated PNG data and actual pixel dimensions. Editing accepts up to five inline PNG/JPEG/WebP references. See the [image contract and limits](docs/images.md) and [image API route example](examples/image-api-route.ts). General tool calling remains unsupported.

Create a client once with your backend's configuration and reuse it across requests. Supply authentication to each `client.execute(...)` call; concurrent calls keep credentials and execution state isolated. `CodexKitBridgeClientOptions` describes constructor options, and `client.validatePreparedRequest(request)` provides preflight using the same configured limits.

[examples/api-route.ts](examples/api-route.ts) shows a framework-independent response adapter. The backend authenticates the caller and resolves the matching credentials before calling the library. The returned result is JSON-serializable and can be sent directly through the host API.

For a runnable local host, use `npm run dev:api` and open **Structured → Local Cloud** in either Debug demo app. The API defaults to synthetic provider responses on `http://127.0.0.1:8787`; `npm run dev:api -- --live` explicitly enables real requests. See [local API setup and request contract](docs/local-api.md) for authentication, supported scope, and the Swift-to-TypeScript verification harness. The library itself does not start a server.

### Migrating from the original package name

Version `0.1.1` uses `@timazed/codexkit` in place of `@timazed/codexkit-cloud`. In an existing backend:

```sh
npm uninstall @timazed/codexkit-cloud
npm install @timazed/codexkit
```

Change imports and `require(...)` calls to `@timazed/codexkit`. `CodexKitBridgeClient`, `CodexKitCloudError`, and the exported types retain their existing APIs. The old `@timazed/codexkit-cloud@0.1.0` publication remains available for existing consumers; new releases use the new name.

## Prepared request and authority

`PreparedRequest` describes the **library argument**. It does not establish a new cloud-owned wire protocol, operation identity, or persistence format. CodexKit's protocol remains authoritative; the host maps that protocol into this argument:

```ts
interface PreparedRequest {
  body: Uint8Array;      // Exact UTF-8 provider request bytes from CodexKit.
  sha256: string;       // CodexKit's lowercase hexadecimal SHA-256 of those bytes.
  sessionId: string;    // CodexKit's session_id header.
  clientRequestId: string; // CodexKit's x-client-request-id header.
  originator: string;   // CodexKit's originator header.
}

interface Authentication {
  accessToken: string;
  accountId: string;    // ChatGPT-Account-ID from the same CodexKit authentication context.
}
```

When the host receives base64-encoded bytes, decode them directly to a `Buffer`/`Uint8Array` using the CodexKit contract. Enforce the host's incoming payload limits before allocating. Do not parse and reserialize the provider body, or recalculate the supplied digest to hide a mismatch. Request bytes are copied and verified before transmission. Authentication is a separate per-call value; no token refresh, credential switching, or login flow is performed.

The existing Swift `prepareStructuredRecovery` API returns a local handle, not exported provider bytes. Its recovery record is internal. The CodexKit integration must supply the prepared bytes and header values explicitly; this package neither reads Swift recovery files nor changes the Swift API. Compatibility is based on the source snapshot recorded in [the fixture notes](docs/compatibility.md); there is no claim that a new Swift offload protocol has already shipped.

The response format is taken directly from the frozen body's `text.format`. There is no second independently mutable schema, model, or reasoning configuration in the library argument. Host job IDs, input revisions, contract versions, and attempt accounting stay with the CodexKit/host envelope.

### Supported text request subset

- Self-contained one-shot text or native JSON-schema output.
- `stream: true`, `store: false`, `tools: []`, and `tool_choice: "none"`.
- `input` contains CodexKit `message` items with `system`, `developer`, or `user` roles and `input_text` content.
- `text.format.type` is `text` or `json_schema`; JSON schema includes a name and schema.
- No image input in `execute`, tool calls, assistant history migration, previous response IDs, conversation references, or provider background mode. Dedicated generation/editing uses `executeImage` instead.

Models and reasoning effort strings are preserved exactly, including values unknown to this package. This library performs no model discovery, selection, downgrade, request repair, or fallback narration. `client.validatePreparedRequest(request)` runs the same preflight without a provider call.

## Execution configuration

The default endpoint matches CodexKit: `https://chatgpt.com/backend-api/codex/responses`. The library applies `Authorization: Bearer …`, `ChatGPT-Account-ID`, the three prepared routing headers, and JSON/SSE content negotiation.

Configure the client in trusted application code when needed:

```ts
import { CodexKitBridgeClient } from "@timazed/codexkit";

const client = new CodexKitBridgeClient({
  // Optional trusted profile values, never copied from an incoming payload:
  // endpoint: "https://your-trusted-provider.example/responses",
  // headers: { "x-codex-beta-features": "your-configured-feature" },
  limits: { maxOutputBytes: 8 * 1024 * 1024 },
});

// const result = await client.execute({ preparedRequest, authentication });
```

Endpoint overrides require HTTPS and cannot contain URL credentials, query parameters, or fragments. Reserved authentication, routing, and transport headers cannot be overridden. Redirects are returned as failures and are never followed. A supplied `fetch` implementation is a trusted transport/testing boundary and must preserve one-attempt semantics and honor cancellation.

## Results and progress

```ts
const result = await client.execute({
  preparedRequest,
  authentication,
  signal: explicitCancellationSignal, // Optional; controlled by your integration.
  onProgress: async event => {
    // Actual response.created, output_text.delta, or reasoning_summary_text.delta.
    // Provisional content; do not commit this as the completed result.
    await forwardProgressToYourConsumer(event);
  },
});
```

Progress callbacks are awaited for backpressure and may contain private content. A callback failure stops consumption with `progress_callback_failed`. Omitting the callback has no effect on execution. Cancelling the supplied signal aborts local transport; it does not prove provider-side cancellation. No generation deadline is imposed by the library.

An `ExecutionResult` contains:

| Field | Meaning |
| --- | --- |
| `status` | Always `completed` for a returned result. |
| `responseId`, optional `requestId` | Provider correlation identifiers. |
| `format` | `text` or `json_schema`, from CodexKit's request. |
| `outputText` | Exact concatenation of final-answer text parts; if there are no `final_answer` messages, unphased assistant messages. No trimming or separators are added. |
| `messages` | All completed assistant messages in provider order, including separately labeled commentary. |
| `output` | Completed provider output items, including reasoning metadata. |
| `completedEvent` | Original terminal JSON data, without SSE framing. |
| `usage` | Provider-supplied usage object, when present. |

The terminal output snapshot is authoritative. For CodexKit-compatible streams that omit `response.output`, the client uses indexed `response.output_item.done` records only after receiving a valid `response.completed`. Text deltas alone never establish completion. Absent terminal status is accepted for that existing CodexKit stream shape; an explicit noncompleted status, error, or incomplete details prevents success. The connection is released at terminal completion without waiting for EOF.

JSON output is parsed strictly and validated against the supplied schema before return. Validation follows CodexKit's bounded schema subset: primitive/union types, properties/required/additionalProperties, arrays, enum/const, composition, local references, numeric bounds, and size constraints. Unknown assertions (including `pattern` and `format`) and remote references are rejected before transmission. Defaults and coercion are never applied. Recursive validation and JSON parsing have work/depth limits.

Return `outputText` to CodexKit for its own typed decoding and application validation. It preserves whitespace, escaping, and large integer lexemes. Validation uses JavaScript numbers, as CodexKit's schema validator uses Double; parsed metadata in `output`/`usage` may have the same numeric precision limits. `completedEvent` preserves the original terminal JSON. Do not decode and reencode `outputText` when exact numeric representation matters.

## Failures

All execution failures reject with `CodexKitCloudError`. `error.toJSON()` returns `code`, a static message, and bounded diagnostic fields. Provider error messages, raw error bodies, transport causes, and callback/abort reasons are not retained. No logging is performed. Results and progress remain private application data, not log-safe diagnostics.

| Codes | Meaning |
| --- | --- |
| `invalid_request`, `integrity_mismatch`, `unsupported_request`, `unsupported_schema` | Preflight rejection. |
| `invalid_authentication` | Missing or malformed credential inputs. |
| `authentication_failed`, `http_error` | Unsuccessful provider HTTP response; includes status and safe provider code / Retry-After when available. |
| `image_usage_limit_exceeded` | Image allowance exhausted; optional reset time in `details.imageUsageLimit`. |
| `transport_error`, `stream_interrupted` | Failed connection or EOF before terminal completion. |
| `provider_failed`, `response_incomplete`, `response_refused` | Explicit unsuccessful provider outcome. |
| `invalid_response`, `unsupported_output` | Malformed event stream or unsupported output/tool activity. |
| `invalid_output`, `schema_mismatch` | Completed provider output failed JSON/schema validation. |
| `limit_exceeded` | Payload, item count, nesting, or validation work limit reached. |
| `cancelled`, `progress_callback_failed` | Caller cancellation or callback failure. |

`details.outcome` distinguishes `not_started`, `unknown`, `failed`, `incomplete`, and `completed`. It describes provider outcome evidence, not result usability or permission to retry. For example, schema failure can have `outcome: "completed"` but still returns no successful result. Transport failures after attempting the POST conservatively remain unknown. `invalid_configuration` is thrown synchronously by the client constructor.

A 401/403 never refreshes credentials or reissues a POST. Polling, job deduplication, retry budgets, and acknowledgement are host operations. Calling `client.execute` again is a new provider attempt, even with identical bytes.

## Resource bounds

Defaults are exported as `DEFAULT_LIMITS` and can be adjusted in trusted client configuration:

| Limit | Default |
| --- | --- |
| Request bytes | 4 MiB |
| SSE event bytes | 16 MiB |
| Total stream bytes | 128 MiB |
| Completed output bytes | 16 MiB |
| Output items | 1,024 |
| JSON / validation nesting | 64; configurable up to 128 |
| JSON nodes per document | 100,000 |
| Schema validation work steps | 100,000 |

HTTP error-body inspection is capped at 64 KiB or the configured event limit, whichever is smaller. Byte limits measure encoded content, not total JavaScript heap consumption. Unknown informational events are ignored; they cannot authorize tools or establish completion. Exact immediately repeated numbered events are suppressed; conflicting or backwards sequence numbers fail closed.

## Development and verification

```sh
# From the CodexKit repository root:
cd packages/codexkit
npm ci
npm run verify
```

Tests inject synthetic fetch responses and disable accidental live fetch calls. They verify text/image request fidelity, framing, output validation, typed failures, cancellation, redaction, and one-attempt behavior. The packaging check installs a local tarball into a temporary consumer and verifies CommonJS, ESM, TypeScript declarations, and both included route examples, including successful execution and error responses. It performs no provider calls and requires no credentials. Real provider/account compatibility has not been tested by these offline fixtures.

To try a local checkout without registry authentication, run `npm pack` after building, then install the resulting `timazed-codexkit-0.2.0.tgz` in the consuming backend. Normal consumers install the package by name with `npm install @timazed/codexkit`.

The repository's root `Cloud CI` workflow runs `npm ci` and `npm run verify` independently on Node 22 and 24 with this package's lockfile. Build output, dependencies, and local tarballs are ignored. There is no root npm workspace or Swift build step that invokes npm.

## Versioning and releases

The established `cloud-v<package version>` release tags continue independently of the npm name: `cloud-v0.1.0` published the original name, and `cloud-v0.1.1` publishes `@timazed/codexkit@0.1.1`. The version is owned by this directory's `package.json` and `package-lock.json`; it does not track the Swift SDK version. Future version changes should update both files without generating npm's default `v*` Git tag (for example, use `npm version <version> --no-git-tag-version`).

Pushing a `cloud-v*` tag runs `Cloud Release`: it validates the version and main ancestry, calls the Node 22/24 Cloud CI matrix, and publishes this package to GitHub Packages. Stable releases use the `latest` dist-tag; prereleases use `next`. Swift continues to use `v*` tags and its existing release workflow.

See [GitHub Packages release setup](docs/releases.md) for repository settings, package visibility, and release commands. The workflow uses the built-in `GITHUB_TOKEN` with `packages: write`, including for the first release. GitHub requires the `@timazed/` package scope; the `CodexKitBridgeClient` API and compatibility pin are unchanged.
