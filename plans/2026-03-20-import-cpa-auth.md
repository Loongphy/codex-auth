---
name: import-cpa-auth
description: Add CPA-format auth import support and drive the branch through the full PR review and CI loop
---

# Plan

Implement CPA-format auth import for `codex-auth`, ship it behind `import --cpa`, and drive the branch from bootstrap through a green Draft PR with no unresolved actionable review threads.

## Requirements
- Add `codex-auth import --cpa [<path>]`.
- In CPA mode, allow the path to be omitted and default the source to `~/.cli-proxy-api`.
- For CPA directory imports, scan all direct child `.json` files only, non-recursively, in sorted filename order.
- Treat each CPA file as the flat token JSON shape implied by `scripts/convert_tokens.sh`.
- Convert CPA JSON to the current standard auth snapshot format in memory before importing.
- Require `refresh_token` during CPA conversion; skip missing or empty values as `MissingRefreshToken`.
- Keep the existing import stdout/stderr reporting model unchanged.
- Keep existing non-CPA import behavior unchanged.
- Reject `--cpa` together with `--purge`.
- Keep this plan file updated so it reflects the latest implementation and PR-loop progress.

## Scope
- In: CLI parsing/help changes, CPA conversion/import logic, docs updates, tests, Draft PR creation, CI/review-loop handling, and temporary `AGENTS.md` execution-lock management.
- Out: unrelated import redesigns, unrelated PR feedback outside this branch diff unless required to make the PR green, and permanent `AGENTS.md` workflow changes.

## Files and entry points
- `src/cli.zig` for CLI parsing/help text and import dispatch options
- `src/auth.zig` for auth parsing helpers and CPA-to-standard conversion
- `src/registry.zig` and `src/main.zig` for import execution, default-source resolution, and report handling
- `src/tests/` plus `README.md` and `docs/implement.md` for validation and documentation coverage

## Data model / API changes
- Extend import parsing with an explicit CPA mode so `handleImport` can choose standard import vs CPA import.
- Add an internal CPA conversion helper that emits standard auth JSON containing:
  - `auth_mode`
  - `OPENAI_API_KEY`
  - `tokens.id_token`
  - `tokens.access_token`
  - `tokens.refresh_token`
  - `tokens.account_id`
  - `last_refresh`
- Keep account identity derived from the converted auth JWT claims, not from the top-level CPA `email`.

## Action items
- [x] Add this plan file and keep implementation aligned with it.
- [x] Add a temporary execution-lock section to `AGENTS.md` that points at this plan until the task is complete.
- [x] Commit the bootstrap changes and create a Draft PR targeting `main`.
- [x] Implement `import --cpa [<path>]` and the underlying CPA conversion/import flow.
- [x] Update docs and help text for the new flag and default source behavior.
- [x] Add or adjust tests for CPA parsing, import behavior, and CLI output.
- [x] Run local validation for the touched Zig code and supporting docs/tests.
- [x] Push implementation changes and process PR review comments plus CI until green.
- [x] Remove the temporary `AGENTS.md` execution lock once the work is complete and validated.

## Progress log
- 2026-03-20: Captured the execution plan and locked `AGENTS.md` to it before any code changes.
- 2026-03-20: Created bootstrap commit `3618744`, opened Draft PR #21, and captured the initial PR snapshot (CI pending, no review threads).
- 2026-03-20: Implemented `import --cpa`, updated docs/tests, and passed `zig test src/main.zig -lc`, `zig build`, and `zig build run -- list`.
- 2026-03-20: Pushed implementation commit `cbd3314`, waited for PR #21 checks to turn green, and confirmed there were still no unresolved review threads before cleanup.
- 2026-03-20: Fixed the missing-default-CPA-source behavior in commit `a54aea9`, re-ran the PR loop, and confirmed PR #21 was green with no unresolved review threads.
- 2026-03-20: Added a repeat-import CPA regression test during an extra branch-vs-`main` review pass and re-entered the PR loop for final verification.

## Testing and validation
- `zig test src/main.zig -lc`
- `zig build`
- `zig build run -- list`
- Add or update tests for:
  - `import --cpa` CLI parsing/help
  - single-file CPA import
  - directory CPA import
  - repeated CPA import -> `updated`
  - missing `refresh_token` -> `MissingRefreshToken`
  - omitted-path CPA import using `~/.cli-proxy-api`
  - stored snapshots using the standard nested auth JSON layout

## Risks and edge cases
- The converted snapshot written under `accounts/` must be the standard auth format, not the original CPA source bytes.
- Default-source resolution must use the real user home directory, not `~/.codex`.
- Directory CPA import should keep the existing import report ordering and stream split.
- The temporary `AGENTS.md` execution lock must be removed before the task is finally declared done.

## Assumptions
- The plan file remains in `plans/` after completion.
- Review comments that are stale or not reasonable are not “fixed” blindly; only actionable comments are addressed and resolved.
- The first PR created from `feat/import-cpa-auth` is the PR used for the entire review loop.
