const { test: nodeTest } = require('node:test');
const assert = require('node:assert/strict');
const { CodexKitCloudError } = require('../dist/index.js');
const { harness, prepared, requestBody, authentication, errorCode } = require('./helpers.cjs');
const { imageHarness, imagePrepared, imageBody } = require('./image-helpers.cjs');
const fixture = require('./fixtures/http-schema-rejection.json');
const test = (name, run) => nodeTest(name, { timeout: 5000 }, run);
const modes = [
  ['text', options => harness(undefined, options), prepared,
    prompt => prepared(requestBody({ instructions: prompt }))],
  ['image', imageHarness, imagePrepared,
    prompt => imagePrepared(imageBody({ prompt }))],
];

function http(body = fixture, { status = 400, headers = {} } = {}) {
  // Byte bodies let the missing-MIME case actually omit Content-Type.
  const bytes = body === null ? null : Buffer.isBuffer(body) ? body :
    Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  return new Response(bytes, { status, headers });
}
async function failure(run, input) {
  let captured;
  await assert.rejects(run(input), error => {
    assert.ok(error instanceof CodexKitCloudError);
    captured = JSON.parse(JSON.stringify(error));
    assert.deepEqual(captured, JSON.parse(JSON.stringify(error.toJSON())));
    assert.deepEqual(captured, { code: error.code, message: error.message, ...error.details });
    assert.equal(error.cause, undefined);
    return true;
  });
  return captured;
}

for (const [mode, make, prepare, withPrompt] of modes) {
  test(`${mode}: schema 400 exposes a flat, safe contract and sends original bytes once`, async () => {
    const preparedRequest = prepare();
    const { run, calls } = make({ fetch: async () => http(fixture, { headers: {
      'content-type': 'application/json', 'x-request-id': 'req-headerfixture', 'retry-after': '30',
    } }) });
    const result = await failure(run, { preparedRequest, onProgress: () => assert.fail('HTTP failures cannot generate progress') });
    assert.deepEqual(result, {
      code: 'http_error', message: 'The provider returned an unsuccessful HTTP response.',
      outcome: 'failed', httpStatus: 400, requestId: 'req-headerfixture', responseId: 'resp_schemafixture',
      providerCode: 'invalid_json_schema', providerType: 'invalid_request_error',
      providerParam: 'text.format.schema', providerReason: 'invalid_schema', retryAfter: '30',
    });
    assert.equal(calls.length, 1);
    assert.deepEqual(Buffer.from(calls[0].body), Buffer.from(preparedRequest.body));
    assert.equal(calls[0].method, 'POST');
    assert.equal(calls[0].redirect, 'manual');
  });

  for (const contentType of [undefined, 'text/plain', 'text/html', 'application/octet-stream', 'APPLICATION/JSON']) {
    test(`${mode}: diagnostics survive Content-Type ${contentType}`, async () => {
      const result = await failure(make({ fetch: async () => http(fixture, {
        headers: contentType ? { 'content-type': contentType } : {},
      }) }).run);
      assert.equal(result.providerReason, 'invalid_schema');
      assert.equal(result.providerParam, 'text.format.schema');
      assert.equal(result.requestId, 'req-bodyfixture');
      assert.equal(result.responseId, 'resp_schemafixture');
    });
  }

  test(`${mode}: known parameter failures and message-only schema templates use static reasons`, async () => {
    for (const [error, expected] of [
      [{ code: 'unsupported_parameter', type: 'invalid_request_error', param: 'temperature' }, 'unsupported_parameter'],
      [{ code: 'missing_required_parameter', param: 'input' }, 'missing_parameter'],
      [{ code: 'invalid_value', param: 'input[12].content[3].text' }, 'invalid_parameter'],
      [{ code: 'context_length_exceeded' }, 'context_length_exceeded'],
      [{ code: 'content_policy_violation' }, 'content_policy'],
      [{ code: 'insufficient_quota' }, 'quota_exceeded'],
      [{ code: null, type: 'invalid_request_error', param: 'response_format', message: fixture.error.message }, 'invalid_schema'],
      [{ message: fixture.error.message }, 'invalid_request'],
      [{ param: 'text.format.schema.properties.private_character', message: 'private world narrative' }, 'invalid_request'],
    ]) {
      const result = await failure(make({ fetch: async () => http({ error }) }).run);
      assert.equal(result.providerReason, expected);
      assert.ok(!JSON.stringify(result).includes('private'));
    }
  });

  test(`${mode}: recognized body IDs and response-header precedence`, async () => {
    for (const [body, headers, requestId, responseId] of [
      [fixture, { 'x-response-id': 'resp_headerfixture' }, 'req-bodyfixture', 'resp_headerfixture'],
      [{ request_id: '12345678-1234-1234-1234-123456789abc', response: { id: 'resp_nestedfixture' } }, {},
        '12345678-1234-1234-1234-123456789abc', 'resp_nestedfixture'],
      [{ request_id: 'req-topfixture', response_id: 'resp_topfixture', error: fixture.error }, {}, 'req-topfixture', 'resp_topfixture'],
      [fixture, { 'x-request-id': 'Bearer private-token', 'x-response-id': 'private response text' }, 'req-bodyfixture', 'resp_schemafixture'],
    ]) {
      const result = await failure(make({ fetch: async () => http(body, { headers }) }).run);
      assert.equal(result.requestId, requestId);
      assert.equal(result.responseId, responseId);
    }
  });

  test(`${mode}: malformed, non-JSON, invalid UTF-8 and duplicate keys retain HTTP failure`, async () => {
    for (const body of ['{', '<html>private gateway response</html>', 'private response text', '', null,
      Buffer.from([0xff, 0xfe]), '{"error":{"code":"invalid_value","code":"invalid_schema"}}',
      '{"error":{"message":"\\ud800"}}', '[]', '42', '{"error":"private error"}']) {
      const result = await failure(make({ fetch: async () => http(body, { status: 503, headers: {
        'content-type': 'application/json', 'x-request-id': 'req-malformedfixture',
      } }) }).run);
      assert.deepEqual(result, { code: 'http_error', message: 'The provider returned an unsuccessful HTTP response.',
        outcome: 'unknown', requestId: 'req-malformedfixture', httpStatus: 503, providerReason: 'server_error' });
    }
  });

  test(`${mode}: depth and node limits cannot mask HTTP errors`, async () => {
    for (const [limits, body] of [
      [{ maxJsonDepth: 8 }, '['.repeat(20) + '0' + ']'.repeat(20)],
      [{ maxJsonNodes: 100 }, JSON.stringify(Array(200).fill(null))],
    ]) {
      const result = await failure(make({ limits, fetch: async () => http(body) }).run);
      assert.equal(result.code, 'http_error'); assert.equal(result.httpStatus, 400);
      assert.equal(result.providerCode, undefined);
    }
  });

  test(`${mode}: byte cap rejects entire oversized body and cancels without draining`, async () => {
    for (const maximum of [64 * 1024, 1024]) {
      const prefix = Buffer.from(JSON.stringify(fixture));
      for (const size of [maximum, maximum + 1]) {
        let pulls = 0, cancelled = false;
        const bytes = Buffer.concat([prefix, Buffer.alloc(size - prefix.length, 32)]);
        const body = new ReadableStream({ pull(controller) {
          pulls++;
          if (pulls === 1) controller.enqueue(bytes);
          else if (size === maximum) controller.close();
          else assert.fail('oversized body must not be drained');
        }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
        const result = await failure(make({ limits: { maxEventBytes: maximum },
          fetch: async () => new Response(body, { status: 400 }) }).run);
        assert.equal(result.code, 'http_error'); assert.equal(result.httpStatus, 400);
        assert.equal(result.providerCode, size === maximum ? 'invalid_json_schema' : undefined);
        assert.equal(pulls, size === maximum ? 2 : 1);
        if (size > maximum) assert.equal(cancelled, true);
        assert.equal(body.locked, false);
      }
    }
  });

  test(`${mode}: large declared bodies and endless empty chunks stop inspection`, async () => {
    for (const declared of [true, false]) {
      let pulls = 0, cancelled = false;
      const body = new ReadableStream({ pull(controller) { pulls++; controller.enqueue(new Uint8Array()); },
        cancel() { cancelled = true; } }, { highWaterMark: 0 });
      const result = await failure(make({ fetch: async () => new Response(body, { status: 400,
        headers: declared ? { 'content-length': '65537' } : {} }) }).run);
      assert.equal(result.code, 'http_error'); assert.equal(cancelled, true);
      assert.equal(pulls, declared ? 0 : 1025); assert.equal(body.locked, false);
    }
  });

  test(`${mode}: one-byte chunks work; a broken or locked reader cannot replace HTTP status`, async () => {
    const bytes = Buffer.from(JSON.stringify(fixture));
    let at = 0;
    const body = new ReadableStream({ pull(controller) {
      if (at < bytes.length) controller.enqueue(bytes.subarray(at, ++at));
      else controller.close();
    } });
    assert.equal((await failure(make({ fetch: async () => new Response(body, { status: 400 }) }).run)).providerReason, 'invalid_schema');
    for (const locked of [false, true]) {
      const broken = new ReadableStream({ pull(controller) { controller.error(new Error('private transport cause')); } });
      const response = new Response(broken, { status: 400 });
      const reader = locked ? broken.getReader() : undefined;
      try {
        const result = await failure(make({ fetch: async () => response }).run);
        assert.equal(result.code, 'http_error'); assert.equal(result.httpStatus, 400);
        assert.ok(!JSON.stringify(result).includes('private'));
      } finally { reader?.releaseLock(); }
    }
  });

  test(`${mode}: credentials, account IDs, arbitrary tokens, prompt and schema echoes never serialize`, async () => {
    const privateValues = [authentication.accessToken, authentication.accountId, 'Bearer other-token',
      'sk-unrelated-secret', 'eyJhbGciOiJIUzI1NiJ9.private.signature', 'private_prompt', 'person@example.com',
      'text.format.schema.properties.private_character', 'x'.repeat(300), 'private\ntext', '\u202eprivate',
      'req-private\n', 'resp_private\r', 'input[0]\n', 'images[0]\r', null, 123, ['private'], { value: 'private' }];
    for (const secret of privateValues) {
      const result = await failure(make({ headers: { 'x-private-config': 'configured-secret' },
        fetch: async () => http({ error: { code: secret, type: secret, param: secret,
          message: secret, request_id: secret, response_id: secret }, account_id: secret }) }).run);
      assert.deepEqual(result, { code: 'http_error', message: 'The provider returned an unsuccessful HTTP response.',
        outcome: 'failed', httpStatus: 400, providerReason: 'invalid_request' });
    }
    for (const secret of [authentication.accessToken, authentication.accountId, 'configured-secret', 'fixture-thread', 'fixture-image-turn']) {
      const result = await failure(make({ headers: { 'x-private-config': 'configured-secret' }, fetch: async () => http({}, {
        headers: { 'x-request-id': `req-${secret}`, 'x-response-id': `resp_${secret}`,
          'x-codex-imagegen-request-id': `image-${secret}`, authorization: `Bearer ${secret}`, 'set-cookie': secret },
      }) }).run);
      if (secret === 'fixture-image-turn' && mode === 'text') continue;
      assert.ok(!JSON.stringify(result).includes(secret));
    }
    for (const prompt of ['req-echoedprompt', 'echoedprompt', 'resp_echoedprompt']) {
      const result = await failure(make({ fetch: async () => http({ request_id: 'req-echoedprompt',
        response_id: 'resp_echoedprompt' }) }).run, { preparedRequest: withPrompt(prompt) });
      assert.ok(!JSON.stringify(result).includes(prompt));
    }
    // Even JSON Unicode escapes in the prepared bytes cannot disguise an echoed ID.
    const request = withPrompt('req-escapedprompt');
    const escaped = prepare(Buffer.from(request.body).toString().replace('req-escapedprompt', '\\u0072eq-escapedprompt'));
    const result = await failure(make({ fetch: async () => http({ request_id: 'req-escapedprompt' }) }).run,
      { preparedRequest: escaped });
    assert.equal(result.requestId, undefined);
  });

  test(`${mode}: caller cancellation while inspecting an HTTP body remains cancellation`, async () => {
    for (const headers of [{}, { 'content-type': 'application/json' }, { 'content-type': 'text/plain' }]) {
      const control = new AbortController();
      let entered, cancelled = false;
      const ready = new Promise(resolve => { entered = resolve; });
      const body = new ReadableStream({ pull() { entered(); }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
      const { run, calls } = make({ fetch: async () => new Response(body, { status: 400, headers }) });
      const pending = failure(run, { signal: control.signal });
      await ready; control.abort(new Error('private abort reason'));
      const result = await pending;
      assert.equal(result.code, 'cancelled'); assert.equal(result.outcome, 'unknown');
      assert.equal(result.httpStatus, undefined); assert.ok(!JSON.stringify(result).includes('private'));
      assert.equal(cancelled, true); assert.equal(body.locked, false); assert.equal(calls.length, 1);
      assert.equal(calls[0].signal.aborted, true);
    }
    const { run, calls } = make();
    await assert.rejects(run({ signal: AbortSignal.abort('private') }), errorCode('cancelled', 'not_started'));
    assert.equal(calls.length, 0);
  });

  test(`${mode}: overflow across chunks ignores a parseable prefix and cannot await stalled cleanup`, async () => {
    let pulls = 0, cancelled = false;
    const prefix = Buffer.from(JSON.stringify(fixture));
    const body = new ReadableStream({ pull(controller) {
      pulls++;
      if (pulls === 1) controller.enqueue(Buffer.concat([prefix, Buffer.alloc(65536 - prefix.length, 32)]));
      else if (pulls === 2) controller.enqueue(Buffer.from(' '));
      else assert.fail('must stop reading at overflow');
    }, cancel() { cancelled = true; return new Promise(() => {}); } }, { highWaterMark: 0 });
    const result = await failure(make({ fetch: async () => new Response(body, { status: 400,
      headers: { 'content-length': '1', 'x-request-id': 'req-overflowfixture' } }) }).run);
    assert.equal(result.code, 'http_error'); assert.equal(result.httpStatus, 400);
    assert.equal(result.providerCode, undefined); assert.equal(result.requestId, 'req-overflowfixture');
    assert.equal(pulls, 2); assert.equal(cancelled, true); assert.equal(body.locked, false);
  });

  test(`${mode}: established status/code/outcome and retry-after semantics stay intact`, async () => {
    for (const [status, reason] of [[302, 'unclassified'], [400, 'invalid_request'], [401, 'authentication'],
      [403, 'permission_denied'], [404, 'unclassified'], [422, 'invalid_request'], [429, 'rate_limit_exceeded'], [503, 'server_error']]) {
      const { run, calls } = make({ fetch: async () => http(null, { status, headers: { 'retry-after': '30' } }) });
      const result = await failure(run);
      assert.equal(result.code, status === 401 || status === 403 ? 'authentication_failed' : 'http_error');
      assert.equal(result.outcome, status >= 400 && status < 500 ? 'failed' : 'unknown');
      assert.equal(result.httpStatus, status); assert.equal(result.providerReason, reason);
      assert.equal(result.retryAfter, '30'); assert.equal(calls.length, 1);
    }
    const result = await failure(make({ fetch: async () => http(fixture) }).run,
      { authentication: { accessToken: 'token', accountId: 'a' } });
    assert.equal(result.outcome, 'failed'); assert.equal(result.providerReason, 'invalid_schema');
  });
}
