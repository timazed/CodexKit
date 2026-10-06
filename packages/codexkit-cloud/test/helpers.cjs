const { createHash } = require('node:crypto');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { CodexKitBridgeClient } = require('../dist/index.js');

const fixture = readFileSync(join(__dirname, 'fixtures/text-request.json'));
const authentication = { accessToken: 'synthetic-secret-token', accountId: 'synthetic-account' };

function prepared(body = fixture) {
  const bytes = typeof body === 'string' ? Buffer.from(body) : body instanceof Uint8Array ? Buffer.from(body) : Buffer.from(JSON.stringify(body));
  return { body: bytes, sha256: createHash('sha256').update(bytes).digest('hex'),
    sessionId: 'fixture-thread', clientRequestId: 'fixture-thread', originator: 'codex_cli_rs' };
}
function requestBody(change = {}) { return { ...JSON.parse(fixture), ...change }; }
function structured(schema) {
  return prepared(requestBody({ text: { format: { type: 'json_schema', name: 'fixture', strict: true, schema } } }));
}
function message(text = ' Hello 🙂\n', extras = {}) {
  return { type: 'message', id: 'msg-fixture', role: 'assistant', status: 'completed',
    content: [{ type: 'output_text', text, annotations: [] }], ...extras };
}
function complete(text, extra = {}) {
  return { type: 'response.completed', response: { id: 'resp-fixture', status: 'completed',
    output: [message(text)], usage: { input_tokens: 12, output_tokens: 4 }, ...extra } };
}
function sse(events, ending = '\n') {
  return events.map(event => `data: ${typeof event === 'string' ? event : JSON.stringify(event)}${ending}${ending}`).join('');
}
function response(events, { close = true, chunkSize = Infinity, ending = '\n', bytes, onCancel = () => {} } = {}) {
  const all = bytes ?? Buffer.from(sse(events, ending));
  let offset = 0;
  const body = new ReadableStream({
    pull(controller) {
      if (offset < all.length) {
        const end = Math.min(offset + chunkSize, all.length);
        controller.enqueue(all.subarray(offset, end));
        offset = end;
      } else if (close) controller.close();
    },
    cancel() { onCancel(); },
  });
  return new Response(body, { headers: { 'content-type': 'text/event-stream; charset=utf-8', 'x-request-id': 'req-fixture' } });
}
function harness(events = [complete()], options = {}) {
  const calls = [];
  const client = new CodexKitBridgeClient({ ...options,
    fetch: async (url, init) => {
      calls.push({ url, ...init });
      if (options.fetch) return options.fetch(url, init);
      return response(events, options.stream);
    },
  });
  return { calls, client, run: (input = {}) => client.execute({ preparedRequest: prepared(), authentication, ...input }) };
}
function errorCode(code, outcome) {
  return error => {
    const assert = require('node:assert/strict');
    assert.equal(error.name, 'CodexKitCloudError');
    assert.equal(error.code, code);
    if (outcome) assert.equal(error.details.outcome, outcome);
    return true;
  };
}

// All tests must inject a synthetic transport; an accidental live call fails immediately.
globalThis.fetch = async () => { throw new Error('Live network is disabled in offline tests'); };
module.exports = { prepared, requestBody, structured, authentication, message, complete, response, sse, harness, errorCode };
