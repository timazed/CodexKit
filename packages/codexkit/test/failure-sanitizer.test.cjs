const { test } = require('node:test');
const assert = require('node:assert/strict');
const { CodexKitCloudError, sanitizeCodexFailure } = require('../dist/index.js');
const { harness, prepared, complete, authentication } = require('./helpers.cjs');
const { imageHarness, imagePrepared } = require('./image-helpers.cjs');
const fixture = require('./fixtures/http-schema-rejection.json');
const label = 'The provider returned an unsuccessful HTTP response.';
const minimal = { code: 'http_error', message: label };
const full = {
  ...minimal, outcome: 'failed', httpStatus: 400, requestId: 'req-fixture', responseId: 'resp_fixture',
  providerCode: 'invalid_json_schema', providerType: 'invalid_request_error', providerParam: 'text.format.schema',
  providerReason: 'invalid_schema', incompleteReason: 'max_output_tokens', retryAfter: '30',
  imageRequestId: 'image-fixture', imageUsageLimit: { limitId: 'image_gen', resetsAt: 123.5 },
};

for (const [mode, make, prepare] of [['text', (_, options) => harness(undefined, options), prepared],
  ['image', (_, options) => imageHarness(options), imagePrepared]]) {
  test(`${mode}: fixture HTTP 400 traverses SDK and public sanitizer without another request`, async () => {
    const input = prepare();
    const { run, calls } = make(undefined, { fetch: async () => Response.json(fixture, { status: 400,
      headers: { 'x-request-id': 'req-headerfixture', 'retry-after': '30' } }) });
    await assert.rejects(run({ preparedRequest: input }), error => {
      assert.ok(error instanceof CodexKitCloudError);
      const expected = { ...minimal, outcome: 'failed', httpStatus: 400,
        requestId: 'req-headerfixture', responseId: 'resp_schemafixture', providerCode: 'invalid_json_schema',
        providerType: 'invalid_request_error', providerParam: 'text.format.schema', providerReason: 'invalid_schema', retryAfter: '30' };
      assert.deepEqual(sanitizeCodexFailure(error.toJSON()), expected);
      assert.deepEqual(sanitizeCodexFailure(JSON.parse(JSON.stringify(error))), expected);
      assert.deepEqual(error.toJSON(), expected);
      return true;
    });
    assert.equal(calls.length, 1);
    assert.deepEqual(Buffer.from(calls[0].body), Buffer.from(input.body));
  });
}

test('full contract round-trips, is idempotent, and copies each retained object without mutation', () => {
  const input = structuredClone(full);
  Object.freeze(input.imageUsageLimit); Object.freeze(input);
  const safe = sanitizeCodexFailure(input);
  assert.deepEqual(safe, full);
  assert.notEqual(safe, input);
  assert.notEqual(safe.imageUsageLimit, input.imageUsageLimit);
  const again = sanitizeCodexFailure(safe);
  assert.deepEqual(again, safe); assert.notEqual(again, safe);
  assert.notEqual(again.imageUsageLimit, safe.imageUsageLimit);
  assert.deepEqual(sanitizeCodexFailure(JSON.parse(JSON.stringify(safe))), safe);
  safe.imageUsageLimit.resetsAt = 999;
  assert.deepEqual(input, full); assert.equal(again.imageUsageLimit.resetsAt, 123.5);
});

test('legacy errors require only a known SDK code and never invent optional diagnostics', () => {
  assert.deepEqual(sanitizeCodexFailure({ code: 'http_error' }), minimal);
  assert.deepEqual(sanitizeCodexFailure({ code: 'http_error', outcome: 'failed', httpStatus: 400 }),
    { ...minimal, outcome: 'failed', httpStatus: 400 });
  assert.deepEqual(sanitizeCodexFailure({ code: 'cancelled' }), new CodexKitCloudError('cancelled').toJSON());
  assert.equal(sanitizeCodexFailure({ code: 'application_job_failed' }), undefined);
  assert.equal(sanitizeCodexFailure({ code: 'future_sdk_error' }), undefined);
});

test('non-records, unknown codes, nested envelopes and serialized strings are invalid', () => {
  for (const input of [undefined, null, true, 42, 'http_error', JSON.stringify(full), [], [full], new Date(),
    new CodexKitCloudError('http_error'), {}, { error: full }, { details: full }, { code: null },
    { code: 400 }, { code: {} }, { code: 'toString' }, { code: 'constructor' }, { code: '__proto__' }]) {
    assert.equal(sanitizeCodexFailure(input), undefined);
  }
  assert.deepEqual(sanitizeCodexFailure(Object.assign(Object.create(null), { code: 'http_error' })), minimal);
});

test('only explicit fields survive; nested quota values are also allowlisted', () => {
  const input = { ...full, message: 'private message', stack: 'private stack', rawDiagnostics: fixture,
    providerBody: fixture, prompt: 'private prompt', credentials: authentication, accountId: authentication.accountId,
    signedUrl: 'https://example.test/private?token=secret', details: full, httpRequestId: 'api-fixture',
    imageUsageLimit: { ...full.imageUsageLimit, accountId: 'private account', raw: fixture } };
  const snapshot = structuredClone(input);
  assert.deepEqual(sanitizeCodexFailure(input), full);
  assert.deepEqual(input, snapshot);
  const polluted = JSON.parse('{"code":"http_error","__proto__":{"requestId":"req-inherited"},"constructor":{"secret":true}}');
  assert.deepEqual(sanitizeCodexFailure(polluted), minimal);
  assert.equal({}.secret, undefined);
});

test('malformed and recognizable sensitive values cannot escape in otherwise allowed fields', () => {
  const fields = Object.keys(full).filter(key => !['code', 'message'].includes(key));
  for (const value of [null, false, [], {}, NaN, Infinity, -1, 0.5, '', 'private_prompt', 'private prompt',
    authentication.accessToken, authentication.accountId, 'Bearer private-token', 'sk-other-secret',
    'eyJhbGciOiJIUzI1NiJ9.private.signature', 'person@example.com', 'https://example.test/a?signature=private',
    'text.format.schema.properties.private_character', 'req-private\n', 'resp_private\r', 'input[0]\n',
    '30\n', 'private\u202etext', 'x'.repeat(300)]) {
    const input = { code: 'http_error', message: value };
    for (const key of fields) input[key] = value;
    assert.deepEqual(sanitizeCodexFailure(input), minimal, `value: ${JSON.stringify(value)}`);
  }
});

test('bounds and categorical diagnostics share the live SDK policy', () => {
  for (const httpStatus of [100, 200, 400, 599]) assert.equal(sanitizeCodexFailure({ code: 'http_error', httpStatus }).httpStatus, httpStatus);
  for (const httpStatus of [99, 600, 400.1, '400']) assert.deepEqual(sanitizeCodexFailure({ code: 'http_error', httpStatus }), minimal);
  for (const retryAfter of ['0', '0.5', 'Wed, 21 Oct 2015 07:28:00 GMT']) {
    assert.equal(sanitizeCodexFailure({ code: 'http_error', retryAfter }).retryAfter, retryAfter);
  }
  for (const providerParam of ['input[9999].content[0].image_url', 'images[1].image_url']) {
    assert.equal(sanitizeCodexFailure({ code: 'http_error', providerParam }).providerParam, providerParam);
  }
  for (const providerParam of ['input[10000]', 'input[-1]', 'input[0].private', 'text.format.schema.properties.name']) {
    assert.deepEqual(sanitizeCodexFailure({ code: 'http_error', providerParam }), minimal);
  }
  const uuid = '12345678-1234-1234-1234-123456789abc';
  assert.deepEqual(sanitizeCodexFailure({ code: 'http_error', requestId: uuid, responseId: uuid, imageRequestId: uuid }),
    { ...minimal, requestId: uuid, imageRequestId: uuid });
  for (const resetsAt of [0, 0.5, 123]) assert.deepEqual(sanitizeCodexFailure({ code: 'http_error', imageUsageLimit: { limitId: 'image_gen', resetsAt } }),
    { ...minimal, imageUsageLimit: { limitId: 'image_gen', resetsAt } });
  for (const resetsAt of [-1, NaN, Infinity, '123', null, {}]) assert.deepEqual(sanitizeCodexFailure({ code: 'http_error', imageUsageLimit: { limitId: 'image_gen', resetsAt } }),
    { ...minimal, imageUsageLimit: { limitId: 'image_gen' } });
  assert.deepEqual(sanitizeCodexFailure({ code: 'http_error', imageUsageLimit: { limitId: 'account-private', resetsAt: 123 } }), minimal);
});

test('messages regenerate from every static SDK label, including after Error.message is changed', () => {
  const codes = ['invalid_configuration', 'invalid_request', 'integrity_mismatch', 'unsupported_request',
    'unsupported_schema', 'invalid_authentication', 'authentication_failed', 'http_error', 'transport_error',
    'stream_interrupted', 'invalid_response', 'provider_failed', 'response_incomplete', 'response_refused',
    'unsupported_output', 'invalid_output', 'schema_mismatch', 'limit_exceeded', 'cancelled',
    'progress_callback_failed', 'image_usage_limit_exceeded'];
  for (const code of codes) {
    const error = new CodexKitCloudError(code, full);
    const expected = { ...full, code, message: error.message };
    error.message = 'private overwritten message';
    assert.deepEqual(error.toJSON(), expected);
    assert.deepEqual(sanitizeCodexFailure({ ...full, code, message: 'private stored message' }), expected);
    assert.deepEqual(sanitizeCodexFailure(JSON.parse(JSON.stringify(error))), expected);
  }
});

test('serialization applies the same policy to caller-supplied error details', () => {
  const details = { ...structuredClone(full), providerCode: 'private_prompt', providerType: 'private_type',
    responseId: 'https://example.test/?token=secret', incompleteReason: 'private_prompt', stack: 'private' };
  const error = new CodexKitCloudError('http_error', details);
  const expected = sanitizeCodexFailure({ ...details, code: 'http_error' });
  assert.deepEqual(error.toJSON(), expected);
  details.imageUsageLimit.resetsAt = 999;
  assert.notEqual(error.details.imageUsageLimit.resetsAt, 999);
  assert.ok(Object.isFrozen(error.details.imageUsageLimit));
});

test('getters, inherited fields and toJSON hooks are not executed or copied', () => {
  const input = { code: 'http_error', get message() { assert.fail('message getter'); },
    get requestId() { assert.fail('request ID getter'); }, toJSON() { assert.fail('toJSON hook'); } };
  assert.deepEqual(sanitizeCodexFailure(input), minimal);
  assert.equal(sanitizeCodexFailure({ get code() { assert.fail('code getter'); } }), undefined);
  assert.equal(sanitizeCodexFailure(Object.create(full)), undefined);
  const proxy = Proxy.revocable({}, {}); proxy.revoke();
  assert.equal(sanitizeCodexFailure(proxy.proxy), undefined);
});

test('historical validation cannot authenticate identifier provenance or infer missing evidence', () => {
  assert.deepEqual(sanitizeCodexFailure({ code: 'http_error', requestId: 'req-echoedprompt', httpRequestId: 'api-local' }),
    { ...minimal, requestId: 'req-echoedprompt' });
  assert.deepEqual(sanitizeCodexFailure({ code: 'http_error', httpRequestId: 'req-api-only' }), minimal);
});

test('stream failures use the shared category policy without changing code or outcome', async () => {
  for (const [type, field, reason, expected] of [
    ['response.failed', 'providerCode', 'server_error', 'server_error'],
    ['response.failed', 'providerCode', 'private_prompt', undefined],
    ['response.incomplete', 'incompleteReason', 'max_output_tokens', 'max_output_tokens'],
    ['response.incomplete', 'incompleteReason', 'content_filter', 'content_filter'],
    ['response.incomplete', 'incompleteReason', 'private_prompt', undefined],
  ]) {
    const response = { id: 'resp-fixture', ...(type === 'response.failed' ?
      { error: { code: reason } } : { incomplete_details: { reason } }) };
    const { run, calls } = harness([{ type, response }]);
    await assert.rejects(run(), error => {
      const safe = sanitizeCodexFailure(JSON.parse(JSON.stringify(error)));
      assert.deepEqual(safe, error.toJSON());
      assert.equal(safe.code, type === 'response.failed' ? 'provider_failed' : 'response_incomplete');
      assert.equal(safe.outcome, type === 'response.failed' ? 'failed' : 'incomplete');
      assert.equal(safe[field], expected);
      return true;
    });
    assert.equal(calls.length, 1);
  }
});

test('actual image quota failure retains its nested allowance after public sanitization', async () => {
  const { run } = imageHarness({ fetch: async () => Response.json({ error: { type: 'usage_limit_reached', resets_at: 123 } },
    { status: 429, headers: { 'x-codex-active-limit': 'image_gen', 'x-codex-imagegen-request-id': 'image-fixture' } }) });
  await assert.rejects(run(), error => {
    const safe = sanitizeCodexFailure(JSON.parse(JSON.stringify(error)));
    assert.equal(safe.code, 'image_usage_limit_exceeded');
    assert.equal(safe.imageRequestId, 'image-fixture');
    assert.deepEqual(safe.imageUsageLimit, { limitId: 'image_gen', resetsAt: 123 });
    assert.deepEqual(safe, error.toJSON());
    return true;
  });
});

test('successful text and image requests retain original bytes, identifiers, and one-attempt behavior', async () => {
  const text = harness([complete('unchanged text', { id: 'legacy-opaque-response' })]);
  const result = await text.run();
  assert.equal(result.outputText, 'unchanged text'); assert.equal(result.responseId, 'legacy-opaque-response');
  assert.equal(result.requestId, 'req-fixture'); assert.equal(text.calls.length, 1);
  assert.deepEqual(Buffer.from(text.calls[0].body), Buffer.from(prepared().body));
  assert.equal(sanitizeCodexFailure(result), undefined);
  const image = imageHarness();
  const picture = await image.run();
  assert.equal(picture.status, 'completed'); assert.equal(picture.images[0].generationId, 'fixture-generation');
  assert.equal(image.calls.length, 1);
  assert.deepEqual(Buffer.from(image.calls[0].body), Buffer.from(imagePrepared().body));
  assert.equal(sanitizeCodexFailure(picture), undefined);
});
