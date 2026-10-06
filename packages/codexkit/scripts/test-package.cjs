const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync, cpSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');

const root = resolve(__dirname, '..');
const directory = mkdtempSync(join(tmpdir(), 'codexkit-package-'));
const npm = process.env.npm_execpath;
if (!npm) throw new Error('Run this check with npm run test:package after building.');
const run = (args, cwd = directory) => execFileSync(process.execPath, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

try {
  const packed = JSON.parse(run([npm, 'pack', '--ignore-scripts', '--json', '--cache', join(directory, 'cache'), '--pack-destination', directory], root))[0];
  assert.ok(packed.files.some(file => file.path === 'dist/index.js'));
  assert.ok(packed.files.some(file => file.path === 'dist/index.d.ts'));
  assert.ok(packed.files.some(file => file.path === 'docs/compatibility.md'));
  assert.ok(packed.files.some(file => file.path === 'examples/api-route.ts'));
  assert.ok(packed.files.some(file => file.path === 'examples/image-api-route.ts'));
  const manifest = JSON.parse(readFileSync(join(root, 'package.json')));
  assert.equal(packed.name, manifest.name);
  assert.equal(packed.version, manifest.version);
  assert.ok(!packed.files.some(file => file.path.startsWith('node_modules/') || file.path.startsWith('test/')));
  writeFileSync(join(directory, 'package.json'), JSON.stringify({ name: 'codexkit-consumer', version: '1.0.0', private: true }));
  run([npm, 'install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund', '--cache', join(directory, 'cache'), join(directory, packed.filename)]);
  const body = readFileSync(join(root, 'test/fixtures/text-request.json'));
  writeFileSync(join(directory, 'request.json'), body);
  const common = `
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { createHash } = require('node:crypto');
const api = require('@timazed/codexkit');
const { CodexKitBridgeClient } = api;
assert.equal(api.execute, undefined);
assert.equal(api.createExecutor, undefined);
assert.equal(api.validatePreparedRequest, undefined);
const body = readFileSync('request.json');
let calls = 0;
const client = new CodexKitBridgeClient({ fetch: async (_, init) => {
  calls++;
  assert.deepEqual(Buffer.from(init.body), body);
  return new Response('data: ' + JSON.stringify({ type: 'response.completed', response: {
    id: 'packaged-response', status: 'completed', output: [{ type: 'message', role: 'assistant',
      content: [{ type: 'output_text', text: 'packaged result' }] }],
  } }) + '\\n\\n', { headers: { 'content-type': 'text/event-stream' } });
} });
const preparedRequest = { body, sha256: createHash('sha256').update(body).digest('hex'),
  sessionId: 's', clientRequestId: 'c', originator: 'codex_cli_rs' };
client.validatePreparedRequest(preparedRequest);
client.execute({ preparedRequest,
  authentication: { accessToken: 'synthetic-token', accountId: 'synthetic-account' },
}).then(result => { assert.equal(result.outputText, 'packaged result'); assert.equal(calls, 1); })
  .catch(error => { console.error(error); process.exitCode = 1; });
`;
  writeFileSync(join(directory, 'consumer.cjs'), common);
  run(['consumer.cjs']);
  writeFileSync(join(directory, 'consumer.mjs'), `import { CodexKitBridgeClient, CodexKitCloudError } from '@timazed/codexkit';\nconst client = new CodexKitBridgeClient();\nif (typeof client.execute !== 'function' || typeof client.validatePreparedRequest !== 'function' || !CodexKitCloudError) throw new Error('ESM imports failed');\nimport './consumer.cjs';\n`);
  run(['consumer.mjs']);
  // The runnable API example must also resolve the scoped package after packing.
  run(['-e', "const { createLocalAPIServer } = require('./node_modules/@timazed/codexkit/examples/local-api/server.cjs'); createLocalAPIServer().close();"]);

  mkdirSync(join(directory, 'examples'));
  cpSync(join(directory, 'node_modules/@timazed/codexkit/examples/api-route.ts'), join(directory, 'examples/api-route.ts'));
  cpSync(join(directory, 'node_modules/@timazed/codexkit/examples/image-api-route.ts'), join(directory, 'examples/image-api-route.ts'));
  writeFileSync(join(directory, 'consumer.ts'), `
import { CodexKitBridgeClient, CodexKitCloudError } from '@timazed/codexkit';
import type { CodexKitBridgeClientOptions, ExecuteInput, ExecutionResult, PreparedRequest } from '@timazed/codexkit';
import type { PreparedImageRequest, ExecuteImageInput, ImageExecutionResult, ImageAction, GeneratedImage } from '@timazed/codexkit';
const preparedRequest: PreparedRequest = { body: new Uint8Array(), sha256: '', sessionId: '', clientRequestId: '', originator: '' };
const input: ExecuteInput = { preparedRequest, authentication: { accessToken: '', accountId: '' },
  onProgress: async event => { if (event.type === 'response.output_text.delta') event.delta.toUpperCase(); } };
const options: CodexKitBridgeClientOptions = { limits: { maxOutputBytes: 1024 } };
const client = new CodexKitBridgeClient(options);
client.validatePreparedRequest(preparedRequest);
const result: Promise<ExecutionResult> = client.execute(input);
const error = new CodexKitCloudError('invalid_request');
void [result, error];
const action: ImageAction = 'generate';
const imageRequest: PreparedImageRequest = { body: new Uint8Array(), sha256: '', clientRequestId: '', imageTurnId: '', originator: '', action };
const imageInput: ExecuteImageInput = { preparedRequest: imageRequest, authentication: input.authentication };
const images: Promise<ImageExecutionResult> = new CodexKitBridgeClient({ imageLimits: { maxPixels: 4_000_000 } }).executeImage(imageInput);
client.validatePreparedImageRequest(imageRequest);
images.then(result => { const image: GeneratedImage = result.images[0]!; void image.pixelSize.width; });
const quotaError = new CodexKitCloudError('image_usage_limit_exceeded');
void quotaError.details.imageUsageLimit?.resetsAt;
`);
  cpSync(join(directory, 'consumer.ts'), join(directory, 'consumer.mts'));
  for (const module of ['CommonJS', 'NodeNext']) {
    writeFileSync(join(directory, 'tsconfig.json'), JSON.stringify({
      compilerOptions: {
        target: 'ES2022', lib: ['ES2022'], module,
        moduleResolution: module === 'CommonJS' ? 'Node' : 'NodeNext',
        strict: true, exactOptionalPropertyTypes: true, skipLibCheck: false, noEmit: true,
        types: ['node'], typeRoots: [join(root, 'node_modules/@types')],
      },
      include: ['consumer.ts', ...(module === 'NodeNext' ? ['consumer.mts'] : []), 'examples/*.ts'],
    }));
    run([join(root, 'node_modules/typescript/bin/tsc'), '-p', 'tsconfig.json']);
  }
  run([join(root, 'node_modules/typescript/bin/tsc'), '-p', 'tsconfig.json', '--noEmit', 'false', '--rootDir', '.', '--outDir', 'compiled']);
  writeFileSync(join(directory, 'route-consumer.cjs'), `
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { createHash } = require('node:crypto');
const body = readFileSync('request.json');
let calls = 0;
globalThis.fetch = async (_, init) => {
  calls++;
  assert.deepEqual(Buffer.from(init.body), body);
  assert.equal(init.headers.Authorization, 'Bearer synthetic-token');
  assert.equal(init.headers['ChatGPT-Account-ID'], 'synthetic-account');
  if (calls === 2) return new Response('', { status: 401 });
  assert.equal(calls, 1, 'The route must not retry');
  return new Response('data: ' + JSON.stringify({ type: 'response.completed', response: {
    id: 'route-response', status: 'completed', output: [{ type: 'message', role: 'assistant',
      content: [{ type: 'output_text', text: 'route result' }] }],
  } }) + '\\n\\n', { headers: { 'content-type': 'text/event-stream' } });
};
const { executeCodexRoute } = require('./compiled/examples/api-route.js');
const preparedRequest = { body, sha256: createHash('sha256').update(body).digest('hex'),
  sessionId: 's', clientRequestId: 'c', originator: 'codex_cli_rs' };
const authentication = { accessToken: 'synthetic-token', accountId: 'synthetic-account' };
const response = { status(code) { this.code = code; return this; }, json(body) { this.body = body; } };
(async () => {
  await executeCodexRoute(preparedRequest, authentication, response);
  assert.equal(response.code, 200);
  assert.equal(response.body.outputText, 'route result');
  assert.equal(calls, 1);
  await executeCodexRoute({ ...preparedRequest, sha256: '0'.repeat(64) }, authentication, response);
  assert.equal(response.code, 400);
  assert.equal(response.body.error.code, 'integrity_mismatch');
  assert.equal(calls, 1, 'Preflight failure must not transmit');
  await executeCodexRoute(preparedRequest, authentication, response);
  assert.equal(response.code, 502);
  assert.equal(response.body.error.code, 'authentication_failed');
  assert.equal(calls, 2, 'Provider authentication failure must not reissue');
})().catch(error => { console.error(error); process.exitCode = 1; });
`);
  run(['route-consumer.cjs']);
  require('./test-image-package.cjs')({ root, directory, run });
  console.log(`Package consumer checks passed: CommonJS, ESM, TypeScript declarations, text/image route examples (${packed.size} bytes packed).`);
} finally {
  rmSync(directory, { recursive: true, force: true });
}
