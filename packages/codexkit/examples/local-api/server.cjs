const { createServer } = require('node:http');
const { CodexKitBridgeClient, CodexKitCloudError } = require('@timazed/codexkit');
const { fixtureFetch } = require('./fixture.cjs');

const VERSION = 1;
const MODE = Object.freeze({ fixture: 'fixture', live: 'live' });
const ERROR = Object.freeze({
  invalid: 'invalid_envelope', version: 'unsupported_version', large: 'request_too_large',
  media: 'unsupported_media_type', forbidden: 'local_clients_only', missing: 'not_found',
  busy: 'server_busy', timeout: 'execution_timeout', internal: 'internal_error',
});

class APIError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}

function json(response, status, value) {
  if (response.destroyed || response.writableEnded) return;
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', ...(status >= 400 ? { Connection: 'close' } : {}) });
  response.end(JSON.stringify({ version: VERSION, ...value }));
}

function decodeEnvelope(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new APIError(400, ERROR.invalid);
  if (value.version !== VERSION) throw new APIError(400, ERROR.version);
  const prepared = value.preparedRequest;
  if (!prepared || typeof prepared !== 'object' || Array.isArray(prepared) ||
      Object.keys(value).some(key => !['version', 'preparedRequest', 'authentication'].includes(key)) ||
      Object.keys(prepared).some(key => !['bodyBase64', 'sha256', 'sessionId', 'clientRequestId', 'originator'].includes(key)) ||
      typeof prepared.bodyBase64 !== 'string' || !prepared.bodyBase64.length) {
    throw new APIError(400, ERROR.invalid);
  }
  const body = Buffer.from(prepared.bodyBase64, 'base64');
  if (body.toString('base64') !== prepared.bodyBase64) throw new APIError(400, ERROR.invalid);
  return { preparedRequest: { body, sha256: prepared.sha256, sessionId: prepared.sessionId,
    clientRequestId: prepared.clientRequestId, originator: prepared.originator },
    authentication: value.authentication };
}

async function readEnvelope(request, maximumBytes) {
  if (request.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json') {
    throw new APIError(415, ERROR.media);
  }
  if (Number(request.headers['content-length']) > maximumBytes) throw new APIError(413, ERROR.large);
  const chunks = [];
  let length = 0;
  // Preserve the socket on a size-limit failure long enough to return HTTP 413.
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    length += chunk.length;
    if (length > maximumBytes) throw new APIError(413, ERROR.large);
    chunks.push(chunk);
  }
  try { return decodeEnvelope(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
  catch (error) {
    if (error instanceof APIError) throw error;
    throw new APIError(400, ERROR.invalid);
  }
}

/** Local development host only. Credentials/results are never persisted or logged. */
function createLocalAPIServer({ mode = MODE.fixture, fetch: fetcher, maximumBytes = 6 * 1024 * 1024,
  maximumConcurrent = 4, executionTimeoutMs = 90_000 } = {}) {
  if (!Object.values(MODE).includes(mode)) throw new Error('Expected fixture or live mode.');
  for (const value of [maximumBytes, maximumConcurrent, executionTimeoutMs]) {
    if (!Number.isSafeInteger(value) || value <= 0) throw new Error('Expected positive API limits.');
  }
  const client = new CodexKitBridgeClient({
    ...(fetcher ? { fetch: fetcher } : mode === MODE.fixture ? { fetch: fixtureFetch } : {}),
  });
  let active = 0;
  const server = createServer(async (request, response) => {
    let controller;
    let timer;
    let timedOut = false;
    let started = false;
    const disconnect = () => { if (!response.writableEnded) controller?.abort(); };
    try {
      if (request.headers.origin || !/^(127\.0\.0\.1|localhost)(:\d+)?$/.test(request.headers.host ?? '')) {
        throw new APIError(403, ERROR.forbidden);
      }
      if (request.method === 'GET' && request.url === '/health') {
        json(response, 200, { status: 'ok', mode });
        return;
      }
      if (request.method !== 'POST' || request.url !== '/v1/execute') throw new APIError(404, ERROR.missing);
      if (active >= maximumConcurrent) throw new APIError(429, ERROR.busy);
      active++;
      started = true;
      controller = new AbortController();
      request.once('aborted', disconnect);
      response.once('close', disconnect);
      const input = await readEnvelope(request, maximumBytes);
      timer = setTimeout(() => { timedOut = true; controller.abort(); }, executionTimeoutMs);
      const result = await client.execute({ ...input, signal: controller.signal });
      json(response, 200, { mode, result });
    } catch (error) {
      if (timedOut) {
        json(response, 504, { error: { code: ERROR.timeout, outcome: 'unknown' } });
      } else if (error instanceof CodexKitCloudError) {
        json(response, error.details.outcome === 'not_started' ? 400 : 502, { error: error.toJSON() });
      } else if (error instanceof APIError) {
        json(response, error.status, { error: { code: error.code, outcome: 'not_started' } });
      } else {
        json(response, 500, { error: { code: ERROR.internal, outcome: 'unknown' } });
      }
    } finally {
      clearTimeout(timer);
      request.removeListener('aborted', disconnect);
      response.removeListener('close', disconnect);
      if (started) active--;
    }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  return server;
}

module.exports = { createLocalAPIServer, decodeEnvelope, MODE, ERROR };
