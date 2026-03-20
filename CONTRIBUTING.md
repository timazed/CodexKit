# Contributing

Thanks for contributing to `CodexKit`.

## Local Setup

```sh
swift package resolve
swift test
```

For demo app validation:

```sh
xcodebuild -project DemoApp/AssistantRuntimeDemoApp.xcodeproj -scheme AssistantRuntimeDemoApp -destination 'generic/platform=iOS' build
```

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

- We use Semantic Versioning with tags like `v1.0.0`.
- Update `CHANGELOG.md` for release notes.
- Tag from `main` with an annotated tag:

```sh
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```
