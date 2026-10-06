import { fail } from "./errors.js";
import type { ExecutionLimits } from "./types.js";

export const DEFAULT_LIMITS: Readonly<ExecutionLimits> = Object.freeze({
  maxRequestBytes: 4 * 1024 * 1024,
  maxEventBytes: 16 * 1024 * 1024,
  maxStreamBytes: 128 * 1024 * 1024,
  maxOutputBytes: 16 * 1024 * 1024,
  maxOutputItems: 1024,
  maxJsonDepth: 64,
  maxJsonNodes: 100_000,
  maxValidationSteps: 100_000,
});

export function resolveLimits(overrides: Partial<ExecutionLimits> = {}): ExecutionLimits {
  const limits = { ...DEFAULT_LIMITS };
  for (const [key, value] of Object.entries(overrides)) {
    if (!Object.hasOwn(DEFAULT_LIMITS, key) || !Number.isSafeInteger(value) || value <= 0) fail("invalid_configuration");
    limits[key as keyof ExecutionLimits] = value;
  }
  // Keep recursive parsers within the JavaScript stack's safe range.
  if (limits.maxJsonDepth > 128) fail("invalid_configuration");
  return Object.freeze(limits);
}
