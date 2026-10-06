import { fail, type ErrorCode } from "./errors.js";
import type { ExecutionLimits, JsonObject, JsonValue } from "./types.js";

export function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function utf8(bytes: Uint8Array, code: ErrorCode): string {
  try { return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes); }
  catch { return fail(code); }
}

/** Strict, bounded JSON parsing, including duplicate keys and Unicode scalar validity. */
export function parseJson(text: string, limits: ExecutionLimits, code: ErrorCode): JsonValue {
  let at = 0;
  let remaining = limits.maxJsonNodes;
  const whitespace = (): void => { while (/[\t\n\r ]/.test(text[at] ?? "x")) at++; };
  const take = (character: string): boolean => {
    whitespace();
    if (text[at] !== character) return false;
    at++;
    return true;
  };
  const string = (): string => {
    whitespace();
    const start = at;
    if (text[at++] !== '"') fail(code);
    while (at < text.length) {
      const character = text[at++];
      if (character === "\\") { at++; continue; }
      if (character !== '"') continue;
      let result: string;
      try { result = JSON.parse(text.slice(start, at)) as string; }
      catch { return fail(code); }
      for (let i = 0; i < result.length; i++) {
        const unit = result.charCodeAt(i);
        if (unit >= 0xd800 && unit <= 0xdbff) {
          const next = result.charCodeAt(++i);
          if (!(next >= 0xdc00 && next <= 0xdfff)) fail(code);
        } else if (unit >= 0xdc00 && unit <= 0xdfff) fail(code);
      }
      return result;
    }
    return fail(code);
  };
  const value = (depth: number): JsonValue => {
    if (depth > limits.maxJsonDepth || --remaining < 0) fail("limit_exceeded");
    whitespace();
    if (text[at] === '"') return string();
    if (take("{")) {
      const object: JsonObject = Object.create(null) as JsonObject;
      if (take("}")) return object;
      do {
        const key = string();
        if (Object.hasOwn(object, key) || !take(":")) fail(code);
        object[key] = value(depth + 1);
        if (take("}")) return object;
      } while (take(","));
      return fail(code);
    }
    if (take("[")) {
      const array: JsonValue[] = [];
      if (take("]")) return array;
      do {
        array.push(value(depth + 1));
        if (take("]")) return array;
      } while (take(","));
      return fail(code);
    }
    const start = at;
    while (at < text.length && !/[\t\n\r ,\]}]/.test(text[at]!)) at++;
    const token = text.slice(start, at);
    if (token === "true") return true;
    if (token === "false") return false;
    if (token === "null") return null;
    if (!/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(token)) fail(code);
    const number = Number(token);
    if (!Number.isFinite(number)) fail(code);
    return number;
  };
  const result = value(0);
  whitespace();
  if (at !== text.length) fail(code);
  return result;
}
