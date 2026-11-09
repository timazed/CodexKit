const { test } = require('node:test');
const assert = require('node:assert/strict');
const { imageHarness, imagePrepared, imageBody, imageResponse } = require('./image-helpers.cjs');
const { errorCode } = require('./helpers.cjs');
const header = Buffer.from([...Buffer.from('GIF89a'), 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255]);
const frame = Buffer.from([0x21, 0xf9, 4, 0, 10, 0, 0, 0, 0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0]);
const gif = Buffer.concat([header, frame, frame, Buffer.from([0x3b])]);
const request = (controls = {}) => imagePrepared(imageBody({ output_format: 'gif', ...controls }));
const response = bytes => imageResponse({ data: [{ b64_json: bytes.toString('base64') }] });

for (const controls of [{}, { frame_count: 2, frame_duration_ms: 100 }]) {
  test(`GIF returns preserved bytes with controls ${JSON.stringify(controls)}`, async () => {
    const { run, calls } = imageHarness({ fetch: async () => response(gif) });
    const preparedRequest = request(controls);
    const result = await run({ preparedRequest });
    assert.equal(result.images[0].mimeType, 'image/gif');
    assert.deepEqual(result.images[0].pixelSize, { width: 1, height: 1 });
    assert.deepEqual(Buffer.from(result.images[0].base64, 'base64'), gif);
    assert.deepEqual(Buffer.from(calls[0].body), preparedRequest.body);
  });
}
for (const controls of [{ frame_count: 1 }, { frame_count: 17 }, { frame_count: 2.5 },
  { frame_duration_ms: 19 }, { frame_duration_ms: 2001 }, { extra: true }, { gif: {} }]) {
  test(`rejects invalid GIF controls ${JSON.stringify(controls)} before fetching`, async () => {
    const { run, calls } = imageHarness();
    await assert.rejects(run({ preparedRequest: request(controls) }), errorCode('unsupported_request', 'not_started'));
    assert.equal(calls.length, 0);
  });
}
for (const bytes of [gif.subarray(0, gif.length - 1), Buffer.concat([gif, Buffer.from([0])]),
  Buffer.concat([header, frame, Buffer.from([0x3b])]),
  Buffer.concat([header, frame, frame.subarray(0, frame.length - 3), Buffer.from([0x44, 0, 0, 0x3b])])]) {
  test(`rejects malformed or incomplete GIF ${bytes.toString('hex').slice(-20)}`, async () => {
    const { run } = imageHarness({ fetch: async () => response(bytes) });
    await assert.rejects(run({ preparedRequest: request() }), errorCode('invalid_response'));
  });
}
test('upstream flat GIF fields are forwarded exactly and PNG rejects animation fields', async () => {
  const controls = { frame_count: 2, frame_duration_ms: 200 };
  const { run, calls } = imageHarness({ fetch: async () => response(gif) });
  await run({ preparedRequest: request(controls) });
  const body = JSON.parse(Buffer.from(calls[0].body).toString('utf8'));
  assert.deepEqual(body, imageBody({ output_format: 'gif', ...controls }));
  assert.equal(body.gif, undefined);
  const png = imageHarness();
  await assert.rejects(png.run({ preparedRequest: imagePrepared(imageBody(controls)) }),
    errorCode('unsupported_request', 'not_started'));
  assert.equal(png.calls.length, 0);
});
test('GIF total frame pixels respect limits', async () => {
  const { run } = imageHarness({ imageLimits: { maxPixels: 1 }, fetch: async () => response(gif) });
  await assert.rejects(run({ preparedRequest: request() }), errorCode('limit_exceeded'));
});
test('default PNG requests reject unexpected GIF output', async () => {
  const { run } = imageHarness({ fetch: async () => response(gif) });
  await assert.rejects(run(), errorCode('invalid_response'));
});

test('decodes a multi-color ImageIO GIF with LZW dictionary growth', async () => {
  const { readFileSync } = require('node:fs');
  const { join } = require('node:path');
  const bytes = readFileSync(join(__dirname, 'fixtures/animated-colors.gif'));
  const { run } = imageHarness({ fetch: async () => response(bytes) });
  const result = await run({ preparedRequest: request() });
  assert.deepEqual(result.images[0].pixelSize, { width: 32, height: 32 });
  assert.equal(result.images[0].base64, bytes.toString('base64'));
});
