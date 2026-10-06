import { createHash } from "node:crypto";
import { fail } from "./errors.js";
import { isObject, parseJson, utf8 } from "./json.js";
import { validateSchema } from "./schema.js";
import type { Authentication, ExecutionLimits, JsonValue, PreparedRequest } from "./types.js";

export interface ValidatedRequest {
  readonly body: Uint8Array<ArrayBuffer>;
  readonly headers: Readonly<Record<string, string>>;
  readonly format: "text" | "json_schema";
  readonly schema?: JsonValue;
}

export function headerValue(value: unknown, maxLength = 1024): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength && /^[\x21-\x7e]+$/.test(value);
}

export function prepareRequest(input: PreparedRequest, limits: ExecutionLimits): ValidatedRequest {
  if (!input || !(input.body instanceof Uint8Array) || !input.body.byteLength) fail("invalid_request");
  if (input.body.byteLength > limits.maxRequestBytes) fail("limit_exceeded");
  if (typeof input.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(input.sha256)) fail("invalid_request");
  for (const value of [input.sessionId, input.clientRequestId, input.originator]) {
    if (!headerValue(value)) fail("invalid_request");
  }
  // Copy before the first await: a caller cannot mutate bytes after integrity validation.
  const body = new Uint8Array(input.body);
  if (createHash("sha256").update(body).digest("hex") !== input.sha256) fail("integrity_mismatch");
  const value = parseJson(utf8(body, "invalid_request"), limits, "invalid_request");
  if (!isObject(value) || typeof value.model !== "string" || !value.model.length || typeof value.instructions !== "string") fail("invalid_request");
  if (value.stream !== true || value.store !== false || !Array.isArray(value.tools) || value.tools.length || value.tool_choice !== "none") fail("unsupported_request");
  for (const field of ["previous_response_id", "conversation"]) {
    if (value[field] != null) fail("unsupported_request");
  }
  if (value.background !== undefined && value.background !== false) fail("unsupported_request");
  if (value.reasoning !== undefined && (!isObject(value.reasoning) || typeof value.reasoning.effort !== "string" || !value.reasoning.effort.length)) fail("invalid_request");
  if (!Array.isArray(value.input) || !value.input.length) fail("unsupported_request");
  for (const message of value.input) {
    if (!isObject(message) || message.type !== "message" || !["system", "developer", "user"].includes(String(message.role)) || !Array.isArray(message.content)) fail("unsupported_request");
    for (const content of message.content) {
      if (!isObject(content) || content.type !== "input_text" || typeof content.text !== "string") fail("unsupported_request");
    }
  }
  if (!isObject(value.text) || !isObject(value.text.format)) fail("invalid_request");
  const format = value.text.format;
  if (format.type !== "text" && format.type !== "json_schema") fail("unsupported_request");
  if (format.type === "json_schema") {
    if (typeof format.name !== "string" || !format.name.length || format.schema === undefined ||
      (format.strict !== undefined && typeof format.strict !== "boolean")) fail("invalid_request");
    validateSchema(format.schema, limits);
  }
  return {
    body,
    headers: { session_id: input.sessionId, "x-client-request-id": input.clientRequestId, originator: input.originator },
    format: format.type,
    ...(format.type === "json_schema" ? { schema: format.schema! } : {}),
  };
}

export function authenticationHeaders(authentication: Authentication): Record<string, string> {
  if (!authentication || !headerValue(authentication.accessToken, 32_768) || !headerValue(authentication.accountId)) fail("invalid_authentication");
  return { Authorization: `Bearer ${authentication.accessToken}`, "ChatGPT-Account-ID": authentication.accountId };
}
