import type { ErrorDetails, ProviderOutcome, ProviderReason } from "./errors.js";

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

function member<T extends string>(value: unknown, allowed: ReadonlySet<T>): T | undefined {
  return typeof value === "string" && allowed.has(value as T) ? value as T : undefined;
}

export function parameter(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length > 128 || /[^\x21-\x7e]/.test(value)) return;
  if (params.has(value)) return value;
  // Indices are bounded; property names from user-defined schemas are never accepted.
  if (/^input\[\d{1,4}\](?:\.(?:role|type|content)|\.content\[\d{1,4}\](?:\.(?:type|text|image_url|detail))?)?$/.test(value) ||
      /^images\[\d{1,4}\](?:\.image_url)?$/.test(value)) return value;
  return;
}

export function identifier(value: unknown, kind: "request" | "response" | "image"): string | undefined {
  if (typeof value !== "string" || value.length > 256 || /[^\x21-\x7e]/.test(value)) return;
  const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
  const prefix = kind === "response" ? /^resp[-_][A-Za-z0-9-]+$/ :
    kind === "image" ? /^(?:req|image)[-_][A-Za-z0-9-]+$/ : /^(?:req|request)[-_][A-Za-z0-9-]+$/;
  return prefix.test(value) || (kind !== "response" && uuid.test(value)) ? value : undefined;
}

export const providerCode = (value: unknown): string | undefined => member(value, codes);
export const providerType = (value: unknown): string | undefined => member(value, types);

export function retryAfter(value: unknown): string | undefined {
  return typeof value === "string" && value.length <= 128 &&
    (/^\d+(?:\.\d+)?$/.test(value) || /^[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(value)) &&
    !/[^\x20-\x7e]/.test(value) ? value : undefined;
}

export function resetTime(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

const outcomes: ReadonlySet<ProviderOutcome> = new Set(["not_started", "unknown", "failed", "incomplete", "completed"]);
const reasons: ReadonlySet<ProviderReason> = new Set([
  "invalid_schema", "invalid_parameter", "unsupported_parameter", "missing_parameter",
  "context_length_exceeded", "content_policy", "authentication", "permission_denied",
  "rate_limit_exceeded", "quota_exceeded", "invalid_request", "server_error", "unclassified",
]);
// Incomplete diagnostics, like provider codes, must be categories rather than arbitrary tokens.
const incompleteReasons = new Set(["max_output_tokens", "content_filter"]);
export const incompleteReason = (value: unknown): string | undefined => member(value, incompleteReasons);

/** Only JSON records; inherited properties and executable getters are not serialized data. */
export function record(value: unknown): object | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return;
  const prototype = Object.getPrototypeOf(value);
  return prototype === null || prototype === Object.prototype ? value : undefined;
}

export function field(value: object, key: string): unknown {
  const descriptor = Object.getOwnPropertyDescriptor(value, key);
  return descriptor && "value" in descriptor ? descriptor.value : undefined;
}

/** One explicit field/value policy for live errors, serialization, and persisted failures. */
export function sanitizeFailureDetails(value: unknown): ErrorDetails {
  const input = record(value);
  if (!input) return {};
  const outcome = member(field(input, "outcome"), outcomes);
  const status = field(input, "httpStatus");
  const httpStatus = typeof status === "number" && Number.isInteger(status) && status >= 100 && status <= 599 ? status : undefined;
  const requestId = identifier(field(input, "requestId"), "request");
  const responseId = identifier(field(input, "responseId"), "response");
  const code = providerCode(field(input, "providerCode"));
  const type = providerType(field(input, "providerType"));
  const param = parameter(field(input, "providerParam"));
  const providerReason = member(field(input, "providerReason"), reasons);
  const incomplete = incompleteReason(field(input, "incompleteReason"));
  const retry = retryAfter(field(input, "retryAfter"));
  const imageRequestId = identifier(field(input, "imageRequestId"), "image");
  const limit = record(field(input, "imageUsageLimit"));
  const resetsAt = limit ? resetTime(field(limit, "resetsAt")) : undefined;
  const imageUsageLimit = limit && field(limit, "limitId") === "image_gen" ? {
    limitId: "image_gen" as const, ...(resetsAt !== undefined ? { resetsAt } : {}),
  } : undefined;
  return {
    ...(outcome !== undefined ? { outcome } : {}), ...(httpStatus !== undefined ? { httpStatus } : {}),
    ...(requestId !== undefined ? { requestId } : {}), ...(responseId !== undefined ? { responseId } : {}),
    ...(code !== undefined ? { providerCode: code } : {}), ...(type !== undefined ? { providerType: type } : {}),
    ...(param !== undefined ? { providerParam: param } : {}), ...(providerReason !== undefined ? { providerReason } : {}),
    ...(incomplete !== undefined ? { incompleteReason: incomplete } : {}), ...(retry !== undefined ? { retryAfter: retry } : {}),
    ...(imageRequestId !== undefined ? { imageRequestId } : {}), ...(imageUsageLimit ? { imageUsageLimit } : {}),
  };
}

