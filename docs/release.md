# Release and CI

This document describes the repository's CI, preview package publishing, and tag-driven release automation.

## Version Source of Truth

- The CLI binary version is defined in `src/version.zig`.
- The root npm package version in `package.json` must match `src/version.zig`.
- Release tags must use the same version with a leading `v`.
  - Example: `src/version.zig = 0.2.2-alpha.1`
  - Matching tag: `v0.2.2-alpha.1`

## npm Package Layout

- npm distribution uses one root package plus four platform packages.
- Root package: `@loongphy/codex-auth`
- Platform packages:
  - `@loongphy/codex-auth-linux-x64`
  - `@loongphy/codex-auth-darwin-x64`
  - `@loongphy/codex-auth-darwin-arm64`
  - `@loongphy/codex-auth-win32-x64`
- The root package exposes the `codex-auth` command and depends on the platform packages through `optionalDependencies`.
- Each platform package declares `os` and `cpu`, so npm installs only the matching binary package for the current host platform.
- GitHub Release assets and npm packages currently target Linux x64, macOS x64, macOS ARM64, and Windows x64.
- Windows builds include both `codex-auth.exe` and `codex-auth-auto.exe`; the helper is used only by the managed auto-switch task.

## CI Workflow

- Branch and pull request validation runs in `.github/workflows/ci.yml`.
- The `build-test` matrix runs on `ubuntu-latest`, `macos-latest`, and `windows-latest`.
- CI installs Zig `0.15.1` and runs `zig test src/main.zig -lc`.

## Preview Packages for Pull Requests

- Pull request preview npm packages are published by `.github/workflows/preview-release.yml`.
- The workflow cross-builds the four platform binaries on Ubuntu and stages the same five npm package directories used by the tag release pipeline.
- The staged root preview package has its `optionalDependencies` rewritten to deterministic `pkg.pr.new` platform package URLs for the PR head SHA.
- Preview publishing then runs a single `pkg.pr.new` publish command across the root package and all four platform packages, so the preview install command keeps the same platform-selective behavior as the real npm release.
- The staged preview root package also gets a `codexAuthPreviewLabel` field like `pr-6 b6bfcf5`.
- The root CLI wrapper uses that field so `codex-auth --version` prints `codex-auth <version> (preview pr-6 b6bfcf5)` for preview installs only.
- `.github/workflows/preview-release.yml` uses `actions/setup-node@v6` with `node-version: lts/*` so preview publishing tracks the latest Node LTS line automatically.
- `pkg.pr.new` preview publishing requires the pkg.pr.new GitHub App to be installed on the repository before the workflow can publish previews or comment on PRs.

## Tag Release Workflow

- Tag pushes matching `v*` run `.github/workflows/release.yml`.
- The release workflow first validates the code with the same `build-test` matrix used by CI.
- It then cross-builds release assets for the four supported targets on Ubuntu.
- Release notes are generated from git tags and commit history.
- GitHub releases are published automatically from the tag pipeline.
- Stable tags create normal GitHub releases.
- Prerelease tags such as `v0.2.0-rc.1`, `v0.2.0-beta.1`, and `v0.2.0-alpha.1` create GitHub releases marked as prereleases, not drafts.

## npm Publish Rules

- npm publishing is handled by the `publish-npm` job in `.github/workflows/release.yml`.
- npm publishing uses Trusted Publishing from GitHub Actions, so the publish job must run on a GitHub-hosted runner with `id-token: write`.
- `.github/workflows/release.yml` uses `actions/setup-node@v6` with Node `24` for the npm packaging and publish steps so the bundled npm CLI supports Trusted Publishing.
- The `setup-node` steps in `.github/workflows/release.yml` explicitly set `package-manager-cache: false` to avoid future automatic npm cache behavior changes in the release pipeline.
- npm provenance validation requires the package `repository.url` metadata to match the GitHub repository URL exactly: `https://github.com/Loongphy/codex-auth`
- Stable tags such as `v0.1.3` publish to npm dist-tag `latest`.
- Prerelease tags such as `v0.2.0-rc.1`, `v0.2.0-beta.1`, and `v0.2.0-alpha.1` publish to npm dist-tag `next`.
