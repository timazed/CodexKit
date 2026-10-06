const { test } = require('node:test');
const assert = require('node:assert/strict');
const { complete, harness, errorCode } = require('./helpers.cjs');

test('cancellation before execution makes no request and exposes no abort reason', async () => {
  const signal = AbortSignal.abort(new Error('private abort reason'));
  const { run, calls } = harness();
  await assert.rejects(run({ signal }), error => {
    errorCode('cancelled', 'not_started')(error);
    assert.ok(!JSON.stringify(error).includes('private'));
    return true;
  });
  assert.equal(calls.length, 0);
});

test('cancellation while waiting for response headers propagates to transport', async () => {
  const controller = new AbortController();
  const { run, calls } = harness(undefined, { fetch: async () => new Promise(() => {}) });
  const promise = run({ signal: controller.signal });
  controller.abort('secret');
  await assert.rejects(promise, errorCode('cancelled', 'unknown'));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].signal.aborted, true);
});

test('cancellation while reading a stalled stream cancels the reader', async () => {
  const controller = new AbortController();
  let cancelled = false;
  const { run } = harness([], { stream: { close: false, onCancel: () => { cancelled = true; } } });
  const promise = run({ signal: controller.signal });
  await new Promise(resolve => setImmediate(resolve));
  controller.abort();
  await assert.rejects(promise, errorCode('cancelled', 'unknown'));
  assert.equal(cancelled, true);
});

test('callback failures abort execution without leaking callback errors or retrying', async () => {
  const { run, calls } = harness([{ type: 'response.output_text.delta', delta: 'part' }, complete()]);
  await assert.rejects(run({ onProgress: () => { throw new Error('private callback token'); } }), error => {
    errorCode('progress_callback_failed', 'unknown')(error);
    assert.ok(!JSON.stringify(error).includes('private'));
    return true;
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].signal.aborted, true);
});

test('slow callbacks apply backpressure and remain cancellable', async () => {
  const controller = new AbortController();
  let entered;
  const ready = new Promise(resolve => { entered = resolve; });
  const { run } = harness([{ type: 'response.output_text.delta', delta: 'part' }, complete()]);
  const promise = run({ signal: controller.signal, onProgress: async () => {
    entered();
    await new Promise(() => {});
  } });
  await ready;
  controller.abort();
  await assert.rejects(promise, errorCode('cancelled', 'unknown'));
});
