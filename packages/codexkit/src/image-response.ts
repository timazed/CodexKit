import { CodexKitCloudError, fail, type ErrorDetails } from "./errors.js";
import { base64Bytes } from "./image-request.js";
import { isObject, parseJson, utf8 } from "./json.js";
import { inspectPNG } from "./png.js";
import { providerFailure } from "./response.js";
import { abortable, checkAbort } from "./stream.js";
import type { ExecutionLimits, JsonValue } from "./types.js";
import type { GeneratedImage, ImageExecutionLimits, ImageExecutionResult } from "./image-types.js";

/** Complete HTTP body required. Bounded slabs also limit bookkeeping for one-byte chunks. */
export async function readImageBody(response: Response, maximum: number, signal: AbortSignal): Promise<Buffer> {
  const length = response.headers.get("content-length");
  if (length && /^\d+$/.test(length) && Number(length) > maximum) fail("limit_exceeded");
  if (!response.body) fail("invalid_response");
  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let total = 0, used = 0, empty = 0;
  let block = Buffer.allocUnsafe(Math.min(maximum, 65536));
  try {
    while (total <= maximum) {
      checkAbort(signal);
      const next = await abortable(reader.read(), signal);
      if (next.done) {
        if (used) chunks.push(block.subarray(0, used));
        return Buffer.concat(chunks, total);
      }
      if (!next.value.length) { if (++empty > 1024) fail("invalid_response"); continue; }
      empty = 0;
      total += next.value.length;
      if (total > maximum) fail("limit_exceeded");
      for (let at = 0; at < next.value.length;) {
        const count = Math.min(block.length - used, next.value.length - at);
        block.set(next.value.subarray(at, at + count), used);
        used += count; at += count;
        if (used === block.length) { chunks.push(block); block = Buffer.allocUnsafe(65536); used = 0; }
      }
    }
    return fail("limit_exceeded");
  } finally {
    void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

export function imageIdentifier(value: unknown, secrets: readonly string[]): string | undefined {
  return typeof value === "string" && /^[A-Za-z0-9_.:-]{1,256}$/.test(value) &&
    !secrets.some(secret => secret.length && value.includes(secret)) ? value : undefined;
}

function quota(response: Response, value: JsonValue | undefined): ErrorDetails["imageUsageLimit"] {
  const error = isObject(value) && isObject(value.error) ? value.error : undefined;
  const windows = ["primary", "secondary"];
  if (response.status !== 429 || error?.type !== "usage_limit_reached" ||
      !(response.headers.get("x-codex-active-limit") === "image_gen" ||
        windows.some(window => response.headers.has(`x-image-gen-${window}-used-percent`)))) return;
  const resets: number[] = [];
  if (typeof error.resets_at === "number" && Number.isFinite(error.resets_at) && error.resets_at >= 0) {
    resets.push(error.resets_at);
  } else for (const window of windows) {
    const used = response.headers.get(`x-image-gen-${window}-used-percent`);
    const reset = response.headers.get(`x-image-gen-${window}-reset-at`);
    if (used && reset && Number.isFinite(Number(used)) && Number(used) >= 100 &&
        Number.isFinite(Number(reset)) && Number(reset) >= 0) resets.push(Number(reset));
  }
  return Object.freeze({ limitId: "image_gen", ...(resets.length ? { resetsAt: Math.max(...resets) } : {}) });
}

export async function imageHTTPFailure(response: Response, limits: ExecutionLimits, signal: AbortSignal): Promise<CodexKitCloudError> {
  let value: JsonValue | undefined;
  try {
    if (response.headers.get("content-type")?.toLowerCase().includes("json")) {
      value = parseJson(utf8(await readImageBody(response, 64 * 1024, signal), "invalid_response"), limits, "invalid_response");
    }
  } catch { checkAbort(signal); }
  const imageUsageLimit = quota(response, value);
  const retryAfter = response.headers.get("retry-after");
  const validRetry = retryAfter && retryAfter.length <= 128 && (/^\d+(?:\.\d+)?$/.test(retryAfter) ||
    /^[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(retryAfter));
  return new CodexKitCloudError(imageUsageLimit ? "image_usage_limit_exceeded" :
    response.status === 401 || response.status === 403 ? "authentication_failed" : "http_error", {
      ...providerFailure(isObject(value) ? value.error : undefined), httpStatus: response.status,
      outcome: response.status >= 400 && response.status < 500 ? "failed" : "unknown",
      ...(imageUsageLimit ? { imageUsageLimit } : {}), ...(validRetry ? { retryAfter } : {}),
    });
}

export function decodeImageResponse(bytes: Buffer, limits: ImageExecutionLimits, jsonLimits: ExecutionLimits, secrets: readonly string[]):
  Pick<ImageExecutionResult, "created" | "images" | "background" | "quality"> {
  const value = parseJson(utf8(bytes, "invalid_response"), jsonLimits, "invalid_response");
  if (!isObject(value)) fail("invalid_response");
  if (value.error != null || value.status === "failed") {
    throw new CodexKitCloudError("provider_failed", { ...providerFailure(value.error), outcome: "failed" });
  }
  if (value.status === "incomplete") throw new CodexKitCloudError("response_incomplete", { outcome: "incomplete" });
  if ((value.status != null && value.status !== "completed") || typeof value.created !== "number" ||
      !Number.isFinite(value.created) || value.created < 0 || !Array.isArray(value.data) || !value.data.length) fail("invalid_response");
  if (value.data.length > limits.maxOutputImages) fail("limit_exceeded");
  let remainingBytes = limits.maxImageBytes, remainingPixels = limits.maxPixels;
  const images: GeneratedImage[] = value.data.map(item => {
    if (!isObject(item)) fail("invalid_response");
    const data = base64Bytes(item.b64_json, remainingBytes, "invalid_response");
    remainingBytes -= data.length;
    const pixelSize = inspectPNG(data, { ...limits, maxPixels: remainingPixels });
    remainingPixels -= pixelSize.width * pixelSize.height;
    const generationId = imageIdentifier(item.generation_id, secrets);
    return Object.freeze({ base64: item.b64_json as string, mimeType: "image/png", pixelSize,
      ...(generationId ? { generationId } : {}) });
  });
  const background = value.background;
  const quality = value.quality;
  return { created: value.created, images: Object.freeze(images),
    ...(background === "transparent" || background === "opaque" || background === "auto" ? { background } : {}),
    ...(quality === "auto" || quality === "low" || quality === "medium" || quality === "high" ? { quality } : {}),
  };
}
