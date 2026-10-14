import type { ErrorDetails, ProviderReason } from "./errors.js";
import { isObject, parseJson, utf8 } from "./json.js";
import { abortable, checkAbort } from "./stream.js";
import type { ExecutionLimits, JsonValue } from "./types.js";

// A token-shaped string can still contain private content. Only known categories
// and protocol parameter paths may escape; extend these sets with offline fixtures.
const codes = new Set([
  "invalid_json_schema", "invalid_schema", "invalid_request_error", "invalid_request",
  "invalid_value", "invalid_parameter", "unsupported_parameter", "unsupported_value",
  "unknown_parameter", "missing_required_parameter", "missing_parameter",
  "context_length_exceeded", "string_above_max_length", "array_above_max_length",
  "invalid_api_key", "invalid_authentication", "authentication_error", "permission_denied",
  "insufficient_permissions", "model_not_found", "rate_limit_exceeded", "insufficient_quota",
  "usage_limit_reached", "content_policy_violation", "content_filter", "server_error",
  "internal_server_error", "service_unavailable", "overloaded", "generation_failed",
]);
const types = new Set([
  "invalid_request_error", "validation_error", "authentication_error", "permission_error",
  "not_found_error", "rate_limit_error", "insufficient_quota", "usage_limit_reached",
  "server_error", "api_error", "overloaded_error",
]);
const params = new Set([
  "model", "instructions", "input", "text", "text.format", "text.format.type", "text.format.name",
  "text.format.schema", "text.format.strict", "text.verbosity", "response_format",
  "response_format.type", "response_format.json_schema", "response_format.json_schema.name",
  "response_format.json_schema.schema", "response_format.json_schema.strict", "reasoning",
  "reasoning.effort", "reasoning.summary", "temperature", "top_p", "max_output_tokens",
  "max_completion_tokens", "max_tokens", "stream", "store", "tools", "tool_choice",
  "parallel_tool_calls", "truncation", "include", "background", "previous_response_id",
  "conversation", "prompt", "size", "quality", "images", "n",
]);

function member(value: unknown, allowed: ReadonlySet<string>): string | undefined {
  return typeof value === "string" && allowed.has(value) ? value : undefined;
}

function parameter(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length > 128 || /[^\x21-\x7e]/.test(value)) return;
  if (params.has(value)) return value;
  // Indices are bounded; property names from user-defined schemas are never accepted.
  if (/^input\[\d{1,4}\](?:\.(?:role|type|content)|\.content\[\d{1,4}\](?:\.(?:type|text|image_url|detail))?)?$/.test(value) ||
      /^images\[\d{1,4}\](?:\.image_url)?$/.test(value)) return value;
  return;
}

function identifier(value: unknown, kind: "request" | "response" | "image"): string | undefined {
  if (typeof value !== "string" || value.length > 256 || /[^\x21-\x7e]/.test(value)) return;
  const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
  const prefix = kind === "response" ? /^resp[-_][A-Za-z0-9-]+$/ :
    kind === "image" ? /^(?:req|image)[-_][A-Za-z0-9-]+$/ : /^(?:req|request)[-_][A-Za-z0-9-]+$/;
  return prefix.test(value) || (kind !== "response" && uuid.test(value)) ? value : undefined;
}

function reason(status: number, code: string | undefined, type: string | undefined, param: string | undefined,
  message: unknown): ProviderReason {
  if (code === "invalid_json_schema" || code === "invalid_schema") return "invalid_schema";
  if (code === "unsupported_parameter" || code === "unknown_parameter") return "unsupported_parameter";
  if (code === "missing_required_parameter" || code === "missing_parameter") return "missing_parameter";
  if (code === "context_length_exceeded") return "context_length_exceeded";
  if (code === "content_policy_violation" || code === "content_filter") return "content_policy";
  if (code === "insufficient_quota" || code === "usage_limit_reached" ||
      type === "insufficient_quota" || type === "usage_limit_reached") return "quota_exceeded";
  if (status === 401 || code === "invalid_api_key" || code === "invalid_authentication" ||
      code === "authentication_error" || type === "authentication_error") return "authentication";
  if (status === 403 || code === "permission_denied" || code === "insufficient_permissions" || type === "permission_error") return "permission_denied";
  if (status === 429 || code === "rate_limit_exceeded" || type === "rate_limit_error") return "rate_limit_exceeded";
  if (status >= 500) return "server_error";
  // Recognize only a schema-rejection template in the relevant 400 parameter context.
  // The schema name, context, offending value and all other message bytes are discarded.
  if (status === 400 && param && ["text.format", "text.format.schema", "response_format",
      "response_format.json_schema", "response_format.json_schema.schema"].includes(param) &&
      typeof message === "string" && /^Invalid schema for (?:response_format|text\.format)\b/.test(message)) return "invalid_schema";
  if (param || ["invalid_value", "invalid_parameter", "unsupported_value", "string_above_max_length",
      "array_above_max_length", "model_not_found"].includes(code ?? "")) return "invalid_parameter";
  if (status === 400 || status === 422 || code === "invalid_request" || code === "invalid_request_error" ||
      type === "invalid_request_error" || type === "validation_error") return "invalid_request";
  return "unclassified";
}

/** Complete, bounded JSON only; MIME metadata is not authoritative on HTTP failures. */
export async function readHTTPErrorBody(response: Response, limits: ExecutionLimits, signal: AbortSignal,
  maximum = Math.min(64 * 1024, limits.maxEventBytes)): Promise<JsonValue | undefined> {
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  try {
    checkAbort(signal);
    if (!response.body) return;
    const length = response.headers.get("content-length");
    if (length && /^\d+$/.test(length) && Number(length) > maximum) return;
    reader = response.body.getReader();
    // One fixed buffer also bounds bookkeeping for single-byte and empty chunks.
    const bytes = Buffer.allocUnsafe(maximum);
    let used = 0, empty = 0;
    while (true) {
      checkAbort(signal);
      const next = await abortable(reader.read(), signal);
      if (next.done) break;
      if (!next.value.byteLength) { if (++empty > 1024) return; continue; }
      empty = 0;
      if (next.value.byteLength > maximum - used) return;
      bytes.set(next.value, used);
      used += next.value.byteLength;
    }
    checkAbort(signal);
    return parseJson(utf8(bytes.subarray(0, used), "invalid_response"), limits, "invalid_response");
  } catch {
    checkAbort(signal);
    // Body, UTF-8, JSON and resource-limit failures cannot replace the HTTP status.
    return;
  } finally {
    if (reader) {
      void reader.cancel().catch(() => {});
      reader.releaseLock();
    } else if (response.body && !response.body.locked) void response.body.cancel().catch(() => {});
  }
}

export function httpDiagnostics(response: Response, value: JsonValue | undefined): ErrorDetails {
  const root = isObject(value) ? value : undefined;
  const error = isObject(root?.error) ? root.error : undefined;
  const providerCode = member(error?.code, codes);
  const providerType = member(error?.type, types);
  const providerParam = parameter(error?.param);
  const requestId = identifier(response.headers.get("x-request-id"), "request") ??
    identifier(root?.request_id, "request") ?? identifier(error?.request_id, "request");
  const responseId = identifier(response.headers.get("x-response-id"), "response") ??
    identifier(root?.response_id, "response") ?? identifier(error?.response_id, "response") ??
    identifier(isObject(root?.response) ? root.response.id : undefined, "response");
  const retryAfter = response.headers.get("retry-after");
  const validRetry = retryAfter && retryAfter.length <= 128 && (/^\d+(?:\.\d+)?$/.test(retryAfter) ||
    /^[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(retryAfter));
  return {
    ...(providerCode ? { providerCode } : {}), ...(providerType ? { providerType } : {}),
    ...(providerParam ? { providerParam } : {}), ...(requestId ? { requestId } : {}),
    ...(responseId ? { responseId } : {}), ...(validRetry ? { retryAfter } : {}),
    providerReason: reason(response.status, providerCode, providerType, providerParam, error?.message),
  };
}

/** Apply at the public error boundary, including header IDs retained during cancellation. */
export function redactHTTPIdentifiers(details: ErrorDetails, body: Uint8Array | undefined): ErrorDetails {
  const safe = { ...details };
  // Only runs after an unsuccessful HTTP response. The request was already strictly
  // validated and snapshotted; normalization detects IDs echoed from escaped JSON too.
  let requestText: string | undefined;
  const strings: string[] = [];
  try {
    if (body) requestText = JSON.stringify(JSON.parse(Buffer.from(body).toString("utf8"), (key: string, value: unknown) => {
      if (key) strings.push(key);
      if (typeof value === "string" && value) strings.push(value);
      return value;
    }));
  } catch { /* Omit identifiers if the privacy check cannot be completed. */ }
  for (const [key, kind] of [["requestId", "request"], ["responseId", "response"], ["imageRequestId", "image"]] as const) {
    const value = identifier(safe[key], kind);
    if (!value || requestText === undefined || requestText.includes(value) ||
        strings.some(text => value.includes(text))) delete safe[key];
  }
  return safe;
}
