const { test: nodeTest } = require('node:test');
const http = require('node:http');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const { createLocalAPIServer } = require('../examples/local-api/server.cjs');
const { prepared, authentication, requestBody } = require('./helpers.cjs');
const { imagePrepared } = require('./image-helpers.cjs');
const test = (name, run) => nodeTest(name, { timeout: 5000 }, run);

async function setup(t, options) {
  const server = createLocalAPIServer(options);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${server.address().port}`;
  return function send(path, body, extra = {}) {
    return new Promise((resolve, reject) => {
      const request = http.request(base + path, { method: body === undefined ? 'GET' : 'POST',
        headers: { 'content-type': 'application/json', 'x-demo-device': 'demo-test', ...extra } }, response => {
        let data = '';
        response.setEncoding('utf8');
        response.on('data', chunk => { data += chunk; });
        response.on('end', () => resolve({ status: response.statusCode, ...JSON.parse(data) }));
      });
      request.on('error', reject);
      request.end(body === undefined ? undefined : JSON.stringify(body));
    });
  };
}

function envelope(request = prepared(), preference) {
  const { body, ...metadata } = request;
  return { preparedRequest: { ...metadata, bodyBase64: Buffer.from(body).toString('base64') }, authentication,
    ...(preference === undefined ? {} : { completionPush: preference }) };
}

async function complete(send, id) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const reply = await send(`/codex/${id}`);
    if (['succeeded', 'failed'].includes(reply.data.status)) return reply.data;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error('Job did not finish');
}

for (const image of [false, true]) for (const push of [undefined, 'silent', 'regular']) {
  test(`demo ${image ? 'image' : 'response'} job with ${push ?? 'default'} preference completes with one event`, async t => {
    const send = await setup(t);
    const accepted = await send(image ? '/codex/images' : '/codex', envelope(image ? imagePrepared() : prepared(), push),
      { 'x-demo-hold': '1' });
    assert.equal(accepted.status, 202);
    assert.equal(accepted.data.completionPush, push ?? 'silent');
    assert.deepEqual((await send('/demo/queue')).data.deliveries, []);
    await send('/demo/release', {});
    const job = await complete(send, accepted.data.jobId);
    assert.equal(job.status, 'succeeded');
    assert.equal(job.completionPush, push ?? 'silent');
    const link = await send(`/codex/${job.jobId}/result`);
    assert.equal(new URL(link.data.url).pathname, `/codex/${job.jobId}/output`);
    const result = (await send(`/codex/${job.jobId}/output`)).data;
    assert.equal(result.status, 'completed');
    if (image) assert.ok(result.images[0].base64);
    else assert.equal(result.outputText, 'Local cloud bridge OK');
    const queue = (await send('/demo/queue')).data;
    assert.deepEqual(queue.deliveries, [{ simulated: true, jobIds: [job.jobId], completionPush: push ?? 'silent' }]);
    assert.equal(queue.jobs[0].providerCalls, 1);
    assert.equal(queue.submissions[0].sha256, queue.submissions[0].bodySHA256);
    assert.ok(!JSON.stringify(queue).includes(authentication.accessToken));
  });
}

test('demo lost reply retries preserve exact envelopes and changed preferences conflict', async t => {
  const send = await setup(t);
  const input = envelope(prepared(), 'regular');
  const headers = { 'x-demo-retry-once': '1', 'x-demo-hold': '1' };
  assert.equal((await send('/codex', input, headers)).status, 503);
  const accepted = await send('/codex', input, headers);
  assert.equal(accepted.status, 202);
  assert.equal((await send('/codex', { ...input, completionPush: 'silent' }, headers)).status, 409);
  let queue = (await send('/demo/queue')).data;
  assert.equal(queue.jobs.length, 1);
  assert.equal(queue.submissions[0].envelopeSHA256, queue.submissions[1].envelopeSHA256);
  assert.equal(queue.submissions[2].conflict, true);
  await send('/demo/release', {});
  assert.equal((await complete(send, accepted.data.jobId)).status, 'succeeded');
  // A repeat after completion still reuses the same result and sends no extra event.
  assert.equal((await send('/codex', input)).data.jobId, accepted.data.jobId);
  queue = (await send('/demo/queue')).data;
  assert.equal(queue.jobs[0].providerCalls, 1);
  assert.equal(queue.deliveries.length, 1);
});

test('demo mixed batch waits for every outstanding job and regular wins', async t => {
  const send = await setup(t, { maximumConcurrent: 1 });
  const ids = [];
  for (const [index, push] of ['silent', 'regular', 'silent'].entries()) {
    const request = { ...prepared(), clientRequestId: `batch-${index}` };
    ids.push((await send('/codex', envelope(request, push), { 'x-demo-hold': '1' })).data.jobId);
    assert.equal((await send('/demo/queue')).data.deliveries.length, 0);
  }
  await send('/demo/release', {});
  await Promise.all(ids.map(id => complete(send, id)));
  const queue = (await send('/demo/queue')).data;
  assert.deepEqual(queue.deliveries, [{ simulated: true, jobIds: ids, completionPush: 'regular' }]);
  assert.ok(queue.jobs.every(job => job.providerCalls === 1));
});

test('demo legacy metadata omits preference while stored job remains silent', async t => {
  const send = await setup(t);
  const accepted = await send('/codex', envelope(), { 'x-demo-legacy-job': '1' });
  assert.equal(accepted.data.completionPush, undefined);
  const job = await complete(send, accepted.data.jobId);
  const legacy = await send(`/codex/${job.jobId}`, undefined, { 'x-demo-legacy-job': '1' });
  assert.equal(legacy.data.completionPush, undefined);
  assert.equal(job.completionPush, 'silent');
});

test('demo rejects invalid preferences, digests, cross-route identities and real-mode fault injection', async t => {
  const send = await setup(t);
  for (const completionPush of ['loud', null, true]) {
    assert.equal((await send('/codex', { ...envelope(), completionPush })).status, 400);
  }
  const invalid = envelope({ ...prepared(), sha256: '0'.repeat(64) });
  assert.equal((await send('/codex', invalid)).status, 400);
  const response = prepared();
  await send('/codex', envelope(response), { 'x-demo-hold': '1' });
  const image = { ...imagePrepared(), clientRequestId: response.clientRequestId };
  assert.equal((await send('/codex/images', envelope(image))).status, 409);
  const live = await setup(t, { mode: 'live' });
  assert.equal((await live('/codex', envelope(), { 'x-demo-retry-once': '1' })).status, 400);
});

test('demo failure produces terminal metadata and drains the completion batch', async t => {
  const send = await setup(t, { fetch: async () => new Response('', { status: 500 }) });
  const accepted = await send('/codex', envelope(prepared(), 'regular'));
  const job = await complete(send, accepted.data.jobId);
  assert.equal(job.status, 'failed');
  assert.equal(job.failure.code, 'http_error');
  assert.equal((await send(`/codex/${job.jobId}/result`)).status, 409);
  assert.equal((await send('/demo/queue')).data.deliveries[0].completionPush, 'regular');
});

test('demo JSON request crosses real bridge schema validation', async t => {
  const send = await setup(t);
  const request = prepared(requestBody({ text: { format: { type: 'json_schema', name: 'demo', strict: true,
    schema: { type: 'object', properties: { message: { type: 'string' } }, required: ['message'], additionalProperties: false } } } }));
  const accepted = await send('/codex', envelope(request, 'regular'));
  await complete(send, accepted.data.jobId);
  const result = (await send(`/codex/${accepted.data.jobId}/output`)).data;
  assert.deepEqual(JSON.parse(result.outputText), { message: 'Local cloud bridge OK' });
});
