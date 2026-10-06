const { test: nodeTest } = require('node:test');
const assert = require('node:assert/strict');
const { CodexKitBridgeClient, DEFAULT_IMAGE_LIMITS } = require('../dist/index.js');
const { authentication, errorCode } = require('./helpers.cjs');
const { imagePrepared, imageBody, imageResult, imageResponse, imageHarness, FIXTURE_PNG } = require('./image-helpers.cjs');
const test = (name, run) => nodeTest(name, { timeout: 5000 }, run);

test('images preserve prepared bytes, routing, authentication and actual PNG dimensions', async () => {
  const { run, calls, client } = imageHarness({ fetch: async () => imageResponse({}, { headers: {
    'x-request-id': 'request-1', 'x-codex-imagegen-request-id': 'image-1',
  } }) });
  const preparedRequest = imagePrepared();
  client.validatePreparedImageRequest(preparedRequest);
  assert.equal(calls.length, 0);
  const result = await run({ preparedRequest });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://chatgpt.com/backend-api/codex/images/generations');
  assert.deepEqual(Buffer.from(calls[0].body), preparedRequest.body);
  assert.equal(calls[0].method, 'POST');
  assert.equal(calls[0].redirect, 'manual');
  assert.equal(calls[0].headers.Authorization, `Bearer ${authentication.accessToken}`);
  assert.equal(calls[0].headers['ChatGPT-Account-ID'], authentication.accountId);
  assert.equal(calls[0].headers['x-client-request-id'], preparedRequest.clientRequestId);
  assert.equal(calls[0].headers['x-codex-image-turn-id'], preparedRequest.imageTurnId);
  assert.equal(calls[0].headers.originator, preparedRequest.originator);
  assert.equal(calls[0].headers.Accept, 'application/json');
  assert.equal(calls[0].headers.session_id, undefined);
  assert.deepEqual(result, { status: 'completed', action: 'generate', clientRequestId: preparedRequest.clientRequestId,
    requestId: 'request-1', imageRequestId: 'image-1', created: 1_700_000_000, background: 'transparent', quality: 'auto',
    images: [{ base64: FIXTURE_PNG, mimeType: 'image/png', pixelSize: { width: 2, height: 1 }, generationId: 'fixture-generation' }] });
  assert.ok(Object.isFrozen(result.images[0].pixelSize));
});

test('edits support five inline references and trusted endpoint configuration', async () => {
  const { run, calls } = imageHarness({ endpoint: 'https://trusted.example/custom/responses' });
  const images = ['png', 'jpeg', 'webp', 'png', 'jpeg'].map(type => ({ image_url: `data:image/${type};base64,AA==` }));
  const request = imagePrepared(imageBody({ images, background: 'opaque' }), 'edit');
  const result = await run({ preparedRequest: request });
  assert.equal(result.action, 'edit');
  assert.equal(calls[0].url, 'https://trusted.example/custom/images/edits');
  assert.deepEqual(Buffer.from(calls[0].body), request.body);
});

for (const [name, request, code] of [
  ['digest mismatch', { ...imagePrepared(), sha256: '0'.repeat(64) }, 'integrity_mismatch'],
  ['bad routing header', { ...imagePrepared(), imageTurnId: 'a\nb' }, 'invalid_request'],
  ['unknown action', { ...imagePrepared(), action: 'variation' }, 'unsupported_request'],
  ['tool calling', imagePrepared(imageBody({ tools: [{ type: 'image_generation' }] })), 'unsupported_request'],
  ['model selection', imagePrepared(imageBody({ model: 'other-model' })), 'unsupported_request'],
  ['quality override', imagePrepared(imageBody({ quality: 'high' })), 'unsupported_request'],
  ['size override', imagePrepared(imageBody({ size: '1024x1024' })), 'unsupported_request'],
  ['blank prompt', imagePrepared(imageBody({ prompt: '  ' })), 'invalid_request'],
  ['invalid background', imagePrepared(imageBody({ background: 'auto' })), 'unsupported_request'],
  ['generation references', imagePrepared(imageBody({ images: [] })), 'unsupported_request'],
  ['missing edit references', imagePrepared(imageBody(), 'edit'), 'unsupported_request'],
  ['six edit references', imagePrepared(imageBody({ images: Array(6).fill({ image_url: 'data:image/png;base64,AA==' }) }), 'edit'), 'unsupported_request'],
  ['remote edit URL', imagePrepared(imageBody({ images: [{ image_url: 'https://example.com/a.png' }] }), 'edit'), 'unsupported_request'],
  ['invalid reference encoding', imagePrepared(imageBody({ images: [{ image_url: 'data:image/png;base64,AB==' }] }), 'edit'), 'invalid_request'],
  ['duplicate JSON keys', imagePrepared('{"prompt":"a","prompt":"b"}'), 'invalid_request'],
]) test(`image preflight rejects ${name} without a POST`, async () => {
  const { client, run, calls } = imageHarness();
  assert.throws(() => client.validatePreparedImageRequest(request), errorCode(code));
  await assert.rejects(run({ preparedRequest: request }), errorCode(code, 'not_started'));
  assert.equal(calls.length, 0);
});

test('image credentials are required and request/auth snapshots isolate concurrent calls', async () => {
  const { run, calls } = imageHarness();
  await assert.rejects(run({ authentication: {} }), errorCode('invalid_authentication', 'not_started'));
  assert.equal(calls.length, 0);
  const request = imagePrepared();
  const original = Buffer.from(request.body);
  const credentials = { ...authentication };
  const pending = run({ preparedRequest: request, authentication: credentials });
  request.body.fill(0); credentials.accessToken = 'changed';
  await Promise.all([pending, run({ authentication: { accessToken: 'second', accountId: 'second-account' } })]);
  assert.deepEqual(Buffer.from(calls[0].body), original);
  assert.equal(calls[0].headers.Authorization, `Bearer ${authentication.accessToken}`);
  assert.equal(calls[1].headers.Authorization, 'Bearer second');
});

test('image configuration and both input budgets are bounded', async () => {
  assert.ok(Object.isFrozen(DEFAULT_IMAGE_LIMITS));
  for (const limits of [{ maxImageBytes: 33 * 1024 * 1024 }, { maxPixels: 0 }, { maxOutputImages: 33 }, { unknown: 1 }]) {
    assert.throws(() => new CodexKitBridgeClient({ imageLimits: limits }), errorCode('invalid_configuration'));
  }
  assert.throws(() => new CodexKitBridgeClient({ headers: { 'x-codex-image-turn-id': 'override' } }), errorCode('invalid_configuration'));
  for (const [limits, request] of [
    [{ maxRequestBytes: 10 }, imagePrepared()],
    [{ maxImageBytes: 1 }, imagePrepared(imageBody({ images: [{ image_url: 'data:image/png;base64,AAA=' }] }), 'edit')],
  ]) {
    const { run, calls } = imageHarness({ imageLimits: limits });
    await assert.rejects(run({ preparedRequest: request }), errorCode('limit_exceeded', 'not_started'));
    assert.equal(calls.length, 0);
  }
});

for (const [name, result, code] of [
  ['missing data', { data: [] }, 'invalid_response'],
  ['missing creation time', { created: undefined }, 'invalid_response'],
  ['URL-only output', { data: [{ url: 'https://example.com/image.png' }] }, 'invalid_response'],
  ['JPEG output', { data: [{ b64_json: '/9j/2Q==' }] }, 'invalid_response'],
  ['malformed base64', { data: [{ b64_json: FIXTURE_PNG + '\n' }] }, 'invalid_response'],
  ['missing PNG end', { data: [{ b64_json: Buffer.from(FIXTURE_PNG, 'base64').subarray(0, -12).toString('base64') }] }, 'invalid_response'],
  ['bad PNG CRC', { data: [{ b64_json: FIXTURE_PNG.replace('AAAAD0lEQ', 'BAAAD0lEQ') }] }, 'invalid_response'],
  ['provider failure', { status: 'failed', error: { code: 'generation_failed' } }, 'provider_failed'],
  ['incomplete generation', { status: 'incomplete' }, 'response_incomplete'],
  ['pending generation', { status: 'in_progress' }, 'invalid_response'],
]) test(`image output rejects ${name}`, async () => {
  const { run, calls } = imageHarness({ fetch: async () => imageResponse(result) });
  await assert.rejects(run(), errorCode(code));
  assert.equal(calls.length, 1);
});

test('image output enforces byte, count, total pixel and decompression limits', async () => {
  for (const limits of [{ maxResponseBytes: 10 }, { maxImageBytes: 10 }, { maxPixels: 1 }, { maxInflatedBytes: 1 },
    { maxOutputImages: 1 }, { maxPixels: 3 }]) {
    const { run } = imageHarness({ imageLimits: limits, fetch: async () => imageResponse({ data: Array(2).fill({ b64_json: FIXTURE_PNG }) }) });
    await assert.rejects(run(), errorCode('limit_exceeded', 'unknown'));
  }
  const { run } = imageHarness({ fetch: async () => imageResponse({}, { headers: { 'content-length': '999999999' } }) });
  await assert.rejects(run(), errorCode('limit_exceeded'));
});

test('image JSON must be valid, unique-key UTF-8 with the correct media type', async () => {
  for (const response of [new Response('{', { headers: { 'content-type': 'application/json' } }),
    new Response('{"created":1,"created":2}', { headers: { 'content-type': 'application/json' } }),
    new Response(Buffer.from([0xff]), { headers: { 'content-type': 'application/json' } }),
    new Response(JSON.stringify(imageResult()), { headers: { 'content-type': 'text/html' } })]) {
    await assert.rejects(imageHarness({ fetch: async () => response }).run(), errorCode('invalid_response'));
  }
});

test('image result allows the Swift contract without an explicit status', async () => {
  const result = await imageHarness({ fetch: async () => imageResponse({ status: undefined, quality: 'future-value' }) }).run();
  assert.equal(result.status, 'completed');
  assert.equal(result.quality, undefined);
});

test('image errors redact private data and never retry HTTP failures or redirects', async () => {
  for (const status of [302, 401, 403, 429, 500]) {
    const { run, calls } = imageHarness({ fetch: async () => Response.json({ error: {
      message: authentication.accessToken, code: authentication.accountId,
    } }, { status, headers: { location: 'https://example.com', 'x-request-id': authentication.accessToken,
      'x-codex-imagegen-request-id': authentication.accountId, 'retry-after': authentication.accessToken } }) });
    await assert.rejects(run(), error => {
      assert.equal(error.code, status === 401 || status === 403 ? 'authentication_failed' : 'http_error');
      assert.equal(error.details.httpStatus, status);
      assert.ok(!JSON.stringify(error).includes(authentication.accessToken));
      assert.ok(!JSON.stringify(error).includes(authentication.accountId));
      return true;
    });
    assert.equal(calls.length, 1);
  }
  const result = await imageHarness({ fetch: async () => imageResponse({ data: [{ b64_json: FIXTURE_PNG,
    generation_id: authentication.accessToken }] }) }).run();
  assert.equal(result.images[0].generationId, undefined);
});

test('image quota exposes typed reset metadata with body precedence and no retry', async () => {
  for (const [bodyReset, headers, reset] of [
    [123, { 'x-codex-active-limit': 'image_gen', 'x-image-gen-primary-used-percent': '100', 'x-image-gen-primary-reset-at': '456' }, 123],
    [undefined, { 'x-image-gen-primary-used-percent': '100', 'x-image-gen-primary-reset-at': '456',
      'x-image-gen-secondary-used-percent': '100', 'x-image-gen-secondary-reset-at': '789' }, 789],
    [undefined, { 'x-codex-active-limit': 'image_gen' }, undefined],
  ]) {
    const { run, calls } = imageHarness({ fetch: async () => Response.json({ error: { type: 'usage_limit_reached', resets_at: bodyReset } },
      { status: 429, headers: { ...headers, 'retry-after': '60' } }) });
    await assert.rejects(run(), error => {
      assert.equal(error.code, 'image_usage_limit_exceeded');
      assert.equal(error.details.outcome, 'failed');
      assert.equal(error.details.imageUsageLimit.limitId, 'image_gen');
      assert.equal(error.details.imageUsageLimit.resetsAt, reset);
      assert.equal(error.details.retryAfter, '60');
      return true;
    });
    assert.equal(calls.length, 1);
  }
  await assert.rejects(imageHarness({ fetch: async () => Response.json({ error: { type: 'usage_limit_reached' } },
    { status: 429 }) }).run(), errorCode('http_error'));
});

test('image cancellation handles preflight, pending headers and a late custom response', async () => {
  const pre = new AbortController(); pre.abort('private reason');
  const first = imageHarness();
  await assert.rejects(first.run({ signal: pre.signal }), errorCode('cancelled', 'not_started'));
  assert.equal(first.calls.length, 0);
  let resolve, cancelled = false;
  const control = new AbortController();
  const { run, calls } = imageHarness({ fetch: () => new Promise(done => { resolve = done; }) });
  const pending = run({ signal: control.signal });
  control.abort('private reason');
  await assert.rejects(pending, errorCode('cancelled', 'unknown'));
  resolve(new Response(new ReadableStream({ cancel() { cancelled = true; } })));
  await new Promise(done => setImmediate(done));
  assert.equal(calls.length, 1); assert.equal(cancelled, true);
});

test('image completion requires HTTP EOF and stalled reads can be cancelled', async () => {
  let entered, cancelled = false;
  const ready = new Promise(done => { entered = done; });
  const control = new AbortController();
  const { run } = imageHarness({ fetch: async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(Buffer.from(JSON.stringify(imageResult()))); },
    pull() { entered(); }, cancel() { cancelled = true; },
  }), { headers: { 'content-type': 'application/json' } }) });
  let complete = false;
  const pending = run({ signal: control.signal }).then(result => { complete = true; return result; });
  await ready; await new Promise(done => setImmediate(done));
  assert.equal(complete, false);
  control.abort();
  await assert.rejects(pending, errorCode('cancelled', 'unknown'));
  assert.equal(cancelled, true);
});

test('image stream errors after valid JSON never return success', async () => {
  let pushed = false;
  const { run } = imageHarness({ fetch: async () => new Response(new ReadableStream({ pull(controller) {
    if (!pushed) { pushed = true; controller.enqueue(Buffer.from(JSON.stringify(imageResult()))); }
    else controller.error(new Error('private provider connection failure'));
  } }), { headers: { 'content-type': 'application/json' } }) });
  await assert.rejects(run(), errorCode('transport_error', 'unknown'));
});

for (const [name, png] of Object.entries(require('./fixtures/png-cases.json'))) {
  test(`PNG scanline validation: ${name}`, async () => {
    const { run } = imageHarness({ fetch: async () => imageResponse({ data: [{ b64_json: png }] }) });
    if (name.startsWith('invalid-')) await assert.rejects(run(), errorCode('invalid_response'));
    else {
      const result = await run();
      assert.deepEqual(result.images[0].pixelSize, { width: 2, height: name === 'gray16' ? 1 : 2 });
      assert.equal(result.images[0].base64, png);
    }
  });
}
