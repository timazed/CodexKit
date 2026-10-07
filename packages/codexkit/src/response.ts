import { CodexKitCloudError, fail, type ErrorDetails, type ProviderOutcome } from "./errors.js";
import { isObject, parseJson } from "./json.js";
import type { ValidatedRequest } from "./request.js";
import { validateValue } from "./schema.js";
import type { ServerEvent } from "./stream.js";
import type { ExecutionLimits, ExecutionResult, JsonObject, OutputMessage, ProgressEvent } from "./types.js";

function identifier(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= 1024 && /^[\x21-\x7e]+$/.test(value) ? value : undefined;
}

export function providerFailure(error: unknown): Pick<ErrorDetails, "providerCode"> {
  if (!isObject(error)) return {};
  return typeof error.code === "string" && /^[a-z][a-z0-9_]{0,99}$/.test(error.code) ? { providerCode: error.code } : {};
}

/** Response state is per call; deltas never become successful output on their own. */
export class ResponseConsumer {
  private responseId: string | undefined;
  private sequence: number | undefined;
  private previousData: string | undefined;
  private readonly completedItems = new Map<number, JsonObject>();
  private completedItemBytes = 0;
  private outcome: ProviderOutcome = "unknown";

  constructor(private readonly request: ValidatedRequest, private readonly limits: ExecutionLimits) {}

  get details(): ErrorDetails {
    return { outcome: this.outcome, ...(this.responseId ? { responseId: this.responseId } : {}) };
  }

  consume(event: ServerEvent): { result?: ExecutionResult; progress?: ProgressEvent } {
    if (event.data === "[DONE]") fail("stream_interrupted");
    const value = parseJson(event.data, this.limits, "invalid_response");
    if (!isObject(value) || typeof value.type !== "string") fail("invalid_response");
    if (event.event && event.event !== "message" && event.event !== value.type) fail("invalid_response");
    if (value.sequence_number !== undefined) {
      const sequence = value.sequence_number;
      if (typeof sequence !== "number" || !Number.isSafeInteger(sequence) || sequence < 0) fail("invalid_response");
      if (this.sequence !== undefined && sequence <= this.sequence) {
        if (sequence === this.sequence && event.data === this.previousData) return {};
        fail("invalid_response");
      }
      this.sequence = sequence;
      this.previousData = event.data;
    }
    const response = isObject(value.response) ? value.response : undefined;
    if (response?.id !== undefined) {
      const id = identifier(response.id);
      if (!id || (this.responseId && this.responseId !== id)) fail("invalid_response");
      this.responseId = id;
    }
    if (value.type === "response.failed" || value.type === "error") {
      this.outcome = "failed";
      throw new CodexKitCloudError("provider_failed", providerFailure(response?.error ?? value.error ?? value));
    }
    if (value.type === "response.incomplete") {
      this.outcome = "incomplete";
      throw new CodexKitCloudError("response_incomplete", this.incompleteDetails(response));
    }
    if (value.type === "response.created") {
      if (!this.responseId) fail("invalid_response");
      return { progress: { type: value.type, responseId: this.responseId } };
    }
    if (value.type === "response.output_item.added" || value.type === "response.output_item.done") {
      if (!isObject(value.item)) fail("invalid_response");
      this.assertItemType(value.item);
      if (value.type === "response.output_item.done") {
        const index = value.output_index;
        if (typeof index !== "number" || !Number.isSafeInteger(index) || index < 0) fail("invalid_response");
        const previous = this.completedItems.get(index);
        if (previous && JSON.stringify(previous) !== JSON.stringify(value.item)) fail("invalid_response");
        if (!previous) {
          this.completedItemBytes += Buffer.byteLength(JSON.stringify(value.item));
          if (this.completedItems.size >= this.limits.maxOutputItems || this.completedItemBytes > this.limits.maxOutputBytes) fail("limit_exceeded");
          this.completedItems.set(index, value.item);
        }
      }
    }
    if (value.type === "response.output_text.delta" || value.type === "response.reasoning_summary_text.delta") {
      if (typeof value.delta !== "string") fail("invalid_response");
      const itemId = value.item_id === undefined ? undefined : identifier(value.item_id);
      if (value.item_id !== undefined && !itemId) fail("invalid_response");
      const indexName = value.type === "response.output_text.delta" ? "content_index" : "summary_index";
      const index = value[indexName];
      if (index !== undefined && (typeof index !== "number" || !Number.isSafeInteger(index) || index < 0)) fail("invalid_response");
      return { progress: {
        type: value.type, delta: value.delta,
        ...(itemId ? { itemId } : {}),
        ...(index !== undefined ? value.type === "response.output_text.delta" ? { contentIndex: index as number } : { summaryIndex: index as number } : {}),
      } };
    }
    if (value.type === "response.completed") {
      if (!response || !this.responseId) fail("invalid_response");
      if (response.status === "incomplete" || response.incomplete_details != null) {
        this.outcome = "incomplete";
        throw new CodexKitCloudError("response_incomplete", this.incompleteDetails(response));
      }
      if (response.error != null || (response.status !== undefined && response.status !== "completed")) {
        this.outcome = response.status === "failed" ? "failed" : "unknown";
        throw new CodexKitCloudError("provider_failed", providerFailure(response.error));
      }
      this.outcome = "completed";
      return { result: this.finish(response, event.data) };
    }
    if (value.type.includes("_call") || value.type.startsWith("response.mcp_")) fail("unsupported_output");
    // Unknown informational events are forward-compatible; never treated as completion.
    return {};
  }

  private assertItemType(item: JsonObject): void {
    if (item.type !== "message" && item.type !== "reasoning") fail("unsupported_output");
  }

  private incompleteDetails(response?: JsonObject): ErrorDetails {
    const reason = isObject(response?.incomplete_details) ? response.incomplete_details.reason : undefined;
    return typeof reason === "string" && /^[a-z][a-z0-9_]{0,99}$/.test(reason) ? { incompleteReason: reason } : {};
  }

  private finish(response: JsonObject, data: string): ExecutionResult {
    let output = response.output;
    // Codex may send complete output-item records and an empty terminal snapshot.
    // Only those complete indexed items can supply output; deltas never can.
    if (output === undefined || (Array.isArray(output) && output.length === 0 && this.completedItems.size > 0)) {
      const entries = [...this.completedItems.entries()].sort((a, b) => a[0] - b[0]);
      if (entries.some(([index], position) => index !== position)) fail("invalid_response");
      output = entries.map(([, item]) => item);
    }
    if (!Array.isArray(output)) fail("invalid_response");
    if (output.length > this.limits.maxOutputItems || Buffer.byteLength(JSON.stringify(output)) > this.limits.maxOutputBytes) fail("limit_exceeded");
    const messages: OutputMessage[] = [];
    const items: JsonObject[] = [];
    const ids = new Set<string>();
    for (const item of output) {
      if (!isObject(item)) fail("invalid_response");
      this.assertItemType(item);
      items.push(item);
      if (item.status !== undefined && item.status !== "completed") fail("invalid_response");
      const id = item.id === undefined ? undefined : identifier(item.id);
      if (item.id !== undefined && (!id || ids.has(id))) fail("invalid_response");
      if (id) ids.add(id);
      if (item.type === "reasoning") continue;
      if (item.role !== "assistant" || !Array.isArray(item.content)) fail("invalid_response");
      if (item.phase != null && item.phase !== "commentary" && item.phase !== "final_answer") fail("unsupported_output");
      const parts: string[] = [];
      for (const content of item.content) {
        if (!isObject(content)) fail("invalid_response");
        if (content.type === "refusal") fail("response_refused");
        if (content.type !== "output_text") fail("unsupported_output");
        if (typeof content.text !== "string") fail("invalid_response");
        parts.push(content.text);
      }
      if (!parts.length) fail("invalid_response");
      messages.push(Object.freeze({ text: parts.join(""), ...(id ? { id } : {}), ...(item.phase ? { phase: item.phase as "commentary" | "final_answer" } : {}) }));
    }
    const finals = messages.filter(message => message.phase === "final_answer");
    const selected = finals.length ? finals : messages.filter(message => message.phase === undefined);
    if (!selected.length) fail("invalid_response");
    const outputText = selected.map(message => message.text).join("");
    if (Buffer.byteLength(outputText) > this.limits.maxOutputBytes) fail("limit_exceeded");
    if (this.request.schema !== undefined) {
      validateValue(parseJson(outputText, this.limits, "invalid_output"), this.request.schema, this.limits);
    }
    if (response.usage != null && !isObject(response.usage)) fail("invalid_response");
    return Object.freeze({
      status: "completed", responseId: this.responseId!, format: this.request.format,
      outputText, messages: Object.freeze(messages), completedEvent: data, output: Object.freeze(items),
      ...(isObject(response.usage) ? { usage: response.usage } : {}),
    });
  }
}
