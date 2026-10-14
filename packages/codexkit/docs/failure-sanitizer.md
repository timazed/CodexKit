# Sanitizing serialized failures (Cloud 0.2.5)

`sanitizeCodexFailure` lets consumers normalize untrusted historical failure JSON with the SDK's own field and value policy. It is synchronous, deterministic for JSON data, non-mutating, and performs no network, credential, environment, or clock access. It makes no generation attempt and supplies no retry advice.

```ts
import { sanitizeCodexFailure, type SanitizedCodexFailure } from "@timazed/codexkit";

const safe: SanitizedCodexFailure | undefined = sanitizeCodexFailure(storedFailure);
```

Pass the **parsed, flat failure object**, including the result of `CodexKitCloudError.toJSON()` or `JSON.parse(JSON.stringify(error))`. Extract your application's envelope first (for example, `stored.error`). A JSON string is not parsed by this function. A live `CodexKitCloudError` should be passed through `toJSON()` first. Only plain records (including null-prototype records) with an own, recognized `code` are accepted. Inherited fields, accessors and `toJSON` hooks are not read or invoked. Executable objects such as proxies are outside the serialized-JSON contract; inspection errors return `undefined`.

The invalid-input result is **`undefined`** for a non-record or missing, malformed, unknown, future, or application-specific SDK `code`. There is no invented fallback code. A recognized code with invalid optional diagnostics still returns a failure; each invalid diagnostic is omitted. A missing outcome stays missing, and no classification or diagnostic is inferred from a supplied message or status. The application owns its fallback and future-version handling.

`SanitizedCodexFailure` extends the published `ErrorDetails` with required `code: ErrorCode` and `message: string`. It reuses `ProviderOutcome`, `ProviderReason`, and the existing image-limit shape. All diagnostic properties remain optional. Each successful call returns a fresh object and a fresh `imageUsageLimit`, if retained. Outputs share no object references with the input, and sanitizing an output again gives the same values.

## Exact allowlist and validation

| Field | Retained values |
| --- | --- |
| `code` | A currently published SDK `ErrorCode`. |
| `message` | Always regenerated from the static SDK label for `code`; supplied text is ignored. |
| `outcome` | `not_started`, `unknown`, `failed`, `incomplete`, `completed`. |
| `httpStatus` | Integer from 100 through 599; the provider's status, not the consuming route's status. |
| `requestId`, `responseId`, `imageRequestId` | The existing [HTTP identifier formats and bounds](http-errors.md#validation-and-privacy). `requestId` means the **provider request ID**, never the consuming API's HTTP request ID. |
| `providerCode`, `providerType`, `providerParam` | The existing [SDK category and protocol-path allowlists](http-errors.md#validation-and-privacy); no arbitrary token or schema-property names. |
| `providerReason` | A published `ProviderReason` category. Missing values are not reconstructed. |
| `incompleteReason` | `max_output_tokens` or `content_filter`; arbitrary provider tokens are omitted. |
| `retryAfter` | At most 128 printable ASCII characters: a non-negative decimal string or the SDK's HTTP-date-shaped syntax. Informational; not a parsed calendar date or permission to retry. |
| `imageUsageLimit.limitId` | Exactly `image_gen`; otherwise the entire nested object is omitted. |
| `imageUsageLimit.resetsAt` | Optional finite non-negative number, preserving the existing reset-time rule (including fractional values). Invalid reset values do not remove a valid `limitId`. |

No other fields survive. In particular, `name`, `stack`, raw diagnostics, provider bodies/messages, prompts, credentials, account fields, signed URLs, nested `details`, and arbitrary nested properties are never copied. Unknown/unsafe values are omitted rather than coerced or truncated. The sanitizer does not validate causal consistency between otherwise valid categories and cannot prove that a stored failure really occurred.

The implementation shares the SDK's HTTP category, parameter, identifier, Retry-After and image reset validators. `CodexKitCloudError` construction and `toJSON()` use the same explicit safe-detail policy, and serialization regenerates the static message even if `Error.message` was overwritten. In 0.2.5 this also applies the closed category/identifier policy to manually constructed and stream-terminal errors: unknown optional provider codes, incomplete reasons and opaque correlation formats may now be omitted. Existing SDK error codes, request validation, models, outcome/retry behavior and successful results are unchanged.

For example, after dropping a stored provider message, raw body, and additional account properties:

```json
{
  "code": "http_error",
  "message": "The provider returned an unsuccessful HTTP response.",
  "outcome": "failed",
  "httpStatus": 400,
  "requestId": "req-headerfixture",
  "responseId": "resp_schemafixture",
  "providerCode": "invalid_json_schema",
  "providerType": "invalid_request_error",
  "providerParam": "text.format.schema",
  "providerReason": "invalid_schema"
}
```

An older `{ "code": "http_error" }` normalizes to just that code and its static message. It does not acquire `providerReason`, `outcome` or any IDs.

## Historical privacy limits

Treat persisted JSON as untrusted even if an earlier SDK wrote it. The sanitizer enforces structure and value vocabularies, not authenticity or the provenance of an identifier. Without the original validated request and credentials, it cannot repeat the live SDK's request-echo and secret-substring redaction. A private value disguised as an otherwise valid identifier (for example `req-echoedprompt`, or an account ID that happens to be a UUID) is indistinguishable from a real provider ID. Numeric metadata and known categories likewise cannot be authenticated from stored JSON alone.

Live HTTP failures still get the SDK's existing context-aware redaction before serialization. The sanitizer cannot recover absent historical diagnostics or certify that old identifiers passed that redaction. If historical provenance is insufficient for your logging policy, omit correlation IDs in your application's projection. Do not pass credentials or raw requests to this API to compensate; it intentionally has no such inputs. An incident's original generation defect is not established or fixed by this normalization.

## mp-api migration

After the Cloud release and registry verification succeed, pin `@timazed/codexkit@0.2.5` in a separately authorized mp-api change. Replace `CodexFailureParser`'s duplicate SDK code/reason lists, regexes and nested-value validation with one call, then keep the application's existing field projection and fallback:

```ts
import { sanitizeCodexFailure, type SanitizedCodexFailure } from "@timazed/codexkit";

// Existing application-owned DTO projection; these names are illustrative.
function parseStoredFailure(stored: unknown) {
  const safe: SanitizedCodexFailure | undefined = sanitizeCodexFailure(stored);
  if (!safe) return applicationFailureFallback();
  return projectApplicationFields(safe);
}
```

`applicationFailureFallback` and `projectApplicationFields` remain mp-api code; they are not SDK exports. The [compilable projection example](../examples/failure-projection.ts) demonstrates selecting fields with `Pick<SanitizedCodexFailure, ...>` and preserving optionality without reimplementing value rules. Keep the existing application-specific failure codes, persisted job schema, API response envelope, log policy and consuming API HTTP request ID outside the SDK. Never substitute that API ID for `safe.requestId`.

This release does not modify or deploy mp-api, migrate stored jobs, replay production generations, or change Swift. Tests exercise fixture HTTP 400s through actual SDK execution, JSON round trips, legacy failures, unsafe values, message regeneration, freshness/immutability, unchanged success paths, and packed CommonJS/ESM/TypeScript consumers entirely offline.
