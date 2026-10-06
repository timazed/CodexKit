const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { releaseVersion, validatePackage, validateGit } = require('../scripts/validate-release.cjs');

const manifest = require('../package.json');
const lockfile = require('../package-lock.json');

test('cloud tags select latest for stable releases and next for prereleases', () => {
  assert.deepEqual(releaseVersion('cloud-v0.1.0'), { version: '0.1.0', npmTag: 'latest' });
  assert.deepEqual(releaseVersion('cloud-v1.2.3-beta.0'), { version: '1.2.3-beta.0', npmTag: 'next' });
});

test('release rejects Swift tags, refs, malformed versions, and unsafe input', () => {
  for (const tag of [undefined, 'v0.1.0', 'main', '--help', 'cloud-v01.2.3', 'cloud-v1.2.3-beta.01',
    'cloud-v1.2.3+build', 'cloud-v1.2.3\n', 'cloud-v1.2.3; touch bad']) {
    assert.throws(() => releaseVersion(tag));
  }
});

test('release requires matching package identity, version, and lockfile', () => {
  const tag = `cloud-v${manifest.version}`;
  assert.equal(validatePackage(tag, manifest, lockfile).version, manifest.version);
  assert.throws(() => validatePackage('cloud-v9.9.9', manifest, lockfile));
  assert.throws(() => validatePackage(tag, { ...manifest, name: 'another-package' }, lockfile));
  assert.throws(() => validatePackage(tag, { ...manifest, private: true }, lockfile));
  for (const change of [{ version: '9.9.9' }, { name: 'another-package' }, { packages: {} },
    { packages: { '': { ...lockfile.packages[''], version: '9.9.9' } } }]) {
    assert.throws(() => validatePackage(tag, manifest, { ...lockfile, ...change }));
  }
});

test('release requires GitHub Packages and the publishing repository', () => {
  const tag = `cloud-v${manifest.version}`;
  for (const change of [{ repository: { ...manifest.repository, url: 'https://github.com/other/repo' } },
    { repository: { ...manifest.repository, directory: 'another-package' } },
    { publishConfig: { ...manifest.publishConfig, registry: 'https://other.example/' } },
    { publishConfig: { ...manifest.publishConfig, registry: 'https://registry.npmjs.org/' } }]) {
    assert.throws(() => validatePackage(tag, { ...manifest, ...change }, lockfile));
  }
});

test('release rejects an unscoped package even when its lockfile matches', () => {
  const name = 'codexkit-cloud';
  const unscopedLockfile = { ...lockfile, name, packages: { ...lockfile.packages,
    '': { ...lockfile.packages[''], name } } };
  assert.throws(() => validatePackage(`cloud-v${manifest.version}`, { ...manifest, name }, unscopedLockfile));
});

test('release requires an existing tag at HEAD and a commit reachable from main', () => {
  const directory = mkdtempSync(join(tmpdir(), 'codexkit-cloud-release-'));
  const git = (...args) => execFileSync('git', args, { cwd: directory, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  try {
    git('init', '--quiet', '--initial-branch=main');
    git('config', 'user.name', 'Release Fixture');
    git('config', 'user.email', 'fixture@example.test');
    git('config', 'commit.gpgsign', 'false');
    git('config', 'tag.gpgsign', 'false');
    writeFileSync(join(directory, 'fixture'), 'initial');
    git('add', 'fixture');
    git('commit', '--quiet', '-m', 'Fixture');
    git('update-ref', 'refs/remotes/origin/main', 'HEAD');
    // These tags exist only inside the temporary test repository.
    git('tag', '-a', 'cloud-v0.1.0', '-m', 'Fixture release');
    const original = git('rev-parse', 'HEAD');
    assert.equal(validateGit('cloud-v0.1.0', directory), original);
    assert.throws(() => validateGit('cloud-v0.2.0', directory));
    git('switch', '--quiet', '-c', 'feature/unmerged');
    writeFileSync(join(directory, 'fixture'), 'unmerged');
    git('commit', '--quiet', '-am', 'Unmerged fixture');
    assert.throws(() => validateGit('cloud-v0.1.0', directory));
    git('tag', 'cloud-v0.2.0');
    assert.throws(() => validateGit('cloud-v0.2.0', directory));
    git('switch', '--quiet', '--detach', original);
    git('tag', '--force', 'cloud-v0.1.0', 'feature/unmerged');
    assert.throws(() => validateGit('cloud-v0.1.0', directory));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
