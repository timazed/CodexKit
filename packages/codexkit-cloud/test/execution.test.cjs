const { test } = require('node:test');
const assert = require('node:assert/strict');
const { CodexKitBridgeClient, CodexKitCloudError, CODEX_RESPONSES_ENDPOINT } = require('../dist/index.js');
const { prepared, requestBody, authentication, complete, response, harness, errorCode } = require('./helpers.cjs');

test('sends the exact prepared bytes and CodexKit authentication/routing headers once', async () => {
  const input = prepared();
  const { run, calls } = harness();
  const result = await run({ preparedRequest: input });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, CODEX_RESPONSES_ENDPOINT);
  assert.equal(calls[0].method, 'POST');
  assert.equal(calls[0].redirect, 'manual');
  assert.deepEqual(Buffer.from(calls[0].body), input.body);
  const headers = new Headers(calls[0].headers);
  assert.equal(headers.get('authorization'), `Bearer ${authentication.accessToken}`);
  assert.equal(headers.get('chatgpt-account-id'), authentication.accountId);
  assert.equal(headers.get('session_id'), input.sessionId);
  assert.equal(headers.get('x-client-request-id'), input.clientRequestId);
  assert.equal(headers.get('originator'), input.originator);
  assert.equal(headers.get('accept'), 'text/event-stream');
  assert.equal(result.outputText, ' Hello 🙂\n');
  assert.equal(result.responseId, 'resp-fixture');
  assert.equal(result.requestId, 'req-fixture');
  assert.equal(result.usage.input_tokens, 12);
  assert.equal(result.completedEvent, JSON.stringify(complete()));
  assert.equal(calls[0].signal.aborted, true);
});

test('snapshots input bytes and credentials before yielding', async () => {
  const request = prepared();
  const original = Buffer.from(request.body);
  const auth = { ...authentication };
  const { run, calls } = harness(undefined, { fetch: async () => {
    request.body.fill(0); auth.accessToken = 'replacement';
    return response([complete()]);
  } });
  await run({ preparedRequest: request, authentication: auth });
  assert.deepEqual(Buffer.from(calls[0].body), original);
  assert.equal(calls[0].headers.Authorization, `Bearer ${authentication.accessToken}`);
});

test('keeps caller-selected model and reasoning unchanged', async () => {
  const request = prepared(requestBody({ model: 'future-explicit-model', reasoning: { effort: 'ultra', summary: 'auto' } }));
  const { run, calls } = harness();
  await run({ preparedRequest: request });
  assert.deepEqual(Buffer.from(calls[0].body), request.body);
});

for (const [name, mutate, code] of [
  ['digest mismatch', p => { p.sha256 = '0'.repeat(64); }, 'integrity_mismatch'],
  ['missing digest', p => { delete p.sha256; }, 'invalid_request'],
  ['malformed digest', p => { p.sha256 = 'not-a-digest'; }, 'invalid_request'],
  ['missing body', p => { delete p.body; }, 'invalid_request'],
  ['header injection', p => { p.sessionId = 'x\r\nAuthorization: secret'; }, 'invalid_request'],
]) test(`rejects ${name} before fetching`, async () => {
  const { run, calls } = harness(); const p = prepared(); mutate(p);
  await assert.rejects(run({ preparedRequest: p }), errorCode(code, 'not_started'));
  assert.equal(calls.length, 0);
});

for (const change of [
  { tools: [{ type: 'web_search' }] }, { tool_choice: 'auto' }, { stream: false }, { store: true },
  { previous_response_id: 'prior' }, { conversation: 'conversation' }, { background: true },
  { input: [{ type: 'message', role: 'user', content: [{ type: 'input_image', image_url: 'https://invalid.example/image' }] }] },
  { input: [{ type: 'function_call_output', output: 'tool' }] },
  { input: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'history' }] }] },
  { text: { format: { type: 'json_object' } } },
]) test(`rejects unsupported request ${JSON.stringify(change)}`, async () => {
  const { run, calls } = harness();
  await assert.rejects(run({ preparedRequest: prepared(requestBody(change)) }), errorCode('unsupported_request', 'not_started'));
  assert.equal(calls.length, 0);
});

test('strict JSON rejects duplicate keys, invalid UTF-8 and trailing values', async () => {
  for (const bytes of ['{"model":"first","model":"second"}', '{} {}', Buffer.from([0xff]), '{"__proto__":1,"__proto__":2}']) {
    const { run, calls } = harness();
    await assert.rejects(run({ preparedRequest: prepared(bytes) }), errorCode('invalid_request', 'not_started'));
    assert.equal(calls.length, 0);
  }
});

test('preflight has no network side effects', () => {
  const client = new CodexKitBridgeClient();
  assert.equal(client.validatePreparedRequest(prepared()), undefined);
  assert.throws(() => client.validatePreparedRequest({ ...prepared(), sha256: '0'.repeat(64) }), errorCode('integrity_mismatch'));
});

test('preflight uses the same snapshotted client limits as execution', async () => {
  const limits = { maxRequestBytes: 10 };
  const { client, calls } = harness(undefined, { limits });
  limits.maxRequestBytes = 10_000;
  assert.throws(() => client.validatePreparedRequest(prepared()), errorCode('limit_exceeded'));
  await assert.rejects(client.execute({ preparedRequest: prepared(), authentication }), errorCode('limit_exceeded', 'not_started'));
  assert.equal(calls.length, 0);
});

test('request size limits run before transmission', async () => {
  const { run, calls } = harness(undefined, { limits: { maxRequestBytes: 10 } });
  await assert.rejects(run(), errorCode('limit_exceeded', 'not_started'));
  assert.equal(calls.length, 0);
});

test('configuration is trusted-only and cannot override routing or authentication headers', () => {
  for (const endpoint of ['http://example.com/responses', 'https://user:pass@example.com/responses',
    'https://example.com/responses?token=secret', 'https://example.com/responses#fragment', 'https://example.com/other']) {
    assert.throws(() => new CodexKitBridgeClient({ endpoint }), errorCode('invalid_configuration'));
  }
  for (const name of ['Authorization', 'ChatGPT-Account-ID', 'HOST', 'Cookie', 'Content-Length', 'originator', 'session_id']) {
    assert.throws(() => new CodexKitBridgeClient({ headers: { [name]: 'override' } }), errorCode('invalid_configuration'));
  }
  for (const limits of [{ maxEventBytes: 0 }, { maxJsonDepth: 10000 }, { maxStreamBytes: NaN }, { toString: 10 }]) {
    assert.throws(() => new CodexKitBridgeClient({ limits }), errorCode('invalid_configuration'));
  }
});

test('trusted endpoint/header configuration is snapshotted and request URL fields are ignored', async () => {
  const config = { 'x-codex-beta-features': 'fixture-feature' };
  const { run, calls } = harness(undefined, { endpoint: 'https://codex.example/responses', headers: config });
  config['x-codex-beta-features'] = 'mutated';
  await run({ preparedRequest: { ...prepared(), endpoint: 'https://untrusted.example', headers: { Authorization: 'bad' } } });
  assert.equal(calls[0].url, 'https://codex.example/responses');
  assert.equal(calls[0].headers['x-codex-beta-features'], 'fixture-feature');
  assert.equal(calls[0].headers.Authorization, `Bearer ${authentication.accessToken}`);
});

for (const status of [400, 401, 403, 429, 500, 503, 302]) test(`HTTP ${status} produces one typed failure and no retry/redirect`, async () => {
  const { run, calls } = harness(undefined, { fetch: async () => new Response(JSON.stringify({ error: {
    code: 'rate_limit_exceeded', message: `Private: ${authentication.accessToken}`, input: 'private prompt',
  } }), { status, headers: { 'content-type': 'application/json', 'retry-after': '30', 'location': 'https://untrusted.example', 'x-request-id': 'req-http' } }) });
  await assert.rejects(run(), error => {
    errorCode(status === 401 || status === 403 ? 'authentication_failed' : 'http_error')(error);
    assert.equal(error.details.httpStatus, status);
    assert.equal(error.details.retryAfter, '30');
    assert.equal(error.details.providerCode, 'rate_limit_exceeded');
    assert.equal(error.details.requestId, 'req-http');
    assert.ok(!JSON.stringify(error).includes(authentication.accessToken));
    assert.ok(!JSON.stringify(error).includes('private prompt'));
    return true;
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].redirect, 'manual');
});

test('HTML and oversized error bodies retain their HTTP failure', async () => {
  for (const body of ['<html>Challenge</html>', '{'.repeat(100000)]) {
    const { run } = harness(undefined, { fetch: async () => new Response(body, { status: 403, headers: { 'content-type': 'application/json' } }) });
    await assert.rejects(run(), errorCode('authentication_failed', 'failed'));
  }
});

test('sanitizes transport causes and credential-shaped provider metadata', async () => {
  const { run } = harness(undefined, { fetch: async () => { throw new Error(`headers=${authentication.accessToken}`); } });
  await assert.rejects(run(), error => {
    errorCode('transport_error', 'unknown')(error);
    assert.ok(!JSON.stringify(error).includes(authentication.accessToken));
    assert.equal(error.cause, undefined);
    return true;
  });
  const other = harness(undefined, { fetch: async () => new Response('{}', { status: 401, headers: { 'x-request-id': authentication.accessToken } }) });
  await assert.rejects(other.run(), error => { assert.equal(error.details.requestId, undefined); return true; });
});

test('invalid credentials fail before fetching', async () => {
  for (const auth of [{}, { accessToken: 'x\ny', accountId: 'a' }, { accessToken: '', accountId: 'a' }]) {
    const { run, calls } = harness();
    await assert.rejects(run({ authentication: auth }), errorCode('invalid_authentication', 'not_started'));
    assert.equal(calls.length, 0);
  }
});

test('redaction preserves typed outcome values even with short account identifiers', async () => {
  const { run } = harness([{ type: 'response.failed', response: { error: { code: 'server_error' } } }]);
  await assert.rejects(run({ authentication: { accessToken: 'synthetic', accountId: 'a' } }), errorCode('provider_failed', 'failed'));
});

test('default client exposes typed errors without reaching the network', async () => {
  const client = new CodexKitBridgeClient();
  await assert.rejects(client.execute({ preparedRequest: prepared(), authentication: {} }), errorCode('invalid_authentication', 'not_started'));
  assert.deepEqual(new CodexKitCloudError('invalid_request').toJSON(), { code: 'invalid_request', message: 'The prepared request is malformed.' });
});

test('concurrent calls have independent credentials and response state', async () => {
  const calls = [];
  const client = new CodexKitBridgeClient({ fetch: async (_, init) => {
    const token = init.headers.Authorization;
    calls.push(token);
    await new Promise(resolve => setImmediate(resolve));
    return response([complete(token.endsWith('one') ? 'one' : 'two', { id: token.endsWith('one') ? 'resp-one' : 'resp-two' })]);
  } });
  const results = await Promise.all(['one', 'two'].map(token => client.execute({ preparedRequest: prepared(), authentication: { accessToken: token, accountId: `account-${token}` } })));
  assert.deepEqual(results.map(result => result.outputText), ['one', 'two']);
  assert.deepEqual(results.map(result => result.responseId), ['resp-one', 'resp-two']);
  assert.equal(calls.length, 2);
});
