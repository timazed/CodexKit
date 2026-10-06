import { createHash } from "node:crypto";
import { fail, type ErrorCode } from "./errors.js";
import { isObject, parseJson, utf8 } from "./json.js";
import { headerValue } from "./request.js";
import type { ExecutionLimits } from "./types.js";
import type { ImageExecutionLimits, PreparedImageRequest } from "./image-types.js";

export function base64Bytes(value: unknown, maximum: number, code: ErrorCode): Buffer {
  if (typeof value !== "string" || !value.length) fail(code);
  if (value.length > Math.ceil(maximum / 3) * 4) fail("limit_exceeded");
  const bytes = Buffer.from(value, "base64");
  if (!bytes.length || bytes.toString("base64") !== value) fail(code);
  if (bytes.length > maximum) fail("limit_exceeded");
  return bytes;
}

export function prepareImageRequest(input: PreparedImageRequest, limits: ImageExecutionLimits, jsonLimits: ExecutionLimits) {
  if (!input || !(input.body instanceof Uint8Array) || !input.body.byteLength) fail("invalid_request");
  if (input.body.byteLength > limits.maxRequestBytes) fail("limit_exceeded");
  if (input.action !== "generate" && input.action !== "edit") fail("unsupported_request");
  if (typeof input.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(input.sha256) ||
      ![input.clientRequestId, input.imageTurnId, input.originator].every(value => headerValue(value))) fail("invalid_request");
  const body = new Uint8Array(input.body);
  if (createHash("sha256").update(body).digest("hex") !== input.sha256) fail("integrity_mismatch");
  const value = parseJson(utf8(body, "invalid_request"), jsonLimits, "invalid_request");
  if (!isObject(value) || typeof value.prompt !== "string" || !value.prompt.trim()) fail("invalid_request");
  if (Object.keys(value).some(key => !["prompt", "background", "model", "quality", "size", "images"].includes(key)) ||
      value.model !== "gpt-image-2" || value.quality !== "auto" || value.size !== "auto" ||
      (value.background !== "transparent" && value.background !== "opaque")) fail("unsupported_request");
  if (input.action === "generate") {
    if (value.images !== undefined) fail("unsupported_request");
  } else {
    if (!Array.isArray(value.images) || !value.images.length || value.images.length > 5) fail("unsupported_request");
    let remaining = limits.maxImageBytes;
    for (const reference of value.images) {
      if (!isObject(reference) || Object.keys(reference).some(key => key !== "image_url") ||
          typeof reference.image_url !== "string") fail("unsupported_request");
      const prefix = /^data:image\/(?:png|jpeg|webp);base64,/.exec(reference.image_url)?.[0];
      if (!prefix) fail("unsupported_request");
      remaining -= base64Bytes(reference.image_url.slice(prefix.length), remaining, "invalid_request").length;
    }
  }
  return { body, action: input.action, clientRequestId: input.clientRequestId, headers: {
    originator: input.originator, "x-client-request-id": input.clientRequestId, "x-codex-image-turn-id": input.imageTurnId,
  } };
}
