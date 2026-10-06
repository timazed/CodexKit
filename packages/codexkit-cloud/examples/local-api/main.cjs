const { createLocalAPIServer, MODE } = require('./server.cjs');

const args = process.argv.slice(2);
let mode = MODE.fixture;
let port = 8787;
for (let index = 0; index < args.length; index++) {
  if (args[index] === '--live') mode = MODE.live;
  else if (args[index] === '--port') port = Number(args[++index]);
  else throw new Error('Usage: npm run dev:api -- [--live] [--port 8787]');
}
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid port.');
const server = createLocalAPIServer({ mode });
server.listen(port, '127.0.0.1', () => {
  console.log(`CodexKitCloud local API: http://127.0.0.1:${server.address().port} (${mode})`);
  console.log(mode === MODE.fixture
    ? 'Synthetic provider responses; no credentials or provider access required.'
    : 'Live provider requests enabled. Supply authentication separately for each request.');
});
server.on('error', error => {
  console.error(error.code === 'EADDRINUSE' ? 'Port is already in use.' : 'Could not start the local API.');
  process.exitCode = 1;
});
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    server.close();
    server.closeAllConnections();
  });
}
