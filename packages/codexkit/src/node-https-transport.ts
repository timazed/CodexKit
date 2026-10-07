import { request } from "node:https";
import { Readable } from "node:stream";

/**
 * Optional Node HTTPS transport for CodexKit execution. Waits for headers/body
 * until the client's AbortSignal fires, without fetch's shorter headers timeout.
 * Only supports the byte-backed POST/manual-redirect contract used by this SDK.
 * Never retries, follows redirects, persists credentials or logs payloads.
 */
export const nodeHttpsTransport: typeof globalThis.fetch = async (input, init = {}) => {
  if (!(typeof input === "string" || input instanceof URL) || init.method !== "POST" ||
      init.redirect !== "manual" || !(init.body instanceof Uint8Array) || !init.signal) {
    throw new TypeError("Unsupported CodexKit HTTPS transport input");
  }
  const url = new URL(input);
  if (url.protocol !== "https:" || url.username || url.password || url.hash) throw new TypeError("Invalid CodexKit HTTPS transport URL");
  const body = init.body;
  const signal = init.signal;
  const headers = new Headers(init.headers);
  // Native HTTPS does not decompress responses. Ask for identity encoding.
  headers.set("accept-encoding", "identity");
  return new Promise<Response>((resolve, reject) => {
    const outgoing = request(url, { method: "POST", headers: Object.fromEntries(headers), signal, agent: false }, incoming => {
      incoming.on("error", reject);
      try {
        const responseHeaders = new Headers();
        for (const [name, value] of Object.entries(incoming.headers)) {
          if (value !== undefined) responseHeaders.set(name, Array.isArray(value) ? value.join(", ") : value);
        }
        const status = incoming.statusCode || 502;
        if ([204, 205, 304].includes(status)) {
          incoming.resume(); resolve(new Response(null, { status, headers: responseHeaders }));
        } else resolve(new Response(Readable.toWeb(incoming) as ReadableStream, { status, headers: responseHeaders }));
      } catch (error) { incoming.destroy(); reject(error); }
    });
    outgoing.on("error", reject);
    outgoing.end(body);
  });
};
