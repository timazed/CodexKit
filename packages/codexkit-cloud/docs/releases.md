# Publishing to GitHub Packages

The root `.github/workflows/cloud-release.yml` publishes `@timazed/codexkit-cloud` to GitHub's npm registry at `https://npm.pkg.github.com`. It runs when a `cloud-v*` tag is pushed; Swift's `v*` tags and release workflow remain independent. Creating a tag is a release action, not part of ordinary development.

GitHub Packages uses your existing GitHub account. If needed, [create a GitHub account](https://github.com/signup). No npmjs.com account or npm access token is required. GitHub requires scoped npm names, so the imported `codexkit-cloud` package is named `@timazed/codexkit-cloud` here. Its version remains `0.1.0`, and the `CodexKitBridgeClient` API is unchanged.

## What the workflow does

1. Require a valid cloud version tag, matching package and lockfile versions, the `@timazed/codexkit-cloud` name, and the configured GitHub registry and repository.
2. Require the tagged commit to be reachable from `origin/main`.
3. Call the existing Cloud CI matrix to run `npm ci` and `npm run verify` on Node 22 and 24, including packed-package consumer checks.
4. Check out that exact verified commit in a separate publishing job and recheck the tag and main ancestry. The publishing job does not restore dependency caches.
5. Install locked dependencies, build, and publish from `packages/codexkit-cloud` using Node 24.14.0. Only the publish step receives GitHub Actions' automatically generated `GITHUB_TOKEN` as `NODE_AUTH_TOKEN`. Publishing uses `--ignore-scripts` because the build is already complete.

Stable versions publish to the `latest` dist-tag. Prereleases such as `cloud-v0.2.0-beta.1` publish to `next`. Build-metadata tags are rejected. A moved tag, mismatched lockfile, failed verification, or unmerged commit prevents publishing. An existing package version cannot be overwritten; rerunning a completed publication fails instead of changing its contents.

## One-time GitHub setup

Merge the workflow and package into `timazed/CodexKit`. In the repository's [environment settings](https://github.com/timazed/CodexKit/settings/environments), configure the **`github-packages`** environment. Any deployment branch/tag restrictions must allow the intended `cloud-v*` release tags.

The publishing job requests `contents: read` and `packages: write`. GitHub supplies `GITHUB_TOKEN` for each run; do not create a secret with that name or add an `NPM_TOKEN`. The first tagged release can create the package directly through Actions. No manual initial publication or npm trusted publisher configuration is needed. See [publishing with GitHub Actions](https://docs.github.com/en/actions/tutorials/publish-packages/publish-nodejs-packages#publishing-packages-to-github-packages).

The package's `repository` field links it to `timazed/CodexKit`. If the package already exists, ensure this repository has Actions write access in its package settings.

GitHub initially creates packages with **private visibility**, including packages linked to public repositories. Change visibility in the package's GitHub settings if public distribution is intended. GitHub's npm registry requires authentication for installation even when a package is public. See [GitHub's npm registry documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry) and [package access and visibility](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).

## Preparing a release

The initial version is already `0.1.0`. For future versions, update the package and lockfile together from this directory with `npm version <version> --no-git-tag-version`. Run `npm ci` and `npm run verify`, then merge the changes into `main`.

When ready to publish the initial version, tag its merged commit from the repository root:

```sh
git switch main
git pull --ff-only
git tag -a cloud-v0.1.0 -m "codexkit-cloud 0.1.0"
git push origin cloud-v0.1.0
```

Use the corresponding version for later releases. Do not use Swift's `v*` prefix or npm's automatic Git tagging. Monitor **Cloud Release** in GitHub Actions; a failed run can be rerun after resolving configuration problems, provided that version has not already been published. Do not move a release tag to repair a failed or completed release.

For a local packaging preview without publishing:

```sh
cd packages/codexkit-cloud
npm ci
npm run verify
npm publish --dry-run
```

The dry run cannot verify GitHub account permissions or the workflow's token. After publication, follow the [installation instructions](../README.md#install-and-use) to authenticate and install `@timazed/codexkit-cloud`; use `@timazed/codexkit-cloud@next` for prereleases.
