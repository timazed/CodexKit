# HTTP error consumer contract (Cloud 0.2.4)

This additive contract applies to unsuccessful provider HTTP responses from `CodexKitBridgeClient.execute` and `executeImage`, using either fetch or `nodeHttpsTransport`. It improves diagnosis only. Request bytes, model selection, validation, one-attempt execution, retries and successful response handling are unchanged. The October 14, 2026 Pocket POTUS Day 20 failures do not establish which provider rule was violated; the synthetic fixtures are representative, not recovered production responses.

## Serialization and compatibility

In JavaScript, diagnostics are available on `error.details`. `error.toJSON()` and `JSON.stringify(error)` flatten those diagnostics alongside `code` and `message`. There is **no nested `details` object in the wire format**. The JavaScript `name` remains `CodexKitCloudError` and is not a serialized field. For example, a host route can return `{ "error": error.toJSON() }`:

```json
{
  "error": {
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
}
```

| Exact field | Type | Meaning |
| --- | --- | --- |
| `code` | string | Existing SDK error code: `authentication_failed` for 401/403; otherwise `http_error`, except the existing image-quota classification `image_usage_limit_exceeded`. |
| `message` | string | Existing static SDK message; never provider-authored text. |
| `outcome` | string | Existing provider evidence: `failed` for 400–499, `unknown` for other unsuccessful HTTP statuses (including redirects and 5xx). Does not imply permission to retry. |
| `httpStatus` | number | Existing upstream HTTP status, distinct from the middleware route's HTTP status. |
| `requestId` | optional string | Provider request correlation ID: valid `x-request-id`, then top-level JSON `request_id`, then `error.request_id`. Never the client's job ID or `x-client-request-id`. |
| `responseId` | optional string | Provider response correlation ID: valid `x-response-id`, then top-level `response_id`, `error.response_id`, then `response.id`. Does not imply generation completed. |
| `providerCode` | optional string | Provider `error.code`, preserved verbatim only when in the safe code vocabulary below. Unknown/unsafe codes are omitted. |
| `providerType` | optional string, **new** | Provider `error.type`, preserved verbatim only when in the safe type vocabulary below. |
| `providerParam` | optional string, **new** | Provider `error.param`, preserved verbatim only for the known protocol paths below. It is never extracted from provider prose. |
| `providerReason` | optional string, **new** | SDK-authored classification from the table below. Emitted for completed HTTP error inspection, including unreadable/absent bodies. Optional in consumer DTOs for compatibility with older versions and cancellation/non-HTTP errors. |
| `retryAfter` | optional string | Existing bounded numeric or HTTP-date Retry-After header. Informational only; the SDK does not retry. |
| `imageRequestId` | optional string | Existing `x-codex-imagegen-request-id` for image requests, subject to identifier/privacy validation. |
| `imageUsageLimit` | optional object | Existing image allowance metadata `{ "limitId": "image_gen", "resetsAt"?: number }`; existing quota evidence rules still apply. |

No fields were renamed, removed or nested. Existing `code`, `message`, `outcome` and `httpStatus` semantics are unchanged. `providerCode` and HTTP correlation identifiers now fail closed for unknown/unsafe values; consumers must already tolerate their absence. Stream-terminal errors and successful results retain their existing contracts. `ErrorDetails` and the new `ProviderReason` type are exported from `@timazed/codexkit`.

## Safe rejection reasons

These are diagnostic categories, not definitive root-cause findings or retry instructions. Consumers must accept unknown future strings. No provider message, schema name, schema property, input value or arbitrary explanation is included.

| `providerReason` | Meaning / evidence |
| --- | --- |
| `invalid_schema` | Known `invalid_json_schema`/`invalid_schema` code; or HTTP 400 with a known format/schema parameter and the provider template prefix `Invalid schema for response_format` or `Invalid schema for text.format`. The rest of the message is discarded. |
| `unsupported_parameter` | Known `unsupported_parameter`/`unknown_parameter` code. |
| `missing_parameter` | Known `missing_required_parameter`/`missing_parameter` code. |
| `context_length_exceeded` | Known code of the same name. |
| `content_policy` | Known `content_policy_violation`/`content_filter` code. |
| `quota_exceeded` | Known `insufficient_quota`/`usage_limit_reached` code or type. |
| `authentication` | HTTP 401 or known authentication code/type. |
| `permission_denied` | HTTP 403 or known permission code/type. |
| `rate_limit_exceeded` | HTTP 429 or known rate-limit code/type. |
| `server_error` | HTTP 5xx, absent an earlier specific classification. |
| `invalid_parameter` | A validated rejected parameter or known invalid-value/parameter, unsupported-value, length-limit or model-not-found code. |
| `invalid_request` | HTTP 400/422 or known invalid-request/validation code/type, without a more specific classification. |
| `unclassified` | Unsuccessful HTTP response without evidence for a category above. |

The implementation evaluates specific code categories first (in the order above), then authentication/permission/rate-limit evidence and 5xx, then the schema message template, parameter evidence, and generic status/type fallbacks. A category can remain useful when unsafe individual fields are omitted. It never overrides the SDK error code, status or outcome.

## Validation and privacy

Error JSON is inspected regardless of Content-Type. Only a complete UTF-8 JSON body of at most `min(65536, limits.maxEventBytes)` bytes is parsed, using the existing strict duplicate-key, depth and node limits. A declared Content-Length above the cap skips inspection; actual bytes are always bounded even if Content-Length is missing or misleading. Oversized/truncated/non-JSON/malformed bodies contribute no body fields. Valid header metadata and the authoritative HTTP failure survive. Reads stop at the cap crossing, use bounded storage, and stop after 1,025 consecutive empty chunks. Readers are cancelled/released without waiting for a custom transport's cleanup. A stalled read remains cancellable by the caller's signal; there is no new timeout or retry.

Only the documented JSON paths and headers are considered. Authentication headers, cookies, tokens, account fields, prompts, raw provider bodies, arbitrary transport causes and abort reasons are never copied. Provider prose is never retained; the schema template only selects a static enum. Logging should serialize the SDK error, not a raw response, transport cause, request, or authentication object.

Validation is stricter than a generic “looks like a token” regex:

- **Codes:** `invalid_json_schema`, `invalid_schema`, `invalid_request_error`, `invalid_request`, `invalid_value`, `invalid_parameter`, `unsupported_parameter`, `unsupported_value`, `unknown_parameter`, `missing_required_parameter`, `missing_parameter`, `context_length_exceeded`, `string_above_max_length`, `array_above_max_length`, `invalid_api_key`, `invalid_authentication`, `authentication_error`, `permission_denied`, `insufficient_permissions`, `model_not_found`, `rate_limit_exceeded`, `insufficient_quota`, `usage_limit_reached`, `content_policy_violation`, `content_filter`, `server_error`, `internal_server_error`, `service_unavailable`, `overloaded`, `generation_failed`.
- **Types:** `invalid_request_error`, `validation_error`, `authentication_error`, `permission_error`, `not_found_error`, `rate_limit_error`, `insufficient_quota`, `usage_limit_reached`, `server_error`, `api_error`, `overloaded_error`.
- **Parameters:** `model`, `instructions`, `input`, `text`, `text.format`, `text.format.type`, `text.format.name`, `text.format.schema`, `text.format.strict`, `text.verbosity`, `response_format`, `response_format.type`, `response_format.json_schema`, `response_format.json_schema.name`, `response_format.json_schema.schema`, `response_format.json_schema.strict`, `reasoning`, `reasoning.effort`, `reasoning.summary`, `temperature`, `top_p`, `max_output_tokens`, `max_completion_tokens`, `max_tokens`, `stream`, `store`, `tools`, `tool_choice`, `parallel_tool_calls`, `truncation`, `include`, `background`, `previous_response_id`, `conversation`, `prompt`, `size`, `quality`, `images`, `n`. Also `input[I]`, `input[I].role`, `.type`, `.content`, `.content[J]`, `.content[J].type`, `.text`, `.image_url`, `.detail`, and `images[I]`/`images[I].image_url`, with each index 1–4 decimal digits and the full path at most 128 characters. Custom schema property paths are omitted entirely.
- **Identifiers:** at most 256 characters; request IDs start with `req-`, `req_`, `request-` or `request_`; response IDs start with `resp-` or `resp_`; image IDs start with `req-`, `req_`, `image-` or `image_`. Suffixes contain only ASCII letters, digits and hyphens. Canonical hexadecimal UUIDs are additionally accepted for request/image IDs. Other opaque formats are omitted pending an explicit reviewed validator.
- **Redaction:** fields containing the caller's access token, account ID, configured header values or request routing header values are omitted. HTTP identifiers are additionally omitted when they appear in normalized request JSON or contain any of its string values/keys. This conservative check can omit a legitimate identifier rather than risk an echo; JSON escapes do not bypass it. Static `outcome` and `providerReason` categories are unaffected by short credentials. No unsafe value is truncated into a supposedly safe value.

Cancellation still reports `cancelled`; before transmission its outcome is `not_started`, and while waiting for/reading an HTTP response it is `unknown`. Aborting body inspection does not convert cancellation into `http_error` or invent a completed provider failure. Errors after an HTTP status has arrived do not become `transport_error` merely because diagnostic body inspection failed.

## mp-api and Swift rollout

1. Merge this PR, which prepares package and lockfile version **0.2.4**. It does not publish a package. After merge, use the [Cloud release procedure](releases.md) to tag the merged commit **`cloud-v0.2.4`**. Cloud CI must pass Node 22/24 verification before GitHub Packages publication. Do not use a Swift `v*` tag. If 0.2.4 has already been published by then, prepare a new patch version in both manifests; never overwrite a published version or move a tag.
2. After Cloud Release and its registry-install checks succeed, update mp-api with `npm install --save-exact @timazed/codexkit@0.2.4` using its existing GitHub Packages authentication. Commit its manifest and lockfile, verify `npm ls @timazed/codexkit`, and deploy that locked version. This repository does not update or deploy mp-api.
3. Have mp-api persist/forward the flat `error.toJSON()` fields listed above. If its DTO/logger allowlists fields, add exactly `providerType`, `providerParam`, `providerReason` and preserve `httpStatus`, `requestId`, `responseId`, `providerCode` and existing metadata. Do not rename fields to `status`, `request_id`, `providerMessage`, or `param`. Keep middleware job IDs separate. Do not serialize the request, arbitrary caught errors or provider bodies as additional context.
4. In the Swift app's middleware-error DTO, decode the additions as optional strings with their exact camelCase keys. If using `.convertFromSnakeCase`/custom keys, verify the mapping explicitly. Use an unknown-safe enum or string for `providerReason`; tolerate older jobs with absent fields and future reasons. Display the static message/classification and safe rejected parameter; keep existing code/outcome handling. Test the example above through the actual mp-api envelope and the app's DTO before deployment. This PR does not change the Swift SDK or its release version.
5. Confirm the deployed service persists the new safe diagnostics using an offline/synthetic HTTP 400 fixture. Any future production evidence must come from separately authorized execution; do not replay the seven incident jobs just to populate new logs. Historical failures cannot gain provider fields retroactively. This change neither establishes nor fixes the underlying Pocket POTUS request defect.
