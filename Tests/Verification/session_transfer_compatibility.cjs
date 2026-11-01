// Offline check of the documented Swift-envelope -> existing Cloud authentication conversion.
// Run after: npm run build --prefix packages/codexkit
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { authenticationHeaders } = require('../../packages/codexkit/dist/request.js');
const payload = JSON.parse(readFileSync(join(__dirname, '../Fixtures/session-transfer/v1.json'), 'utf8'));
assert.equal(payload.version, 1);
assert.equal(payload.provider, 'chatgpt');
assert.ok(Number.isSafeInteger(payload.expiresAt));
const authentication = { accessToken: payload.accessToken, accountId: payload.account.id };
assert.deepEqual(authenticationHeaders(authentication), {
  Authorization: 'Bearer synthetic-transfer-secret',
  'ChatGPT-Account-ID': 'synthetic-account',
});
console.log('Session-transfer wire compatibility passed (synthetic fixture only).');
