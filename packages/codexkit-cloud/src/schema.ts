import { fail } from "./errors.js";
import { isObject } from "./json.js";
import type { ExecutionLimits, JsonValue } from "./types.js";

// Mirrors CodexKit's JSONSchemaVocabulary / AgentJSONSchemaValidator subset.
// Unknown assertions fail closed; no remote references, coercion, defaults, or repair.
const keywords = new Set([
  "$schema", "$id", "$comment", "title", "description", "default", "examples",
  "deprecated", "readOnly", "writeOnly", "type", "properties", "required",
  "additionalProperties", "items", "enum", "const", "anyOf", "oneOf", "allOf",
  "not", "$defs", "definitions", "$ref", "minimum", "maximum", "exclusiveMinimum",
  "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "minItems", "maxItems",
  "uniqueItems", "minProperties", "maxProperties",
]);
const types = new Set(["string", "integer", "number", "boolean", "array", "object", "null"]);
const compositions = ["anyOf", "oneOf", "allOf"] as const;
const bounds = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"];
const counts = ["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"];

function budget(limits: ExecutionLimits): (depth: number) => void {
  let left = limits.maxValidationSteps;
  return depth => { if (depth > limits.maxJsonDepth || --left < 0) fail("limit_exceeded"); };
}

function resolve(reference: JsonValue, root: JsonValue): JsonValue {
  if (reference === "#") return root;
  if (typeof reference !== "string" || !reference.startsWith("#/")) fail("unsupported_schema");
  let node = root;
  for (const part of reference.slice(2).split("/")) {
    if (/~(?![01])/.test(part)) fail("unsupported_schema");
    const key = part.replace(/~1/g, "/").replace(/~0/g, "~");
    if (isObject(node) && Object.hasOwn(node, key)) node = node[key]!;
    else if (Array.isArray(node) && /^(0|[1-9]\d*)$/.test(key) && Number(key) < node.length) node = node[Number(key)]!;
    else fail("unsupported_schema");
  }
  return node;
}

export function validateSchema(root: JsonValue, limits: ExecutionLimits): void {
  const spend = budget(limits);
  const references = new Set<string>();
  function check(schema: JsonValue, depth: number): void {
    spend(depth);
    if (typeof schema === "boolean") return;
    if (!isObject(schema)) fail("unsupported_schema");
    for (const key of Object.keys(schema)) if (!keywords.has(key)) fail("unsupported_schema");
    if (schema.type !== undefined) {
      const entries = Array.isArray(schema.type) ? schema.type : [schema.type];
      if (!entries.length || entries.some(type => typeof type !== "string" || !types.has(type))) fail("unsupported_schema");
    }
    if (schema.$ref !== undefined) {
      const target = resolve(schema.$ref, root);
      const reference = schema.$ref as string;
      if (!references.has(reference)) {
        references.add(reference);
        check(target, depth + 1);
      }
    }
    for (const key of ["properties", "$defs", "definitions"]) {
      const children = schema[key];
      if (children === undefined) continue;
      if (!isObject(children)) fail("unsupported_schema");
      for (const child of Object.values(children)) check(child, depth + 1);
    }
    for (const key of ["items", "additionalProperties", "not"]) {
      if (schema[key] !== undefined) check(schema[key], depth + 1);
    }
    for (const key of compositions) {
      const children = schema[key];
      if (children === undefined) continue;
      if (!Array.isArray(children) || !children.length) fail("unsupported_schema");
      for (const child of children) check(child, depth + 1);
    }
    if (schema.required !== undefined && (!Array.isArray(schema.required) ||
      schema.required.some(key => typeof key !== "string") || new Set(schema.required).size !== schema.required.length)) fail("unsupported_schema");
    if (schema.enum !== undefined && (!Array.isArray(schema.enum) || !schema.enum.length)) fail("unsupported_schema");
    for (const key of counts) {
      const value = schema[key];
      if (value !== undefined && (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0)) fail("unsupported_schema");
    }
    for (const key of bounds) {
      const value = schema[key];
      if (value !== undefined && (typeof value !== "number" || !Number.isFinite(value) || (key === "multipleOf" && value <= 0))) fail("unsupported_schema");
    }
    if (schema.uniqueItems !== undefined && typeof schema.uniqueItems !== "boolean") fail("unsupported_schema");
  }
  check(root, 0);
}

export function validateValue(value: JsonValue, root: JsonValue, limits: ExecutionLimits): void {
  const spend = budget(limits);
  function equal(a: JsonValue, b: JsonValue, depth: number): boolean {
    spend(depth);
    if (a === b) return true;
    if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((entry, i) => equal(entry, b[i]!, depth + 1));
    if (isObject(a) && isObject(b)) {
      const keys = Object.keys(a);
      return keys.length === Object.keys(b).length && keys.every(key => Object.hasOwn(b, key) && equal(a[key]!, b[key]!, depth + 1));
    }
    return false;
  }
  function matchesType(value: JsonValue, type: JsonValue): boolean {
    if (type === "null") return value === null;
    if (type === "array") return Array.isArray(value);
    if (type === "object") return isObject(value);
    if (type === "integer") return typeof value === "number" && Number.isInteger(value);
    return typeof value === type;
  }
  const sizeMatches = (count: number, min: JsonValue | undefined, max: JsonValue | undefined): boolean =>
    (min === undefined || count >= (min as number)) && (max === undefined || count <= (max as number));
  function matches(value: JsonValue, schema: JsonValue, depth: number): boolean {
    spend(depth);
    if (typeof schema === "boolean") return schema;
    if (!isObject(schema)) fail("unsupported_schema");
    if (schema.$ref !== undefined && !matches(value, resolve(schema.$ref, root), depth + 1)) return false;
    if (schema.type !== undefined && !(Array.isArray(schema.type) ? schema.type : [schema.type]).some(type => matchesType(value, type))) return false;
    if (Array.isArray(schema.enum) && !schema.enum.some(entry => equal(value, entry, depth + 1))) return false;
    if (schema.const !== undefined && !equal(value, schema.const, depth + 1)) return false;
    for (const key of compositions) {
      const children = schema[key];
      if (!Array.isArray(children)) continue;
      let count = 0;
      for (const child of children) if (matches(value, child, depth + 1)) count++;
      if ((key === "anyOf" && count === 0) || (key === "oneOf" && count !== 1) || (key === "allOf" && count !== children.length)) return false;
    }
    if (schema.not !== undefined && matches(value, schema.not, depth + 1)) return false;
    if (isObject(value)) {
      const keys = Object.keys(value);
      if (!sizeMatches(keys.length, schema.minProperties, schema.maxProperties)) return false;
      if (Array.isArray(schema.required) && schema.required.some(key => !Object.hasOwn(value, key as string))) return false;
      const declared = isObject(schema.properties) ? schema.properties : {};
      for (const key of keys) {
        const child = Object.hasOwn(declared, key) ? declared[key]! : schema.additionalProperties ?? true;
        if (!matches(value[key]!, child, depth + 1)) return false;
      }
    } else if (Array.isArray(value)) {
      if (!sizeMatches(value.length, schema.minItems, schema.maxItems)) return false;
      for (let i = 0; i < value.length; i++) {
        if (!matches(value[i]!, schema.items ?? true, depth + 1)) return false;
        if (schema.uniqueItems === true) {
          for (let j = 0; j < i; j++) if (equal(value[i]!, value[j]!, depth + 1)) return false;
        }
      }
    } else if (typeof value === "string") {
      // Unicode scalars, matching Swift unicodeScalars.count, not UTF-16 code units.
      if (!sizeMatches(Array.from(value).length, schema.minLength, schema.maxLength)) return false;
    } else if (typeof value === "number") {
      if (typeof schema.minimum === "number" && value < schema.minimum) return false;
      if (typeof schema.maximum === "number" && value > schema.maximum) return false;
      if (typeof schema.exclusiveMinimum === "number" && value <= schema.exclusiveMinimum) return false;
      if (typeof schema.exclusiveMaximum === "number" && value >= schema.exclusiveMaximum) return false;
      if (typeof schema.multipleOf === "number") {
        const quotient = value / schema.multipleOf;
        if (!Number.isFinite(quotient) || Math.abs(quotient - Math.round(quotient)) > Math.max(1, Math.abs(quotient)) * 1e-12) return false;
      }
    }
    return true;
  }
  if (!matches(value, root, 0)) fail("schema_mismatch");
}
