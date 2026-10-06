const { test: nodeTest } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { createLocalAPIServer } = require('../examples/local-api/server.cjs');
const { FIXTURE_MESSAGE } = require('../examples/local-api/fixture.cjs');
const { prepared, requestBody, authentication, complete, response: providerResponse } = require('./helpers.cjs');
const test = (name, run) => nodeTest(name, { timeout: 5000 }, run);

function envelope(request = prepared()) {
  const { body, ...metadata } = request;
  return { version: 1, preparedRequest: { ...metadata, bodyBase64: Buffer.from(body).toString('base64') }, authentication };
}

async function server(t, options) {
  const instance = createLocalAPIServer(options);
  instance.listen(0, '127.0.0.1');
  await once(instance, 'listening');
  t.after(() => new Promise(resolve => { instance.close(resolve); instance.closeAllConnections(); }));
  return `http://127.0.0.1:${instance.address().port}`;
}

function send(base, body, { path = '/v1/execute', headers = {}, method = 'POST' } = {}) {
  const bytes = typeof body === 'string' ? body : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const request = http.request(base + path, { method, headers: { 'content-type': 'application/json', ...headers } }, response => {
      let data = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { data += chunk; });
      response.on('end', () => resolve({ status: response.statusCode, value: JSON.parse(data) }));
    });
    request.on('error', reject);
    request.end(bytes);
  });
}

test('local API serves health and executes the bridge with a synthetic provider', async t => {
  const base = await server(t);
  assert.deepEqual(await send(base, undefined, { method: 'GET', path: '/health' }),
    { status: 200, value: { version: 1, status: 'ok', mode: 'fixture' } });
  const reply = await send(base, envelope());
  assert.equal(reply.status, 200);
  assert.equal(reply.value.result.outputText, FIXTURE_MESSAGE);
  assert.equal(reply.value.mode, 'fixture');
});

test('local API forwards authoritative bytes and per-request authentication exactly once', async t => {
  const calls = [];
  const base = await server(t, { mode: 'live', fetch: async (url, init) => {
    calls.push({ url, ...init });
    return providerResponse([complete()]);
  } });
  const input = prepared();
  const reply = await send(base, envelope(input));
  assert.equal(reply.status, 200);
  assert.equal(calls.length, 1);
  assert.deepEqual(Buffer.from(calls[0].body), input.body);
  assert.equal(calls[0].headers.Authorization, `Bearer ${authentication.accessToken}`);
  assert.equal(calls[0].headers['ChatGPT-Account-ID'], authentication.accountId);
  assert.equal(calls[0].headers['x-client-request-id'], input.clientRequestId);
});

test('local API rejects malformed envelopes, tools, and digest mismatches before provider access', async t => {
  let calls = 0;
  const base = await server(t, { fetch: async () => { calls++; return providerResponse([complete()]); } });
  for (const [body, code] of [
    ['{', 'invalid_envelope'], [{ ...envelope(), version: 2 }, 'unsupported_version'],
    [{ ...envelope(), endpoint: 'https://untrusted.example/responses' }, 'invalid_envelope'],
    [envelope({ ...prepared(), sha256: '0'.repeat(64) }), 'integrity_mismatch'],
    [envelope(prepared(requestBody({ tools: [{ type: 'web_search' }] }))), 'unsupported_request'],
    [{ ...envelope(), preparedRequest: { ...envelope().preparedRequest, bodyBase64: '!' } }, 'invalid_envelope'],
  ]) {
    const reply = await send(base, body);
    assert.equal(reply.status, 400);
    assert.equal(reply.value.error.code, code);
    assert.equal(reply.value.error.outcome, 'not_started');
  }
  assert.equal(calls, 0);
});

test('local API rejects browser origins, foreign hosts, wrong media types, and oversized bodies', async t => {
  const base = await server(t, { maximumBytes: 100 });
  for (const [headers, status] of [
    [{ origin: 'https://example.com' }, 403], [{ host: 'example.com' }, 403],
    [{ 'content-type': 'text/plain' }, 415], [{ 'content-length': '101' }, 413],
  ]) assert.equal((await send(base, 'x'.repeat(101), { headers })).status, status);
  // No content-length hint: enforce the same limit while reading chunked input.
  assert.equal((await send(base, 'x'.repeat(101))).status, 413);
});

test('local API returns a sanitized provider error without retrying', async t => {
  let calls = 0;
  const base = await server(t, { fetch: async () => {
    calls++;
    return new Response(JSON.stringify({ error: { message: authentication.accessToken } }),
      { status: 401, headers: { 'content-type': 'application/json' } });
  } });
  const reply = await send(base, envelope());
  assert.equal(reply.status, 502);
  assert.equal(reply.value.error.code, 'authentication_failed');
  assert.ok(!JSON.stringify(reply).includes(authentication.accessToken));
  assert.equal(calls, 1);
});

test('local API bounds execution time and aborts the provider', async t => {
  let aborted = false;
  const base = await server(t, { executionTimeoutMs: 20, fetch: (_url, init) => {
    init.signal.addEventListener('abort', () => { aborted = true; });
    return new Promise(() => {});
  } });
  const reply = await send(base, envelope());
  assert.equal(reply.status, 504);
  assert.equal(reply.value.error.outcome, 'unknown');
  assert.equal(aborted, true);
});

test('local API aborts execution when the caller disconnects and rejects excess work', async t => {
  let signal;
  let entered;
  let stopped;
  const ready = new Promise(resolve => { entered = resolve; });
  const cancelled = new Promise(resolve => { stopped = resolve; });
  const base = await server(t, { maximumConcurrent: 1, fetch: (_url, init) => {
    signal = init.signal;
    signal.addEventListener('abort', stopped);
    entered();
    return new Promise(() => {});
  } });
  const request = http.request(base + '/v1/execute', { method: 'POST', headers: { 'content-type': 'application/json' } });
  request.on('error', () => {});
  request.end(JSON.stringify(envelope()));
  await ready;
  assert.equal((await send(base, envelope())).status, 429);
  request.destroy();
  await cancelled;
  assert.equal(signal.aborted, true);
});
