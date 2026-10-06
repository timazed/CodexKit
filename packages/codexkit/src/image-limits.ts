import { fail } from "./errors.js";
import type { ImageExecutionLimits } from "./image-types.js";

const imageBytes = 32 * 1024 * 1024;
const jsonBytes = Math.ceil(imageBytes / 3) * 4 + 1024 * 1024;
export const DEFAULT_IMAGE_LIMITS: Readonly<ImageExecutionLimits> = Object.freeze({
  maxRequestBytes: jsonBytes, maxResponseBytes: jsonBytes, maxImageBytes: imageBytes,
  maxOutputImages: 32, maxPixels: 32_000_000, maxInflatedBytes: 128 * 1024 * 1024,
});

export function resolveImageLimits(overrides: Partial<ImageExecutionLimits> = {}): ImageExecutionLimits {
  const limits = { ...DEFAULT_IMAGE_LIMITS };
  for (const [key, value] of Object.entries(overrides)) {
    if (!Object.hasOwn(limits, key) || !Number.isSafeInteger(value) || value <= 0) fail("invalid_configuration");
    limits[key as keyof ImageExecutionLimits] = value;
  }
  // The Swift image contract bounds references and decoded output to 32 MiB / 32 images.
  if (limits.maxImageBytes > imageBytes || limits.maxOutputImages > 32) fail("invalid_configuration");
  return Object.freeze(limits);
}
