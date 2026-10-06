const { randomUUID } = require('node:crypto');

const FIXTURE_MESSAGE = 'Local cloud bridge OK';

/** Exercises the real bridge parser and validation without contacting a provider. */
async function fixtureFetch(_url, init) {
  const request = JSON.parse(Buffer.from(init.body).toString('utf8'));
  const text = request.text.format.type === 'json_schema'
    ? JSON.stringify({ message: FIXTURE_MESSAGE }) : FIXTURE_MESSAGE;
  const response = {
    id: `fixture-${randomUUID()}`, status: 'completed',
    output: [{ id: 'fixture-message', type: 'message', role: 'assistant',
      content: [{ type: 'output_text', text }] }],
  };
  return new Response(`data: ${JSON.stringify({ type: 'response.completed', response })}\n\n`, {
    headers: { 'content-type': 'text/event-stream', 'x-request-id': 'local-fixture' },
  });
}

module.exports = { fixtureFetch, FIXTURE_MESSAGE };
