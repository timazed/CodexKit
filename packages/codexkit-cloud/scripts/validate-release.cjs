const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { appendFileSync, readFileSync } = require('node:fs');
const { join, resolve } = require('node:path');

function releaseVersion(tag) {
  assert.equal(typeof tag, 'string', 'CLOUD_TAG must identify an existing cloud release tag');
  const match = /^cloud-v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?)$/.exec(tag);
  assert.ok(match && match[0] === tag, 'Expected cloud-v<semver> without build metadata');
  for (const identifier of match[2]?.split('.') ?? []) {
    assert.ok(!/^\d+$/.test(identifier) || /^(0|[1-9]\d*)$/.test(identifier), 'Invalid numeric prerelease identifier');
  }
  return { version: match[1], npmTag: match[2] ? 'next' : 'latest' };
}

function validatePackage(tag, manifest, lockfile) {
  const release = releaseVersion(tag);
  assert.equal(manifest.name, '@timazed/codexkit-cloud', 'Only @timazed/codexkit-cloud may be published');
  assert.equal(manifest.version, release.version, 'Tag and package version must match');
  assert.notEqual(manifest.private, true, 'The cloud package must be publishable');
  for (const value of [lockfile, lockfile.packages?.['']]) {
    assert.equal(value?.name, manifest.name, 'Lockfile package name must match');
    assert.equal(value?.version, manifest.version, 'Lockfile package version must match');
  }
  assert.equal(manifest.repository?.url, 'git+https://github.com/timazed/CodexKit.git', 'Package must link to the publishing repository');
  assert.equal(manifest.repository?.directory, 'packages/codexkit-cloud');
  assert.equal(manifest.publishConfig?.registry, 'https://npm.pkg.github.com', 'Cloud releases must target GitHub Packages');
  return release;
}

function validateGit(tag, cwd) {
  releaseVersion(tag);
  const git = (...args) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const sha = git('rev-parse', '--verify', `refs/tags/${tag}^{commit}`);
  assert.match(sha, /^[0-9a-f]{40}$/);
  assert.equal(git('rev-parse', 'HEAD'), sha, 'Checkout must match the release tag; the tag may have moved');
  git('merge-base', '--is-ancestor', sha, 'refs/remotes/origin/main');
  return sha;
}

if (require.main === module) {
  try {
    const root = resolve(__dirname, '..');
    const read = name => JSON.parse(readFileSync(join(root, name), 'utf8'));
    const release = validatePackage(process.env.CLOUD_TAG, read('package.json'), read('package-lock.json'));
    const sha = validateGit(process.env.CLOUD_TAG, root);
    if (process.env.GITHUB_OUTPUT) {
      appendFileSync(process.env.GITHUB_OUTPUT, `sha=${sha}\nnpm_tag=${release.npmTag}\n`);
    }
    console.log(`Validated @timazed/codexkit-cloud@${release.version} at ${sha}; GitHub Packages dist-tag: ${release.npmTag}.`);
  } catch (error) {
    console.error(`Cloud release validation failed: ${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = { releaseVersion, validatePackage, validateGit };
