const { readFileSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');

module.exports = function verifyImagePackage({ root, directory, run }) {
  writeFileSync(join(directory, 'image-request.json'), readFileSync(join(root, 'test/fixtures/image-generate-request.json')));
  const consumer = `
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { CodexKitBridgeClient, DEFAULT_IMAGE_LIMITS } from '@timazed/codexkit';
const require = createRequire(import.meta.url);
const cjs = require('@timazed/codexkit');
assert.equal(cjs.CodexKitBridgeClient, CodexKitBridgeClient);
assert.equal(DEFAULT_IMAGE_LIMITS.maxOutputImages, 32);
const { fixtureFetch, FIXTURE_PNG } = require('./node_modules/@timazed/codexkit/examples/local-api/fixture.cjs');
const body = readFileSync('image-request.json');
const preparedRequest = { body, sha256: createHash('sha256').update(body).digest('hex'),
  action: 'generate', clientRequestId: 'c', imageTurnId: 'i', originator: 'codex_cli_rs' };
const authentication = { accessToken: 'synthetic-token', accountId: 'synthetic-account' };
let calls = 0;
globalThis.fetch = async (url, init) => {
  calls++;
  assert.equal(url, 'https://chatgpt.com/backend-api/codex/images/generations');
  assert.deepEqual(Buffer.from(init.body), body);
  assert.equal(init.headers.Authorization, 'Bearer synthetic-token');
  if (calls === 3) return new Response('', { status: 401 });
  assert.ok(calls <= 3, 'No automatic retry');
  return fixtureFetch(url, init);
};
const client = new CodexKitBridgeClient();
client.validatePreparedImageRequest(preparedRequest);
assert.equal(calls, 0);
const result = await client.executeImage({ preparedRequest, authentication });
assert.equal(result.images[0].base64, FIXTURE_PNG);
assert.deepEqual(result.images[0].pixelSize, { width: 2, height: 1 });
const { executeCodexImageRoute } = require('./compiled/examples/image-api-route.js');
const response = { status(code) { this.code = code; return this; }, json(value) { this.value = value; } };
await executeCodexImageRoute(preparedRequest, authentication, response);
assert.equal(response.code, 200);
assert.equal(response.value.images[0].base64, FIXTURE_PNG);
await executeCodexImageRoute({ ...preparedRequest, sha256: '0'.repeat(64) }, authentication, response);
assert.equal(response.code, 400);
assert.equal(response.value.error.code, 'integrity_mismatch');
assert.equal(calls, 2);
await executeCodexImageRoute(preparedRequest, authentication, response);
assert.equal(response.code, 502);
assert.equal(response.value.error.code, 'authentication_failed');
assert.equal(calls, 3);
`;
  writeFileSync(join(directory, 'image-consumer.mjs'), consumer);
  run(['image-consumer.mjs']);
};
