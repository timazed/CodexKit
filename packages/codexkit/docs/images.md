# Image generation and editing

`CodexKitBridgeClient.executeImage(...)` executes one prepared request using the dedicated Codex Images endpoints. It returns validated PNG data, actual pixel dimensions, creation time, and correlation IDs. This does not enable Responses tools or change `execute(...)`.

```ts
import { CodexKitBridgeClient } from "@timazed/codexkit";
import type { Authentication, PreparedImageRequest } from "@timazed/codexkit";

const client = new CodexKitBridgeClient();

export async function generateOrEdit(
  preparedRequest: PreparedImageRequest,
  authentication: Authentication,
  signal: AbortSignal,
) {
  const result = await client.executeImage({ preparedRequest, authentication, signal });
  return result; // JSON-serializable; each image has base64, mimeType and pixelSize.
}
```

Decode an image with `Buffer.from(result.images[0]!.base64, "base64")`. The host decides where to store those bytes and how to deliver them to its app. Results and image data are private application content, not log-safe diagnostics. The [route example](../examples/image-api-route.ts) shows HTTP success and error handling.

## Prepared request contract

The host supplies an existing CodexKit request without rewriting its JSON:

| Field | Meaning |
| --- | --- |
| `action` | `"generate"` or `"edit"`; selects the dedicated endpoint. |
| `body` | Exact UTF-8 provider JSON as `Uint8Array`. |
| `sha256` | CodexKit's lowercase SHA-256 of those bytes. |
| `clientRequestId` | Original `x-client-request-id` header. |
| `imageTurnId` | Original `x-codex-image-turn-id` header. |
| `originator` | Original `originator` header. |

Authentication is the same separate `{ accessToken, accountId }` argument used by text execution. The bridge snapshots and validates the request and credentials before its first asynchronous operation. `validatePreparedImageRequest(request)` performs preflight without transmitting.

The accepted provider body matches Swift's dedicated `CodexImagesClient` contract: a nonblank `prompt`, `background` of `"transparent"` or `"opaque"`, `model: "gpt-image-2"`, `quality: "auto"`, and `size: "auto"`. Generation omits `images`; editing includes one to five `{ image_url: "data:image/<png|jpeg|webp>;base64,..." }` references totaling at most 32 MiB of decoded bytes. Reference bytes remain unchanged; the provider validates their image content. Remote URLs, tools, extra body fields, and quality/model/size overrides are rejected before transmission.

The default endpoints are `https://chatgpt.com/backend-api/codex/images/generations` and `/images/edits`. A trusted constructor `endpoint` ending in `/responses` selects sibling image routes under that same base path. Incoming requests cannot supply endpoints or override authentication headers. Redirects are not followed.

## Completion, failures and cancellation

A successful return requires the entire JSON HTTP body to finish, a successful provider outcome, and one or more valid PNG images. Partial bodies, URL-only output, failed/incomplete responses, invalid base64, corrupt PNG chunks or compressed scanlines, and exhausted limits reject with `CodexKitCloudError`. Dimensions come from the PNG bytes; a provider `size` hint cannot override them. PNG validation follows the [PNG specification](https://www.w3.org/TR/png-3/), including CRCs, scanline framing, palettes and Adam7 interlacing. Animated PNG is outside this contract. Ancillary color profiles are preserved without interpretation.

`ImageExecutionResult` contains `status: "completed"`, `action`, `created` (Unix seconds), `clientRequestId`, optional `requestId`/`imageRequestId`, optional recognized `background`/`quality`, and `images`. Each image has canonical `base64`, `mimeType: "image/png"`, `pixelSize: { width, height }`, and an optional sanitized `generationId`.

An image-specific allowance error uses `code: "image_usage_limit_exceeded"`, with `details.imageUsageLimit.limitId: "image_gen"` and optional `resetsAt` in Unix seconds. The provider's body reset takes precedence over exhausted image-window headers. Missing reset metadata stays unknown. Other HTTP and transport errors use the existing error codes. Provider messages and raw error bodies are not exposed.

There is one provider POST per call, no retries, credential refresh, progress stream, fallback request, or implicit generation timeout. An explicit `AbortSignal` cancels waiting for headers or body data and releases the connection. Cancellation cannot confirm the remote provider stopped generating. The host owns deadlines, attempt accounting and any later retry decision.

Since `0.2.1`, workers can opt into [`nodeHttpsTransport`](../README.md#long-running-node-requests) when generation may wait several minutes for headers. Configure it through `new CodexKitBridgeClient({ fetch: nodeHttpsTransport })` and pass the host's deadline signal to `executeImage`. The default client still uses `fetch`; the transport does not add scheduling or durable execution.

## Resource limits

Configure `imageLimits` on the client; defaults are exported as `DEFAULT_IMAGE_LIMITS`:

| Limit | Default |
| --- | --- |
| Request / response JSON bytes | Base64 capacity for 32 MiB plus 1 MiB of metadata. |
| Total decoded reference or output image bytes | 32 MiB. |
| Output images | 32. |
| Total output pixels | 32 million. |
| Inflated PNG scanlines per image | 128 MiB. |

Image count and decoded-byte limits may be lowered but cannot exceed the Swift contract. Other positive limits are host configurable. Existing `limits.maxJsonDepth` and `maxJsonNodes` also apply. HTTP error-body inspection is capped at 64 KiB. These bound encoded data and validation work, not total process heap usage; the host must also bound concurrency and incoming envelopes.

## Integration status

The [compatibility notes](compatibility.md) identify the Swift source used for this implementation. The local API supports `POST /v1/images/execute`, with synthetic PNG responses in fixture mode and real single-attempt execution in live mode. The existing Swift demo's Local Cloud card still exercises structured text; its Images screen uses direct Swift execution.

A public Swift image request-export API, app routing through this bridge, importing cloud images into Swift persistence, and durable jobs/result lookup remain separate work. Offline tests cover both image actions, HTTP, cancellation, resource limits, package imports and the route adapter. They do not establish live provider/account compatibility.
