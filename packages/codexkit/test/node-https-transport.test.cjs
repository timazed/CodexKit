const { test } = require('node:test');
const assert = require('node:assert/strict');
const https = require('node:https');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { CodexKitBridgeClient, nodeHttpsTransport } = require('../dist/index.js');
const { imagePrepared, imageResult } = require('./image-helpers.cjs');
const { authentication, errorCode } = require('./helpers.cjs');

function mockRequest(t, respond) {
  const calls = [];
  t.mock.method(https, 'request', (url, options, callback) => {
    const outgoing = new EventEmitter();
    outgoing.end = body => {
      calls.push({ url: String(url), options, body });
      respond(callback, outgoing, options);
    };
    return outgoing;
  });
  return calls;
}
function response(callback, status, body, headers = {}) {
  const stream = new PassThrough();
  stream.statusCode = status;
  stream.headers = { 'content-type': 'application/json', ...headers };
  callback(stream);
  stream.end(body);
  return stream;
}

test('Node transport forwards exact bytes once and uses the caller deadline for delayed headers', async t => {
  const calls = mockRequest(t, callback => setTimeout(() => response(callback, 200, JSON.stringify(imageResult())), 20));
  const preparedRequest = imagePrepared();
  const client = new CodexKitBridgeClient({ fetch: nodeHttpsTransport });
  const result = await client.executeImage({ preparedRequest, authentication, signal: AbortSignal.timeout(1000) });
  assert.equal(result.images.length, 1);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://chatgpt.com/backend-api/codex/images/generations');
  assert.deepEqual(calls[0].body, new Uint8Array(preparedRequest.body));
  assert.equal(calls[0].options.timeout, undefined);
  assert.equal(calls[0].options.agent, false);
  assert.equal(calls[0].options.headers['accept-encoding'], 'identity');
  assert.equal(calls[0].options.headers.authorization, `Bearer ${authentication.accessToken}`);
  assert.ok(calls[0].options.signal instanceof AbortSignal);
});

test('Node transport leaves redirects and HTTP errors to the SDK without retrying', async t => {
  const calls = mockRequest(t, callback => response(callback, 302, '{}', { location: 'https://other.example/' }));
  const client = new CodexKitBridgeClient({ fetch: nodeHttpsTransport });
  await assert.rejects(client.executeImage({ preparedRequest: imagePrepared(), authentication }), errorCode('http_error', 'unknown'));
  assert.equal(calls.length, 1);
});

test('Node transport releases a pending request on cancellation and maps socket errors safely', async t => {
  let cancelled = false;
  const calls = mockRequest(t, (_callback, outgoing, options) => {
    options.signal.addEventListener('abort', () => { cancelled = true; outgoing.emit('error', new Error('private socket detail')); }, { once: true });
  });
  const controller = new AbortController();
  const pending = new CodexKitBridgeClient({ fetch: nodeHttpsTransport }).executeImage({ preparedRequest: imagePrepared(), authentication, signal: controller.signal });
  controller.abort();
  await assert.rejects(pending, error => {
    assert.equal(error.code, 'cancelled'); assert.equal(error.details.outcome, 'unknown');
    assert.ok(!JSON.stringify(error).includes('private socket detail')); return true;
  });
  assert.equal(calls.length, 1); assert.equal(cancelled, true);
});

test('Node transport propagates truncated response streams and handles bodyless statuses', async t => {
  let status = 200;
  mockRequest(t, callback => {
    if (status === 204) return response(callback, status, '');
    const incoming = new PassThrough(); incoming.statusCode = status; incoming.headers = { 'content-type': 'application/json' };
    callback(incoming); incoming.write('{');
    setImmediate(() => incoming.destroy(new Error('private stream detail')));
  });
  const client = new CodexKitBridgeClient({ fetch: nodeHttpsTransport });
  await assert.rejects(client.executeImage({ preparedRequest: imagePrepared(), authentication }), errorCode('transport_error', 'unknown'));
  status = 204;
  await assert.rejects(client.executeImage({ preparedRequest: imagePrepared(), authentication }), errorCode('invalid_response', 'unknown'));
});

test('Node transport rejects unsupported inputs before creating a connection', async t => {
  const calls = mockRequest(t, () => assert.fail('unexpected request'));
  const init = { method: 'POST', redirect: 'manual', body: new Uint8Array([1]), signal: AbortSignal.timeout(1000) };
  for (const [url, options] of [['http://example.com', init], ['https://example.com', { ...init, redirect: 'follow' }],
    ['https://example.com', { ...init, body: '{}' }], ['https://user:password@example.com', init]]) {
    await assert.rejects(nodeHttpsTransport(url, options), TypeError);
  }
  assert.equal(calls.length, 0);
});
