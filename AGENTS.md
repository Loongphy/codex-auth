# codex-auth

## Language

- All user-facing CLI output, prompts, help text, warnings, and error messages must be written in English only.

## Validation

Verify every `.zig` change at these levels, scaling the effort to the scope of the change:
- **Build**: `zig build` compiles without errors or warnings.
- **Tests**: focused tests for the touched areas first (`zig build test -Dtest-filter=<substring>`), then the full suite (`zig build test test-helpers`) before considering the change done.
- **End-to-end**: run the release build (`zig build -Doptimize=ReleaseSafe`) against an isolated mock `CODEX_HOME` populated with test data, confirming the affected commands work without touching real account data.

Zig toolchain conventions (API discovery, runtime and test rules) live in [docs/zig.md](./docs/zig.md).

## Pull Request Acceptance

- Before pushing, the change must pass the Validation levels above, including the real-environment release check when it affects runtime behavior.
- Before merging a change that affects packaged runtime behavior, smoke-test the published preview npm packages (`pkg.pr.new`, see [docs/release.md](./docs/release.md)): install the root preview package into an isolated project under `/tmp/<task-name>` with isolated `HOME` and `CODEX_HOME`, then run the affected commands end-to-end. `codex-auth --version` must print the `(preview pr-<n> <sha>)` label.
- Before merging, confirm the Greptile review is actually clean: a green check only proves the review ran. Read its full summary score and every inline review comment; each actionable finding must be fixed or explicitly declined. Never merge with unaddressed review comments.
- Merge with squash and merge: write one concise commit message covering the key changes instead of the concatenated per-commit dump, and preserve every distinct commit author in the PR as a `Co-authored-by:` trailer — the default squash keeps only the PR author's identity and silently drops other participants.

## Release Process

- When updating and pushing a release version, always follow [docs/release.md](./docs/release.md).

## Docs

- Do not add low-level technical implementation details to `README.md`. Put implementation-specific behavior in `docs/*.md` or `AGENTS.md` instead.
- Keep `docs/*.md` behavioral: describe what a command does and the rules that cross feature boundaries (state transitions, platform differences, API/JSON contracts). Do not transcribe volatile UI details — exact wording, markers, colors, and rendered examples drift from the implementation and go stale. Pin those details in `tests/*_test.zig` and reference the test file instead.
