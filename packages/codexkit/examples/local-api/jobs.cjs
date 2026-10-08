const { createHash } = require('node:crypto');
const { CodexKitCloudError } = require('@timazed/codexkit');

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const terminal = job => ['succeeded', 'failed'].includes(job.status);

/** In-memory loopback demo middleware. Completion events are simulated; no SNS/APNs. */
function createDemoJobRoutes({ client, mode, readEnvelope, json, APIError, executionTimeoutMs,
  maximumBytes, maximumImageBytes, maximumConcurrent }) {
  const devices = new Map();
  const controllers = new Set();
  let closed = false;
  let running = 0;

  function deviceFor(request) {
    const id = request.headers['x-demo-device'];
    if (typeof id !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(id)) throw new APIError(400, 'invalid_demo_device');
    let device = devices.get(id);
    if (!device) {
      // Bounded retention; only completed devices can be evicted.
      if (devices.size >= 64) {
        const old = [...devices].find(([, value]) => [...value.jobs.values()].every(terminal));
        if (old) devices.delete(old[0]);
        else throw new APIError(429, 'demo_capacity');
      }
      device = { id, jobs: new Map(), submissions: [], deliveries: [], batch: [] };
      devices.set(id, device);
    }
    return device;
  }

  function metadata(job, legacy = false) {
    return { jobId: job.jobId, deviceId: job.deviceId, kind: job.kind, status: job.status,
      ...(!legacy ? { completionPush: job.completionPush } : {}),
      ...(job.failure ? { failure: job.failure } : {}) };
  }

  function notifyWhenDrained(device) {
    if (!device.batch.length || device.batch.some(id => !terminal(device.jobs.get(id)))) return;
    const jobIds = device.batch;
    device.deliveries.push({ simulated: true, jobIds,
      completionPush: jobIds.some(id => device.jobs.get(id).completionPush === 'regular') ? 'regular' : 'silent' });
    device.batch = [];
  }

  function pump() {
    if (closed) return;
    for (const device of devices.values()) for (const job of device.jobs.values()) {
      if (running >= maximumConcurrent) return;
      if (job.status !== 'queued' || job.held) continue;
      job.status = 'running';
      running++;
      void execute(device, job);
    }
  }

  async function execute(device, job) {
    const controller = new AbortController();
    controllers.add(controller);
    const timer = setTimeout(() => controller.abort(), executionTimeoutMs);
    try {
      job.providerCalls++;
      const { preparedRequest, authentication } = job.input;
      const input = { preparedRequest, authentication, signal: controller.signal };
      job.result = await (job.kind === 'image' ? client.executeImage(input) : client.execute(input));
      job.status = 'succeeded';
    } catch (error) {
      job.status = 'failed';
      job.failure = error instanceof CodexKitCloudError
        ? { code: error.code, outcome: error.details.outcome }
        : { code: 'demo_execution_failed', outcome: 'unknown' };
    } finally {
      clearTimeout(timer);
      clearTimeout(job.holdTimer);
      job.input = undefined; // Drop credentials and prepared bytes once execution finishes.
      controllers.delete(controller);
      running--;
      notifyWhenDrained(device);
      pump();
    }
  }

  async function handle(request, response) {
    const submit = request.method === 'POST' && ['/codex', '/codex/images'].includes(request.url);
    const jobRoute = /^\/codex\/([a-f0-9]{64})(?:\/(result|output))?$/.exec(request.url);
    const demo = ['/demo/queue', '/demo/release'].includes(request.url);
    if (!submit && !jobRoute && !demo) return false;
    const device = deviceFor(request);
    if (submit) {
      const image = request.url === '/codex/images';
      const input = await readEnvelope(request, image ? maximumImageBytes : maximumBytes, image, true);
      try {
        if (image) client.validatePreparedImageRequest(input.preparedRequest);
        else client.validatePreparedRequest(input.preparedRequest);
      } catch (error) {
        if (error instanceof CodexKitCloudError) throw new APIError(400, error.code);
        throw error;
      }
      const { authentication, preparedRequest, completionPush } = input;
      if (!authentication || typeof authentication.accessToken !== 'string' || !authentication.accessToken ||
          typeof authentication.accountId !== 'string' || !authentication.accountId) throw new APIError(400, 'invalid_authentication');
      if (request.headers['x-demo-retry-once'] && mode !== 'fixture') throw new APIError(400, 'fixture_only');
      const jobId = digest(preparedRequest.clientRequestId);
      const { body, ...routing } = preparedRequest;
      const fingerprint = digest(JSON.stringify([image, routing, authentication.accountId, completionPush]));
      const existing = device.jobs.get(jobId);
      if (device.submissions.length >= 512) throw new APIError(429, 'demo_capacity');
      device.submissions.push({ jobId, clientRequestId: preparedRequest.clientRequestId, completionPush,
        envelopeSHA256: digest(input.envelopeBytes), sha256: preparedRequest.sha256, bodySHA256: digest(body),
        conflict: !!existing && existing.fingerprint !== fingerprint });
      if (existing) {
        if (existing.fingerprint !== fingerprint) throw new APIError(409, 'request_conflict');
        json(response, 202, { data: metadata(existing, request.headers['x-demo-legacy-job'] === '1') });
        return true;
      }
      if (device.jobs.size >= 64) throw new APIError(429, 'demo_capacity');
      const job = { jobId, deviceId: device.id, kind: image ? 'image' : 'response', status: 'queued',
        completionPush, fingerprint, providerCalls: 0, held: request.headers['x-demo-hold'] === '1',
        input: { preparedRequest, authentication } };
      device.jobs.set(jobId, job);
      device.batch.push(jobId);
      // Abandoned held batches cannot retain credentials indefinitely.
      job.holdTimer = setTimeout(() => {
        if (!job.held || terminal(job)) return;
        job.status = 'failed'; job.input = undefined;
        job.failure = { code: 'demo_hold_expired', outcome: 'not_started' };
        notifyWhenDrained(device);
      }, executionTimeoutMs);
      // Simulate a reply lost AFTER acceptance. The retry must find this same job.
      if (request.headers['x-demo-retry-once'] === '1') json(response, 503, { error: { code: 'demo_reply_lost' } });
      else json(response, 202, { data: metadata(job, request.headers['x-demo-legacy-job'] === '1') });
      pump();
      return true;
    }
    if (request.url === '/demo/queue' && request.method === 'GET') {
      json(response, 200, { data: { jobs: [...device.jobs.values()].map(job => ({ ...metadata(job), providerCalls: job.providerCalls })),
        submissions: device.submissions, deliveries: device.deliveries } });
    } else if (request.url === '/demo/release' && request.method === 'POST') {
      for (const job of device.jobs.values()) { job.held = false; clearTimeout(job.holdTimer); }
      pump();
      json(response, 200, { data: { released: true } });
    } else if (jobRoute && request.method === 'GET') {
      const job = device.jobs.get(jobRoute[1]);
      if (!job) throw new APIError(404, 'not_found');
      if (!jobRoute[2]) json(response, 200, { data: metadata(job, request.headers['x-demo-legacy-job'] === '1') });
      else {
        if (job.status !== 'succeeded') throw new APIError(409, 'result_not_ready');
        if (jobRoute[2] === 'result') json(response, 200, { data: {
          jobId: job.jobId, url: `http://${request.headers.host}/codex/${job.jobId}/output`,
        } });
        else json(response, 200, { data: job.result });
      }
    } else throw new APIError(404, 'not_found');
    return true;
  }

  function close() {
    closed = true;
    for (const device of devices.values()) for (const job of device.jobs.values()) {
      clearTimeout(job.holdTimer); job.input = undefined;
    }
    for (const controller of controllers) controller.abort();
  }
  return { handle, close };
}

module.exports = { createDemoJobRoutes };
