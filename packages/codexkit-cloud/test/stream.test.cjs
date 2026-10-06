const { test } = require('node:test');
const assert = require('node:assert/strict');
const { message, complete, response, sse, harness, errorCode } = require('./helpers.cjs');

for (const ending of ['\n', '\r\n', '\r']) test(`SSE ${JSON.stringify(ending)} handles one-byte chunks and split Unicode`, async () => {
  const { run } = harness([complete('🙂 café 中文\n')], { stream: { chunkSize: 1, ending } });
  assert.equal((await run()).outputText, '🙂 café 中文\n');
});

test('SSE comments, BOM, multiline data, and unknown informational events', async () => {
  const data = '\ufeff: keep alive\r\n\r\n' + sse([{ type: 'codex.future_info', value: 1 }]) +
    'event: response.completed\ndata: {"type":"response.completed",\n' +
    `data: "response":${JSON.stringify(complete('exact').response)}}\n\n`;
  const { run } = harness(undefined, { stream: { bytes: Buffer.from(data), chunkSize: 3 } });
  assert.equal((await run()).outputText, 'exact');
});

test('returns at terminal completion without waiting for EOF and closes the reader', async () => {
  let cancelled = 0;
  const { run } = harness([complete('finished')], { stream: { close: false, onCancel: () => cancelled++ } });
  assert.equal((await run()).outputText, 'finished');
  assert.equal(cancelled, 1);
});

test('actual progress is provisional; terminal snapshot is authoritative', async () => {
  const seen = [];
  const { run } = harness([
    { type: 'response.created', sequence_number: 0, response: { id: 'resp-fixture' } },
    { type: 'response.output_text.delta', sequence_number: 1, delta: 'provisional', item_id: 'msg-fixture', content_index: 0 },
    { type: 'response.reasoning_summary_text.delta', sequence_number: 2, delta: 'Working', item_id: 'reasoning-1', summary_index: 0 },
    { type: 'response.output_item.done', sequence_number: 3, output_index: 0, item: message('old snapshot') },
    { ...complete(' canonical result\n'), sequence_number: 4 },
  ]);
  const result = await run({ onProgress: async event => { await Promise.resolve(); seen.push(event); } });
  assert.equal(seen.length, 3);
  assert.equal(seen[0].responseId, 'resp-fixture');
  assert.equal(seen[1].delta, 'provisional');
  assert.equal(result.outputText, ' canonical result\n');
});

test('supports CodexKit terminal events without an output snapshot or status', async () => {
  const { run } = harness([
    { type: 'response.output_item.done', output_index: 0, item: message('saved') },
    { type: 'response.completed', response: { id: 'resp-fixture' } },
  ]);
  const result = await run();
  assert.equal(result.outputText, 'saved');
  assert.equal(result.output.length, 1);
});

test('fallback completed items use provider indexes instead of arrival order', async () => {
  const { run } = harness([
    { type: 'response.output_item.done', output_index: 1, item: message('B', { id: 'second' }) },
    { type: 'response.output_item.done', output_index: 0, item: message('A', { id: 'first' }) },
    { type: 'response.completed', response: { id: 'resp-fixture' } },
  ]);
  assert.equal((await run()).outputText, 'AB');
});

test('preserves commentary separately from final-answer text', async () => {
  const { run } = harness([complete('', { output: [
    { type: 'reasoning', id: 'reasoning', summary: [] },
    message('I am working.', { id: 'commentary', phase: 'commentary' }),
    message(' Final answer.\n', { id: 'answer', phase: 'final_answer' }),
  ] })]);
  const result = await run();
  assert.equal(result.outputText, ' Final answer.\n');
  assert.equal(result.messages[0].text, 'I am working.');
  assert.equal(result.output.length, 3);
});

for (const events of [[], [{ type: 'response.output_text.delta', delta: '{"looks":"valid"}' }], ['[DONE]'],
  [{ type: 'response.output_item.done', output_index: 0, item: message('{"valid":true}') }]]) {
  test(`EOF/marker without terminal completion rejects ${JSON.stringify(events)}`, async () => {
    const { run, calls } = harness(events);
    await assert.rejects(run(), errorCode('stream_interrupted', 'unknown'));
    assert.equal(calls.length, 1);
  });
}

test('an unterminated terminal SSE frame does not establish completion', async () => {
  const { run } = harness(undefined, { stream: { bytes: Buffer.from(`data: ${JSON.stringify(complete())}\n`) } });
  await assert.rejects(run(), errorCode('stream_interrupted', 'unknown'));
});

test('transport failure mid-stream never returns a partial success', async () => {
  let count = 0;
  const { run, calls } = harness(undefined, { fetch: async () => new Response(new ReadableStream({
    pull(controller) {
      if (count++ === 0) controller.enqueue(Buffer.from(sse([{ type: 'response.output_text.delta', delta: 'partial' }])));
      else controller.error(new Error('private transport details'));
    },
  }), { headers: { 'content-type': 'text/event-stream' } }) });
  await assert.rejects(run(), errorCode('transport_error', 'unknown'));
  assert.equal(calls.length, 1);
});

for (const [events, code, outcome] of [
  [[{ type: 'response.failed', response: { id: 'resp-fixture', error: { code: 'server_error', message: 'Private' } } }], 'provider_failed', 'failed'],
  [[{ type: 'error', code: 'server_error', message: 'Private' }], 'provider_failed', 'failed'],
  [[{ type: 'response.incomplete', response: { id: 'resp-fixture', incomplete_details: { reason: 'max_output_tokens' } } }], 'response_incomplete', 'incomplete'],
  [[complete('', { status: 'incomplete' })], 'response_incomplete', 'incomplete'],
  [[complete('', { error: { code: 'server_error' } })], 'provider_failed', 'unknown'],
  [[complete('', { incomplete_details: { reason: 'max_output_tokens' } })], 'response_incomplete', 'incomplete'],
  [[complete('', { output: [message('', { content: [{ type: 'refusal', refusal: 'Private refusal' }] })] })], 'response_refused', 'completed'],
  [[complete('', { output: [{ type: 'function_call', name: 'tool' }] })], 'unsupported_output', 'completed'],
  [[{ type: 'response.output_item.added', item: { type: 'web_search_call' } }], 'unsupported_output', 'unknown'],
  [[{ type: 'response.function_call_arguments.delta', delta: '{}' }], 'unsupported_output', 'unknown'],
]) test(`reports ${code} for ${JSON.stringify(events)}`, async () => {
  const { run } = harness(events);
  await assert.rejects(run(), error => {
    errorCode(code, outcome)(error);
    assert.ok(!JSON.stringify(error).includes('Private'));
    return true;
  });
});

for (const events of [
  ['{broken'], ['{"type":"response.completed","type":"response.failed"}'],
  [{ type: 'response.completed' }], [complete('', { output: [] })],
  [complete('', { output: [message('x', { status: 'in_progress' })] })],
  [complete('', { output: [message('x'), message('y')] })],
  [complete('', { output: [message('thinking', { phase: 'commentary' })] })],
  [{ type: 'response.output_text.delta', delta: 42 }],
  [{ type: 'response.created', response: { id: 'other' } }, complete()],
  [{ type: 'response.output_item.done', output_index: 1, item: message() }, { type: 'response.completed', response: { id: 'resp-fixture' } }],
]) test(`rejects malformed/inconsistent response ${JSON.stringify(events)}`, async () => {
  await assert.rejects(harness(events).run(), errorCode('invalid_response'));
});

test('SSE event name must agree with its JSON discriminator', async () => {
  const { run } = harness(undefined, { stream: { bytes: Buffer.from(`event: response.failed\ndata: ${JSON.stringify(complete())}\n\n`) } });
  await assert.rejects(run(), errorCode('invalid_response'));
});

test('identical numbered duplicates are suppressed; conflicting or backwards events fail', async () => {
  const delta = { type: 'response.output_text.delta', sequence_number: 1, delta: 'A' };
  let count = 0;
  await harness([delta, delta, { ...complete(), sequence_number: 2 }]).run({ onProgress: () => count++ });
  assert.equal(count, 1);
  for (const next of [{ ...delta, delta: 'B' }, { ...delta, sequence_number: 0 }]) {
    await assert.rejects(harness([delta, next, complete()]).run(), errorCode('invalid_response'));
  }
});

test('rejects invalid UTF-8 and incomplete UTF-8 at EOF', async () => {
  for (const bytes of [Buffer.from([0xff]), Buffer.from([0xe2, 0x82])]) {
    await assert.rejects(harness(undefined, { stream: { bytes } }).run(), errorCode('invalid_response'));
  }
});

test('rejects successful HTTP responses without an SSE body', async () => {
  const { run } = harness(undefined, { fetch: async () => new Response('{}', { headers: { 'content-type': 'application/json' } }) });
  await assert.rejects(run(), errorCode('invalid_response', 'unknown'));
});

test('event, stream, output, and retained item limits are enforced', async () => {
  for (const limits of [{ maxEventBytes: 32 }, { maxStreamBytes: 64 }, { maxOutputBytes: 5 }]) {
    await assert.rejects(harness([complete()], { limits }).run(), errorCode('limit_exceeded'));
  }
  const tooMany = complete('', { output: [message('a', { id: 'a' }), message('b', { id: 'b' })] });
  await assert.rejects(harness([tooMany], { limits: { maxOutputItems: 1 } }).run(), errorCode('limit_exceeded'));
  const retained = ['a', 'b'].map((id, output_index) => ({ type: 'response.output_item.done', output_index, item: message(id, { id }) }));
  await assert.rejects(harness(retained, { limits: { maxOutputItems: 1 } }).run(), errorCode('limit_exceeded'));
  await assert.rejects(harness(undefined, { limits: { maxEventBytes: 32 }, stream: { bytes: Buffer.from(':' + 'x'.repeat(1000)) } }).run(), errorCode('limit_exceeded'));
});

test('no output after terminal completion can replace the completed result', async () => {
  assert.equal((await harness([complete('final'), { type: 'response.failed' }]).run()).outputText, 'final');
});
