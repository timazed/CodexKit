const { randomUUID } = require('node:crypto');

const FIXTURE_MESSAGE = 'Local cloud bridge OK';
// Synthetic 2×1 RGBA PNG generated independently with Python's zlib/CRC32.
const FIXTURE_PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAD0lEQVR4nGP4z8DwHwgbABB5A359Y87XAAAAAElFTkSuQmCC';

/** Exercises the real bridge parser and validation without contacting a provider. */
async function fixtureFetch(_url, init) {
  const request = JSON.parse(Buffer.from(init.body).toString('utf8'));
  if (/\/images\/(generations|edits)$/.test(new URL(_url).pathname)) {
    return Response.json({ created: 1_700_000_000, status: 'completed', background: request.background,
      quality: 'auto', data: [{ b64_json: FIXTURE_PNG, generation_id: 'local-image-fixture' }] }, {
      headers: { 'x-request-id': 'local-fixture', 'x-codex-imagegen-request-id': 'local-image-fixture' },
    });
  }
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

module.exports = { fixtureFetch, FIXTURE_MESSAGE, FIXTURE_PNG };
