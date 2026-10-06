# Contributing

Thanks for contributing to `CodexKit`.

## Local Setup

```sh
swift package resolve
swift test
```

For demo app validation:

```sh
xcodebuild -project DemoApp/CodexKitDemo.xcodeproj -scheme CodexKitIOSDemo -destination 'generic/platform=iOS' build
```

The TypeScript library is developed independently with Node 22 or 24:

```sh
cd packages/codexkit-cloud
npm ci
npm run verify
```

`verify` builds and tests the library, then installs a packed tarball in a temporary consumer to check CommonJS, ESM, declarations, and the API route example. See its [backend usage and installation guide](packages/codexkit-cloud/README.md). The root `Cloud CI` workflow tests both Node versions. Swift workflows and `Package.swift` do not invoke npm.

From the repository root, run `python3 Scripts/check_source_size.py` and `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Verification` for shared repository checks. Production TypeScript, examples, and package verification scripts follow the same 600-line limit as Swift sources.

## Pull Requests

- Keep changes focused and scoped.
- Add or update tests when behavior changes.
- Update docs (`README.md`, `DemoApp/README.md`, `CHANGELOG.md`) for user-facing changes.
- Ensure tests pass before opening a PR.

## Commit Messages

Use clear, imperative messages. Example:

- `Add thread-level persona cache invalidation`
- `Fix OAuth sign-in cancel state reset`

## Releases

- Swift uses Semantic Versioning with tags like `v1.0.0`.
- Update `CHANGELOG.md` for release notes.
- Tag from `main` with an annotated tag:

```sh
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

The npm package owns its version in `packages/codexkit-cloud/package.json` and `package-lock.json`. Cloud release tags use `cloud-v0.1.0` (and subsequently `cloud-v<version>`), independently of Swift's `v*` tags. Use `npm version <version> --no-git-tag-version` within the package when preparing a version change. `Cloud Release` requires a merged commit and matching versions, reuses the Node 22/24 `Cloud CI` matrix, and publishes `@timazed/codexkit-cloud` to GitHub Packages. Stable versions use `latest`; prereleases use `next`. Configure the `github-packages` environment as described in [cloud release setup](packages/codexkit-cloud/docs/releases.md) before pushing a release tag. The workflow uses the built-in `GITHUB_TOKEN` with `packages: write`; the first release needs no manual publication or custom token secret.
