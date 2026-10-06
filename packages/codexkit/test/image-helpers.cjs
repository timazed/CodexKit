const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { prepared, authentication } = require('./helpers.cjs');
const { CodexKitBridgeClient } = require('../dist/index.js');
const { FIXTURE_PNG } = require('../examples/local-api/fixture.cjs');

const fixture = readFileSync(join(__dirname, 'fixtures/image-generate-request.json'));
function imageBody(change = {}) { return { ...JSON.parse(fixture), ...change }; }
function imagePrepared(body = fixture, action = 'generate') {
  const { sessionId, ...value } = prepared(body);
  return { ...value, action, imageTurnId: 'fixture-image-turn' };
}
function imageResult(change = {}) {
  return { created: 1_700_000_000, status: 'completed', background: 'transparent', quality: 'auto',
    size: '9999x9999', data: [{ b64_json: FIXTURE_PNG, generation_id: 'fixture-generation' }], ...change };
}
function imageResponse(change = {}, init) { return Response.json(imageResult(change), init); }
function imageHarness(options = {}) {
  const calls = [];
  const client = new CodexKitBridgeClient({ ...options, fetch: async (url, init) => {
    calls.push({ url, ...init });
    return options.fetch ? options.fetch(url, init) : imageResponse();
  } });
  return { calls, client, run: (input = {}) => client.executeImage({ preparedRequest: imagePrepared(), authentication, ...input }) };
}
module.exports = { imagePrepared, imageBody, imageResult, imageResponse, imageHarness, FIXTURE_PNG };
