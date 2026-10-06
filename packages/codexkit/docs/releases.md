# Publishing to GitHub Packages

The root `.github/workflows/cloud-release.yml` publishes `@timazed/codexkit` to GitHub's npm registry at `https://npm.pkg.github.com`. It runs when a `cloud-v*` tag is pushed; Swift's `v*` tags and release workflow remain independent. Creating a tag is a release action, not part of ordinary development.

GitHub Packages uses your existing GitHub account. No npmjs.com account or npm access token is required. Version `0.1.1` publishes under `@timazed/codexkit`, replacing the original `@timazed/codexkit-cloud@0.1.0` name while preserving the bridge API. Existing installs of the original package remain available. Consumers should [migrate their dependency and imports](../README.md#migrating-from-the-original-package-name).

## What the workflow does

1. Require a valid cloud version tag, matching package and lockfile versions, the `@timazed/codexkit` name, and the configured GitHub registry and repository.
2. Require the tagged commit to be reachable from `origin/main`.
3. Call the existing Cloud CI matrix to run `npm ci` and `npm run verify` on Node 22 and 24, including packed-package consumer checks.
4. Check out that exact verified commit in a separate publishing job and recheck the tag and main ancestry. The publishing job does not restore dependency caches.
5. Install locked dependencies, build, and publish from `packages/codexkit` using Node 24.14.0. Publishing uses `--ignore-scripts` because the build is already complete.
6. Install the exact published version from GitHub Packages in a temporary consumer and verify CommonJS and ESM imports of `CodexKitBridgeClient`. Only publishing and registry verification receive GitHub Actions' automatically generated `GITHUB_TOKEN` as `NODE_AUTH_TOKEN`.

Stable versions publish to the `latest` dist-tag. Prereleases such as `cloud-v0.2.0-beta.1` publish to `next`. Build-metadata tags are rejected. A moved tag, mismatched lockfile, failed verification, or unmerged commit prevents publishing. An existing package version cannot be overwritten; rerunning a completed publication fails instead of changing its contents.

## One-time GitHub setup

Merge the workflow and package into `timazed/CodexKit`. In the repository's [environment settings](https://github.com/timazed/CodexKit/settings/environments), configure the **`github-packages`** environment. Any deployment branch/tag restrictions must allow the intended `cloud-v*` release tags.

The publishing job requests `contents: read` and `packages: write`. GitHub supplies `GITHUB_TOKEN` for each run; do not create a secret with that name or add an `NPM_TOKEN`. The first tagged release can create the package directly through Actions. No manual initial publication or npm trusted publisher configuration is needed. See [publishing with GitHub Actions](https://docs.github.com/en/actions/tutorials/publish-packages/publish-nodejs-packages#publishing-packages-to-github-packages).

The package's `repository` field links it to `timazed/CodexKit`. If the package already exists, ensure this repository has Actions write access in its package settings.

GitHub initially creates packages with **private visibility**, including packages linked to public repositories. Change visibility in the package's GitHub settings if public distribution is intended. GitHub's npm registry requires authentication for installation even when a package is public. See [GitHub's npm registry documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry) and [package access and visibility](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).

## Preparing a release

The renamed package starts at `0.1.1`, continuing the existing release sequence. For future versions, update the package and lockfile together from this directory with `npm version <version> --no-git-tag-version`. Run `npm ci` and `npm run verify`, then merge the changes into `main`.

When ready to publish version `0.2.0`, tag its merged commit from the repository root:

```sh
git switch main
git pull --ff-only
git tag -a cloud-v0.2.0 -m "@timazed/codexkit 0.2.0"
git push origin cloud-v0.2.0
```

Use the corresponding version for later releases. Do not use Swift's `v*` prefix or npm's automatic Git tagging. Monitor **Cloud Release** in GitHub Actions; a failed run can be rerun after resolving configuration problems, provided that version has not already been published. Do not move a release tag to repair a failed or completed release.

For a local packaging preview without publishing:

```sh
cd packages/codexkit
npm ci
npm run verify
npm publish --dry-run
```

The dry run cannot verify GitHub account permissions or the workflow's token. After publication, follow the [installation instructions](../README.md#install-and-use) to authenticate and install `@timazed/codexkit`; use `@timazed/codexkit@next` for prereleases.
