import { CodexKitCloudError, fail } from "./errors.js";
import type { ExecutionLimits } from "./types.js";

export interface ServerEvent { readonly event?: string; readonly data: string }

export function checkAbort(signal?: AbortSignal): void {
  if (signal?.aborted) fail("cancelled");
}

/** Also handles custom transports and callbacks which are slow to observe cancellation. */
export async function abortable<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  let listener: (() => void) | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        listener = () => reject(new CodexKitCloudError("cancelled"));
        signal.addEventListener("abort", listener, { once: true });
        if (signal.aborted) listener();
      }),
    ]);
  } finally {
    if (listener) signal.removeEventListener("abort", listener);
  }
}

class Framer {
  private fragments: string[] = [];
  private lineBytes = 0;
  private eventBytes = 0;
  private data: string[] = [];
  private event: string | undefined;
  private afterCR = false;
  constructor(private readonly maximum: number) {}

  *feed(text: string): Generator<ServerEvent> {
    let start = 0;
    for (let i = 0; i < text.length; i++) {
      const char = text[i];
      if (this.afterCR) {
        this.afterCR = false;
        if (char === "\n") { start = i + 1; continue; }
      }
      if (char !== "\r" && char !== "\n") continue;
      this.append(text.slice(start, i));
      const event = this.line();
      this.afterCR = char === "\r";
      start = i + 1;
      if (event) yield event;
    }
    this.append(text.slice(start));
  }

  private append(fragment: string): void {
    if (!fragment) return;
    this.lineBytes += Buffer.byteLength(fragment);
    if (this.lineBytes + this.eventBytes > this.maximum) fail("limit_exceeded");
    const last = this.fragments.length - 1;
    // Bound fragment bookkeeping even when the transport emits one byte per chunk.
    if (last >= 0 && this.fragments[last]!.length < 4096) this.fragments[last] += fragment;
    else this.fragments.push(fragment);
  }

  private line(): ServerEvent | undefined {
    const line = this.fragments.join("");
    this.eventBytes += this.lineBytes + 1;
    this.fragments = [];
    this.lineBytes = 0;
    if (this.eventBytes > this.maximum) fail("limit_exceeded");
    if (!line) {
      const event = this.data.length ? { data: this.data.join("\n"), ...(this.event ? { event: this.event } : {}) } : undefined;
      this.data = [];
      this.event = undefined;
      this.eventBytes = 0;
      return event;
    }
    if (line.startsWith(":")) return;
    const colon = line.indexOf(":");
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "data") this.data.push(value);
    if (field === "event") this.event = value;
    // id/retry fields are not permission to reconnect or repeat a request.
  }
}

export async function* readEvents(
  body: ReadableStream<Uint8Array>, limits: ExecutionLimits, signal: AbortSignal,
): AsyncGenerator<ServerEvent> {
  const reader = body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const framer = new Framer(limits.maxEventBytes);
  let bytes = 0;
  try {
    while (true) {
      checkAbort(signal);
      const next = await abortable(reader.read(), signal);
      if (next.done) {
        let tail: string;
        try { tail = decoder.decode(); } catch { return fail("invalid_response"); }
        yield* framer.feed(tail);
        // SSE dispatch requires a blank line; an unterminated frame is not a receipt.
        return;
      }
      bytes += next.value.byteLength;
      if (bytes > limits.maxStreamBytes) fail("limit_exceeded");
      let text: string;
      try { text = decoder.decode(next.value, { stream: true }); } catch { return fail("invalid_response"); }
      yield* framer.feed(text);
    }
  } finally {
    // Do not wait for socket EOF (or an uncooperative cancel implementation) after a terminal event.
    void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
