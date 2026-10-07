const { test } = require('node:test');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const assert = require('node:assert/strict');
const { structured, complete, message, harness, errorCode } = require('./helpers.cjs');

const objectSchema = { type: 'object', properties: { answer: { type: 'string' } }, required: ['answer'], additionalProperties: false };

test('validates JSON without rewriting its whitespace, escapes, or large integer lexemes', async () => {
  const text = ' { "answer" : "\\u0068ello", "count": 9007199254740993 }\n';
  const schema = { ...objectSchema, properties: { ...objectSchema.properties, count: { type: 'integer' } } };
  const result = await harness([complete(text)]).run({ preparedRequest: structured(schema) });
  assert.equal(result.format, 'json_schema');
  assert.equal(result.outputText, text);
});

for (const text of ['not JSON', '```json\n{"answer":"yes"}\n```', '{"answer":"a","answer":"b"}', '{"answer":"\\ud800"}', '{"answer":"yes"} trailing']) {
  test(`rejects invalid structured output without repair: ${text}`, async () => {
    const { run, calls } = harness([complete(text)]);
    await assert.rejects(run({ preparedRequest: structured(objectSchema) }), errorCode('invalid_output', 'completed'));
    assert.equal(calls.length, 1);
  });
}

for (const text of ['{}', '{"answer":2}', '{"answer":"yes","extra":true}', 'null']) {
  test(`rejects schema mismatch: ${text}`, async () => {
    await assert.rejects(harness([complete(text)]).run({ preparedRequest: structured(objectSchema) }), errorCode('schema_mismatch', 'completed'));
  });
}

for (const [schema, valid, invalid] of [
  [{ type: 'string', minLength: 1, maxLength: 1 }, '"🙂"', '"ab"'],
  [{ type: ['string', 'null'] }, 'null', '12'],
  [{ type: 'integer', minimum: 2, exclusiveMaximum: 10, multipleOf: 2 }, '4', '5'],
  [{ type: 'number', maximum: 1, exclusiveMinimum: 0 }, '0.5', '0'],
  [{ enum: [{ a: 1, b: 2 }] }, '{"b":2,"a":1}', '{"a":1}'],
  [{ const: null }, 'null', 'false'],
  [{ type: 'array', items: { type: 'string' }, minItems: 1, maxItems: 2, uniqueItems: true }, '["a","b"]', '["a","a"]'],
  [{ anyOf: [{ type: 'string' }, { type: 'integer' }] }, '2', 'true'],
  [{ allOf: [{ type: 'number' }, { minimum: 2 }] }, '3', '1'],
  [{ oneOf: [{ type: 'number' }, { type: 'integer' }] }, '1.5', '1'],
  [{ not: { type: 'null' } }, 'true', 'null'],
  [{ type: 'object', additionalProperties: { type: 'integer' }, minProperties: 1, maxProperties: 2 }, '{"a":1}', '{"a":"x"}'],
  [{ $defs: { answer: { type: 'string' } }, $ref: '#/$defs/answer', maxLength: 3 }, '"yes"', '"longer"'],
  [{ $defs: { 'a/b~c': { type: 'boolean' } }, $ref: '#/$defs/a~1b~0c' }, 'true', '1'],
  [{ properties: { '__proto__': false }, additionalProperties: false }, '{}', '{"__proto__":1}'],
]) test(`CodexKit schema vocabulary: ${JSON.stringify(schema)}`, async () => {
  const input = { preparedRequest: structured(schema) };
  assert.equal((await harness([complete(valid)]).run(input)).outputText, valid);
  await assert.rejects(harness([complete(invalid)]).run(input), errorCode('schema_mismatch', 'completed'));
});

for (const schema of [
  { type: 'string', pattern: '.*' }, { type: 'string', format: 'email' }, { $ref: 'https://example.com/schema' },
  { $ref: '#/$defs/missing' }, { anyOf: [] }, { type: 'unknown' }, { multipleOf: 0 }, { required: ['a', 'a'] },
  { uniqueItems: 'true' }, { minItems: -1 }, { properties: [] }, { items: [] },
]) test(`rejects invalid/unsupported schema before generation: ${JSON.stringify(schema)}`, async () => {
  const { run, calls } = harness();
  await assert.rejects(run({ preparedRequest: structured(schema) }), errorCode('unsupported_schema', 'not_started'));
  assert.equal(calls.length, 0);
});

test('recursive schema validation has a work/depth budget', async () => {
  const recursive = { $ref: '#' };
  await assert.rejects(harness([complete('{}')]).run({ preparedRequest: structured(recursive) }), errorCode('limit_exceeded', 'completed'));
  const branches = { anyOf: Array.from({ length: 20 }, () => ({ type: 'string' })) };
  const { run, calls } = harness(undefined, { limits: { maxValidationSteps: 10 } });
  await assert.rejects(run({ preparedRequest: structured(branches) }), errorCode('limit_exceeded', 'not_started'));
  assert.equal(calls.length, 0);
});

test('valid recursive data and local references work', async () => {
  const schema = { anyOf: [{ type: 'null' }, { type: 'object', properties: { next: { $ref: '#' } }, required: ['next'], additionalProperties: false }] };
  assert.equal((await harness([complete('{"next":{"next":null}}')]).run({ preparedRequest: structured(schema) })).outputText, '{"next":{"next":null}}');
});

test('JSON schema applies to final answer, never commentary', async () => {
  const { run } = harness([complete('', { output: [
    message('Working on it', { id: 'comment', phase: 'commentary' }),
    message('{"answer":"done"}', { phase: 'final_answer' }),
  ] })]);
  assert.equal((await run({ preparedRequest: structured(objectSchema) })).outputText, '{"answer":"done"}');
});

// October 8 capture: HTTP 200 without Content-Type, completed message records,
// and an empty final output array. IDs are redacted; writing is unchanged.
test('decodes completed structured Codex writing without MIME metadata or a populated terminal snapshot', async () => {
  const bytes = readFileSync(join(__dirname, 'fixtures/completed-output-items.sse'));
  const schema = { type: 'object', properties: { day: { type: 'integer' }, event: { type: 'string' } }, required: ['day', 'event'], additionalProperties: false };
  const { run, calls } = harness(undefined, { fetch: async () => new Response(bytes) });
  const value = await run({ preparedRequest: structured(schema) });
  assert.equal(value.status, 'completed');
  assert.equal(value.format, 'json_schema');
  assert.equal(value.outputText, "{\"day\":2,\"event\":\"The infrastructure committee hearing was delayed after lawmakers requested more time to review the proposal.\"}");
  assert.equal(value.messages[0].text, value.outputText);
  assert.equal(JSON.parse(value.outputText).day, 2);
  assert.equal(calls.length, 1);
  await assert.rejects(harness(undefined, { fetch: async () => new Response(bytes, { headers: { 'content-type': 'text/html' } }) })
    .run({ preparedRequest: structured(schema) }), errorCode('invalid_response', 'unknown'));
});
